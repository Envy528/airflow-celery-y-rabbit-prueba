#!/usr/bin/env bash
# Deshace en LINUX (Ubuntu, Mint...) todo lo que agregan este repo y sus scripts,
# para dejar el PC como estaba. Sirve tanto en un worker como en un maestro.
#
# Qué limpia:
#   1. Detiene el worker de iniciar_worker.sh si está corriendo.
#   2. Docker: contenedores, volúmenes y redes de los proyectos "airflow" (maestro)
#      y "airflow-worker" (worker con Docker). OJO: borra la base de datos de Airflow.
#   3. uv (solo si lo instaló iniciar_worker.sh) y el Python que descargó.
#   4. Archivos generados dentro del repo (.venv, logs, airflow.cfg...).
#
# Uso:
#   ./limpiar.sh               limpieza normal
#   ./limpiar.sh --imagenes    además borra las imágenes de Docker (airflow, postgres, rabbitmq)
#   ./limpiar.sh --forzar-uv   borra uv aunque no haya marca de que lo instaló el script
#   ./limpiar.sh --si          no pide confirmación
#
# No borra: el .env, tus DAGs ni la carpeta del repo (bórrala a mano al final si quieres).
set -uo pipefail
cd "$(dirname "$0")"

IMAGENES=0; FORZAR_UV=0; SI=0
for arg in "$@"; do
  case "$arg" in
    --imagenes)  IMAGENES=1 ;;
    --forzar-uv) FORZAR_UV=1 ;;
    --si)        SI=1 ;;
    *) echo "Opción desconocida: $arg"; exit 1 ;;
  esac
done

ok()   { echo "   [ok] $*"; }
info() { echo "   [--] $*"; }
warn() { echo "   [!!] $*"; }

if [ "$SI" -eq 0 ]; then
  echo "Esto detendrá Airflow y borrará sus contenedores, volúmenes (base de datos incluida)"
  echo "y lo que instalaron los scripts. ¿Continuar? [s/N]"
  read -r resp
  [[ "$resp" =~ ^[sS]$ ]] || { echo "Cancelado."; exit 0; }
fi

# 1. Worker sin Docker -----------------------------------------------------------
echo ">> 1. Worker de iniciar_worker.sh"
if pgrep -u "$USER" -f "airflow celery worker" >/dev/null 2>&1; then
  pkill -u "$USER" -f "airflow celery worker"; sleep 3
  pkill -9 -u "$USER" -f "airflow celery worker" 2>/dev/null
  ok "worker detenido"
else
  info "no estaba corriendo"
fi

# 2. Docker ------------------------------------------------------------------------
echo ">> 2. Docker"
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  for proyecto in airflow airflow-worker; do
    filtro="label=com.docker.compose.project=$proyecto"
    c=$(docker ps -aq --filter "$filtro")
    [ -n "$c" ] && docker rm -f $c >/dev/null && ok "contenedores de '$proyecto' borrados"
    v=$(docker volume ls -q --filter "$filtro")
    [ -n "$v" ] && docker volume rm $v >/dev/null && ok "volúmenes de '$proyecto' borrados"
    n=$(docker network ls -q --filter "$filtro")
    [ -n "$n" ] && docker network rm $n >/dev/null && ok "redes de '$proyecto' borradas"
  done
  if [ "$IMAGENES" -eq 1 ]; then
    for img in apache/airflow:3.1.5 postgres:16 rabbitmq:3.13-management; do
      docker image rm "$img" >/dev/null 2>&1 && ok "imagen $img borrada"
    done
  else
    info "imágenes conservadas (usa --imagenes para borrarlas)"
  fi
else
  info "Docker no está disponible para este usuario: nada que limpiar"
fi

# 3. uv ----------------------------------------------------------------------------
echo ">> 3. uv"
if [ -f .uv_instalado_por_script ] || [ "$FORZAR_UV" -eq 1 ]; then
  rm -f "$HOME/.local/bin/uv" "$HOME/.local/bin/uvx" \
        "$HOME/.local/bin/env" "$HOME/.local/bin/env.fish"
  rm -rf "$HOME/.local/share/uv" "$HOME/.cache/uv"
  rm -f "$HOME/.config/fish/conf.d/uv.env.fish"
  # Versiones viejas del script dejaban esta línea en los archivos de la shell
  for rc in "$HOME/.bashrc" "$HOME/.profile" "$HOME/.bash_profile" "$HOME/.zshrc" "$HOME/.zshenv"; do
    if [ -f "$rc" ] && grep -qxF '. "$HOME/.local/bin/env"' "$rc"; then
      cp "$rc" "$rc.bak-airflow"
      grep -vxF '. "$HOME/.local/bin/env"' "$rc.bak-airflow" > "$rc"
      ok "línea de uv quitada de $rc (copia en $rc.bak-airflow)"
    fi
  done
  rm -f .uv_instalado_por_script
  ok "uv y su Python borrados"
else
  info "uv no lo instaló este script: se conserva (usa --forzar-uv si quieres borrarlo)"
fi

# 4. Archivos generados en el repo -------------------------------------------------
echo ">> 4. Archivos generados en el repo"
borrar=(.venv logs airflow.cfg webserver_config.py worker.out config/airflow.cfg dags/__pycache__)
for f in "${borrar[@]}"; do
  if [ -e "$f" ]; then
    if rm -rf "$f" 2>/dev/null; then ok "$f"; else warn "$f no se pudo borrar (lo creó Docker con otro usuario)"; fi
  fi
done
rm -f ./*.generated 2>/dev/null
for d in plugins config; do rmdir "$d" 2>/dev/null && ok "carpeta vacía $d"; done

echo
echo ">> Listo."
echo "   - Si abriste puertos con ufw, revísalos con:  sudo ufw status numbered"
echo "   - Si algo de logs/ no se pudo borrar:         sudo rm -rf logs"
echo "   - Para terminar, puedes borrar la carpeta del repo (contiene tu .env)."
