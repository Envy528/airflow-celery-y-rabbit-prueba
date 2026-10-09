#!/usr/bin/env bash
# Worker de Airflow (CeleryExecutor) para Linux (Ubuntu, Mint...) SIN sudo y SIN Docker.
# Todo se instala dentro de esta carpeta y en ~/.local/bin (uv).
#
# Uso:
#   chmod +x iniciar_worker.sh
#   ./iniciar_worker.sh                                   # en primer plano (Ctrl+C para parar)
#   nohup ./iniciar_worker.sh > worker.out 2>&1 &         # en segundo plano
#   pkill -f "airflow celery worker"                      # detenerlo
#   ./limpiar.sh                                          # deshacer todo lo que instala
set -euo pipefail
cd "$(dirname "$0")"

AIRFLOW_VERSION=3.1.5
PYTHON_VERSION=3.12

# 1. Instalar uv en el usuario si no existe (no pide sudo)
export PATH="$HOME/.local/bin:$PATH"
if ! command -v uv >/dev/null 2>&1; then
  echo ">> Instalando uv..."
  # UV_NO_MODIFY_PATH=1: no toca ~/.bashrc ni ~/.profile (el PATH se pone arriba)
  curl -LsSf https://astral.sh/uv/install.sh | env UV_NO_MODIFY_PATH=1 sh
  # Marca para que limpiar.sh sepa que uv lo instaló este script
  touch .uv_instalado_por_script
fi

# 2. Crear entorno e instalar Airflow (solo la primera vez).
#    uv descarga su propio Python, no usa el del sistema.
if [ ! -x .venv/bin/airflow ]; then
  echo ">> Instalando Airflow ${AIRFLOW_VERSION} (tarda unos minutos la primera vez)..."
  uv venv --python "${PYTHON_VERSION}"
  uv pip install "apache-airflow[celery,postgres]==${AIRFLOW_VERSION}" \
    --constraint "https://raw.githubusercontent.com/apache/airflow/constraints-${AIRFLOW_VERSION}/constraints-${PYTHON_VERSION}.txt"
fi

# 3. Cargar configuración (el mismo .env que usa el maestro)
if [ ! -f .env ]; then
  echo "ERROR: no existe .env. Crea uno con: cp .env.example .env  y rellénalo." >&2
  exit 1
fi
set -a; source .env; set +a
: "${MASTER_IP:?Define MASTER_IP en .env (IP privada del maestro)}"
: "${AIRFLOW_FERNET_KEY:?Define AIRFLOW_FERNET_KEY en .env}"
: "${AIRFLOW_JWT_SECRET:?Define AIRFLOW_JWT_SECRET en .env}"
RABBITMQ_DEFAULT_USER="${RABBITMQ_DEFAULT_USER:-rabbit}"
RABBITMQ_DEFAULT_PASS="${RABBITMQ_DEFAULT_PASS:-rabbit}"
POSTGRES_PORT="${POSTGRES_PORT:-5433}"

export AIRFLOW_HOME="$PWD"
export AIRFLOW__CORE__EXECUTOR=CeleryExecutor
export AIRFLOW__DATABASE__SQL_ALCHEMY_CONN="postgresql+psycopg2://airflow:airflow@${MASTER_IP}:${POSTGRES_PORT}/airflow"
export AIRFLOW__CELERY__BROKER_URL="amqp://${RABBITMQ_DEFAULT_USER}:${RABBITMQ_DEFAULT_PASS}@${MASTER_IP}:5672//"
export AIRFLOW__CELERY__RESULT_BACKEND="db+postgresql://airflow:airflow@${MASTER_IP}:${POSTGRES_PORT}/airflow"
export AIRFLOW__CORE__EXECUTION_API_SERVER_URL="http://${MASTER_IP}:8080/execution/"
export AIRFLOW__CORE__FERNET_KEY="${AIRFLOW_FERNET_KEY}"
export AIRFLOW__API_AUTH__JWT_SECRET="${AIRFLOW_JWT_SECRET}"
export AIRFLOW__CORE__DAGS_FOLDER="$PWD/dags"
export AIRFLOW__CORE__LOAD_EXAMPLES=false
# Se anuncia con su IP real para que el maestro pueda leer sus logs (puerto 8793)
export AIRFLOW__CORE__HOSTNAME_CALLABLE=airflow.utils.net.get_host_ip_address

mkdir -p dags logs plugins

# 4. Arrancar el worker
echo ">> Conectando al maestro ${MASTER_IP} | colas: ${WORKER_QUEUES:-default}"
exec .venv/bin/airflow celery worker -q "${WORKER_QUEUES:-default}"
