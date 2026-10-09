# Airflow distribuido con Celery + RabbitMQ

Clúster de **Apache Airflow 3.1.5** que reparte la ejecución de tareas entre varios computadores de la misma red.

- **CeleryExecutor**: el scheduler no ejecuta las tareas, las deja en una cola.
- **RabbitMQ** es el *broker*, el "buzón" donde quedan las tareas pendientes.
- **PostgreSQL** guarda la metadata de Airflow y el resultado de cada tarea.
- **Workers**: procesos que toman tareas de la cola y las ejecutan. Pueden estar en cualquier PC que llegue al maestro.

Un PC hace de **maestro** (Postgres, RabbitMQ, scheduler, API/UI, Flower y un worker propio) y los demás se suman como **workers**.

> Proyecto de laboratorio/aprendizaje. No usar tal cual en producción: hay contraseñas por defecto y los puertos quedan abiertos en la red local.

---

## Contenido

1. [Cómo funciona](#cómo-funciona)
2. [Estructura del repo](#estructura-del-repo)
3. [Requisitos](#requisitos)
4. [Configuración (.env)](#configuración-env)
5. [Levantar el maestro](#levantar-el-maestro)
6. [Agregar workers](#agregar-workers)
7. [Verificar que todo funciona](#verificar-que-todo-funciona)
8. [Uso diario](#uso-diario)
9. [Mandar tareas a un worker concreto](#mandar-tareas-a-un-worker-concreto)
10. [Red y firewall](#red-y-firewall)
11. [Solución de problemas](#solución-de-problemas)
12. [Desinstalar / limpiar](#desinstalar--limpiar)

---

## Cómo funciona

1. El **scheduler** (en el maestro) decide qué tarea toca y la publica en **RabbitMQ**.
2. Cualquier **worker** libre, sea del maestro o de otro PC, la toma de la cola y la ejecuta.
3. El worker reporta el estado a la **API** y a **Postgres** del maestro.
4. La UI de Airflow muestra el resultado, y **Flower** muestra qué worker hizo qué.

Cada worker necesita llegar al maestro por estos puertos:

| Puerto | Servicio | Quién lo usa |
|---|---|---|
| `5433` | PostgreSQL (`POSTGRES_PORT`; dentro de Docker es 5432) | Workers → maestro |
| `5672` | RabbitMQ (AMQP) | Workers → maestro |
| `8080` | API / UI de Airflow | Workers → maestro, y tu navegador |
| `5555` | Flower (monitoreo de Celery) | Tu navegador |
| `15672` | Panel web de RabbitMQ | Tu navegador |
| `8793` | Logs de cada worker | Maestro → worker (opcional, para ver logs en la UI) |

---

## Estructura del repo

```
.
├── docker-compose.yaml          # MAESTRO: Postgres, RabbitMQ, Airflow, worker local y Flower
├── docker-compose.worker.yaml   # WORKER con Docker (Windows o Linux)
├── iniciar_worker.ps1           # Lanza el worker con Docker en Windows
├── iniciar_worker.sh            # Lanza el worker en Linux SIN Docker y SIN sudo
├── limpiar.ps1                  # Deshace todo en Windows
├── limpiar.sh                   # Deshace todo en Linux
├── .env.example                 # Plantilla de configuración (copiar a .env)
├── dags/                        # Tus DAGs (deben ser IGUALES en todas las máquinas)
├── .gitignore / .gitattributes
└── README.md
```

Lo siguiente se genera al usarlo y **no se sube a git**: `.env` (tiene secretos), `logs/`, `config/airflow.cfg`, `.venv/` y `airflow.cfg`.

---

## Requisitos

| Rol | Sistema | Necesita |
|---|---|---|
| Maestro | Windows o Linux | Docker (Docker Desktop en Windows), ~4 GB de RAM libres |
| Worker | Windows | Docker Desktop |
| Worker | Linux con Docker | Docker + Docker Compose |
| Worker | Linux **sin** Docker ni sudo | `bash` y `curl` (el script instala lo demás en tu usuario) |

Además, **todas las máquinas deben poder verse en la red** (ver [Red y firewall](#red-y-firewall)), y todas usan **la misma carpeta `dags/`**: clona el mismo repo en cada una.

---

## Configuración (.env)

Cada máquina tiene su propio `.env`, creado a partir de la plantilla:

```bash
cp .env.example .env               # Linux
Copy-Item .env.example .env        # Windows (PowerShell)
```

| Variable | Dónde | Descripción |
|---|---|---|
| `AIRFLOW_FERNET_KEY` | **Todas (igual)** | Clave para cifrar conexiones y contraseñas de Airflow |
| `AIRFLOW_JWT_SECRET` | **Todas (igual)** | Secreto con el que se firman los tokens entre workers y API |
| `RABBITMQ_DEFAULT_USER` / `_PASS` | **Todas (igual)** | Credenciales de RabbitMQ (por defecto `rabbit` / `rabbit`) |
| `POSTGRES_PORT` | **Todas (igual)** | Puerto del Postgres del maestro en la red (por defecto `5433`) |
| `AIRFLOW_UID` | Maestro / workers con Docker | `50000` en Windows; en Linux pon el resultado de `id -u` |
| `AIRFLOW__DAG_PROCESSOR__BUNDLE_REFRESH_CHECK_INTERVAL` | Maestro | Cada cuántos **segundos** busca cambios en los DAGs (`60` = 1 minuto) |
| `_AIRFLOW_WWW_USER_USERNAME` / `_PASSWORD` | Maestro | Usuario de la UI (por defecto `airflow` / `airflow`) |
| `MASTER_IP` | Workers | IP privada del maestro |
| `WORKER_IP` | Workers con Docker | IP privada de **ese** worker |
| `WORKER_QUEUES` | Workers | Colas que atiende, separadas por coma (por defecto `default`) |

### Generar las claves (una sola vez)

Genera las claves en una máquina y **copia los mismos valores** en el `.env` de todas:

```bash
# AIRFLOW_FERNET_KEY (termina en "=", es normal: no lo borres)
docker run --rm apache/airflow:3.1.5 python -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"

# AIRFLOW_JWT_SECRET
docker run --rm apache/airflow:3.1.5 python -c "import secrets; print(secrets.token_hex(32))"
```

El `.env` nunca se sube a git. Pásale las claves a tu compañero por un canal privado.

### Saber la IP de una máquina

- **Windows:** `ipconfig`, en la "Dirección IPv4" del adaptador Wi-Fi o Ethernet.
- **Linux:** `ip a | grep "inet "`, en la línea del adaptador `wl...` (Wi-Fi) o `en...` (cable).

---

## Levantar el maestro

```bash
git clone <url-del-repo>
cd <carpeta-del-repo>
cp .env.example .env          # y rellénalo: claves; MASTER_IP se deja vacía
docker compose up -d
```

En **Linux**, además, antes del `up`:

```bash
mkdir -p dags logs plugins config
sed -i "s/^AIRFLOW_UID=.*/AIRFLOW_UID=$(id -u)/" .env
```

Espera uno o dos minutos y revisa:

```bash
docker compose ps
```

Todos los servicios deben quedar en `running (healthy)`. `airflow-init` termina solo; es normal que no aparezca o que salga como `exited (0)`.

Luego **abre los puertos en el firewall** del maestro (ver [Red y firewall](#red-y-firewall)).

| Servicio | URL (en el maestro) | Usuario |
|---|---|---|
| UI de Airflow | http://localhost:8080 | `airflow` / `airflow` |
| Flower | http://localhost:5555 | — |
| RabbitMQ | http://localhost:15672 | `rabbit` / `rabbit` |

---

## Agregar workers

En todos los casos: clona el repo, crea el `.env` con **las mismas claves** que el maestro y pon `MASTER_IP` con la IP del maestro.

### Opción A: Windows (Docker Desktop)

1. En el `.env`, completa `MASTER_IP` y `WORKER_IP` (la IP de este PC).
2. Abre Docker Desktop.
3. Ejecuta en PowerShell, en la carpeta del repo:

   ```powershell
   .\iniciar_worker.ps1 -Logs
   ```

   El script revisa el `.env`, prueba la conexión con el maestro (puertos 5433, 5672 y 8080) y levanta el worker.

   - Solo levantarlo, sin ver logs: `.\iniciar_worker.ps1`
   - Detenerlo: `.\iniciar_worker.ps1 -Detener`
   - Si Windows bloquea el script: `powershell -ExecutionPolicy Bypass -File .\iniciar_worker.ps1`

4. *(Opcional, para ver los logs de este worker en la UI)* Abre el puerto 8793 en PowerShell como administrador:

   ```powershell
   New-NetFirewallRule -DisplayName "Airflow worker logs" -Direction Inbound -Protocol TCP -LocalPort 8793 -Action Allow -RemoteAddress LocalSubnet -Profile Private
   ```

### Opción B: Linux con Docker

```bash
mkdir -p dags logs plugins config
sed -i "s/^AIRFLOW_UID=.*/AIRFLOW_UID=$(id -u)/" .env
# en .env: MASTER_IP y WORKER_IP
docker compose -f docker-compose.worker.yaml up -d
docker compose -f docker-compose.worker.yaml logs -f      # ver logs (Ctrl+C sale de los logs)
docker compose -f docker-compose.worker.yaml down         # detenerlo
```

### Opción C: Linux sin Docker y sin sudo (Ubuntu, Mint…)

Para PCs donde no tienes permisos de administrador. Todo se instala en tu usuario, con [uv](https://docs.astral.sh/uv/) y su propio Python, sin tocar el sistema.

```bash
# en .env: MASTER_IP (WORKER_IP no hace falta aquí)
./iniciar_worker.sh
```

- La primera vez tarda varios minutos, porque instala uv, Python 3.12 y Airflow. Las siguientes arranca directo.
- Ocupa la terminal mientras corre. Para detenerlo usa **`Ctrl+C`** (dos veces para forzar). Para seguir usando la terminal, abre otra pestaña con `Ctrl+Shift+T`.
- En segundo plano: `nohup ./iniciar_worker.sh > worker.out 2>&1 &`, y se detiene con `pkill -f "airflow celery worker"`.
- Si sale `Permission denied`: `chmod +x iniciar_worker.sh`.
- Para ver más detalle en la terminal, agrega al `.env`: `AIRFLOW__LOGGING__CELERY_LOGGING_LEVEL=INFO`.

---

## Verificar que todo funciona

1. Abre **Flower** en el maestro (http://localhost:5555). Debe haber **un worker por máquina**, todos *Online*. El del maestro tiene como nombre el ID del contenedor; los de Docker, la `WORKER_IP`.
2. En la UI de Airflow, activa un DAG y ejecútalo con *Trigger*.
3. En Flower, en *Tasks*, verás qué worker ejecutó cada tarea.

---

## Uso diario

| Acción | Maestro | Worker Windows | Worker Linux (script) |
|---|---|---|---|
| Encender | `docker compose up -d` | `.\iniciar_worker.ps1` | `./iniciar_worker.sh` |
| Apagar | `docker compose down` | `.\iniciar_worker.ps1 -Detener` | `Ctrl+C` |
| Estado | `docker compose ps` | `docker compose -f docker-compose.worker.yaml ps` | la terminal |

**Orden:** primero el maestro (y esperar a que esté *healthy*), después los workers.

- `docker compose down` **no** borra datos. `docker compose down -v` sí borra la base de datos y las colas.
- Para pausar sin borrar contenedores: `docker compose stop` / `docker compose start`.
- **Cambios en DAGs:** haz `git pull` en **todas** las máquinas. El maestro los detecta en hasta 60 segundos.
- **Cambios en el `.env` o en el compose:** vuelve a ejecutar `docker compose up -d`, que recrea lo que cambió.

---

## Mandar tareas a un worker concreto

Cada worker atiende las colas de su `WORKER_QUEUES`. Por ejemplo, con `WORKER_QUEUES=pc2` en un worker:

```python
from airflow.sdk import dag, task

@dag(schedule=None)
def mi_dag():
    @task(queue="pc2")          # solo la ejecuta el worker que atiende "pc2"
    def tarea_pesada(): ...

    @task                       # cola "default": la toma cualquier worker libre
    def tarea_normal(): ...

    tarea_pesada() >> tarea_normal()

mi_dag()
```

Un worker puede atender varias colas a la vez: `WORKER_QUEUES=default,pc2`.

---

## Red y firewall

### Firewall del maestro

**Windows** (PowerShell como administrador):

```powershell
New-NetFirewallRule -DisplayName "Airflow maestro" -Direction Inbound -Protocol TCP -LocalPort 5433,5672,8080,5555,15672 -Action Allow -RemoteAddress LocalSubnet -Profile Private
```

La regla solo aplica en redes marcadas como **Private**. Revísalo con `Get-NetConnectionProfile`, y si sale `Public`:

```powershell
Set-NetConnectionProfile -InterfaceAlias "Wi-Fi" -NetworkCategory Private
```

**Linux:** con Docker, los puertos publicados suelen quedar accesibles aunque `ufw` esté activo. Si no, abre los puertos así (ajusta la subred):

```bash
sudo ufw allow from 192.168.1.0/24 to any port 5433,5672,8080,5555,15672 proto tcp
```

**Deshacer:**

```powershell
Remove-NetFirewallRule -DisplayName "Airflow maestro"         # Windows
Disable-NetFirewallRule -DisplayName "Airflow maestro"        # o solo desactivarla
```
```bash
sudo ufw status numbered && sudo ufw delete <número>          # Linux
```

### Comprobar la conexión desde un worker

```powershell
Test-NetConnection IP_DEL_MAESTRO -Port 5672                  # Windows: debe dar TcpTestSucceeded : True
```
```bash
nc -zv -w 5 IP_DEL_MAESTRO 5672                               # Linux: debe decir "succeeded"
```

Repite con `5433` y `8080`.

### Redes que no dejan que los equipos se vean

Muchas redes de empresas, universidades o bootcamps **aíslan cada equipo**: todos salen a internet, pero no pueden hablar entre sí, aunque estén en la misma subred. Se reconoce porque:

- `Test-NetConnection` da `False`, o `nc` da `timed out`, aunque el firewall esté bien.
- Al hacer ping, Windows responde `DestinationHostUnreachable`.
- En Linux, `ip neigh show IP_DEL_OTRO` muestra `FAILED`.

Eso no se arregla desde los PCs. Las alternativas son:

1. **Hotspot del celular.** Conecta todos los PCs al mismo hotspot: el celular crea su propia red, donde los equipos sí se ven.
   - El tráfico **entre** los PCs no gasta datos móviles; solo lo que sale a internet.
   - **Descarga las imágenes antes**, en otra red, con `docker compose pull` (Airflow pesa más de 1 GB).
   - Al conectarte al hotspot, Windows marca la red como `Public`: cámbiala a `Private` en cada PC.
   - Las IPs cambian, así que actualiza `MASTER_IP` y `WORKER_IP`.
2. **Túnel SSH a través de un servidor en la nube** (por ejemplo, una EC2). Cada PC solo abre conexiones de salida hacia el servidor; funciona en cualquier red.
3. **Pedir a soporte de la red** que permita el tráfico entre las IPs en los puertos 5433, 5672 y 8080.

---

## Solución de problemas

| Síntoma | Causa probable | Solución |
|---|---|---|
| Flower muestra solo el worker del maestro | El worker no llega al maestro | Prueba los puertos (ver arriba); revisa firewall, IPs y aislamiento de red |
| `Connection timed out` hacia `MASTER_IP` | Firewall, IP equivocada o red aislada | Ver [Red y firewall](#red-y-firewall) |
| `Connection refused` | El maestro está apagado o no está *healthy* | `docker compose ps` en el maestro |
| El worker no aparece, aunque hay conexión | Claves distintas entre máquinas | `AIRFLOW_FERNET_KEY` y `AIRFLOW_JWT_SECRET` deben ser idénticas |
| `UnicodeDecodeError: 'utf-8' codec can't decode byte 0xed` al conectar | El worker llegó a **otro** PostgreSQL instalado en el maestro (mensajes en español), no al de Docker | Usa `POSTGRES_PORT=5433` (por defecto) en el `.env` de todas las máquinas |
| Una tarea falla con error de import | DAGs distintos entre máquinas | `git pull` en todas |
| La UI no muestra el log de una tarea de otro PC | El maestro no llega al puerto 8793 del worker | Abre el 8793 en el worker. Los logs igual quedan en su carpeta `logs/` |
| `Permission denied` al ejecutar el `.sh` | Falta permiso de ejecución | `chmod +x iniciar_worker.sh limpiar.sh` |
| `bash: ...\r: command not found` | El `.sh` tiene saltos de línea de Windows | Vuelve a clonar (`.gitattributes` lo evita) |
| Windows: "la ejecución de scripts está deshabilitada" | Política de ejecución | `powershell -ExecutionPolicy Bypass -File .\script.ps1` |
| Docker consume mucha RAM/CPU | Límites de WSL2 | Crea `C:\Users\<tu-usuario>\.wslconfig` con `memory=4GB` y `processors=2` en una sección `[wsl2]`, luego `wsl --shutdown` |

Para ver los logs de un servicio del maestro: `docker compose logs <servicio> --tail 50`, por ejemplo con `airflow-scheduler`.

---

## Desinstalar / limpiar

Para dejar el PC como estaba antes de usar el repo:

**Windows:** PowerShell **como administrador**, para que también borre las reglas del firewall:

```powershell
.\limpiar.ps1              # contenedores, volúmenes, redes, reglas de firewall y archivos generados
.\limpiar.ps1 -Imagenes    # además borra las imágenes de Docker
```

**Linux:**

```bash
./limpiar.sh               # worker, contenedores, volúmenes, uv (si lo instaló el script) y archivos generados
./limpiar.sh --imagenes    # además borra las imágenes de Docker
./limpiar.sh --forzar-uv   # borra uv aunque no se sepa si lo instaló el script
```

Los dos scripts:

- **Borran la base de datos de Airflow** (historial de ejecuciones, usuarios y conexiones).
- **No borran** tu `.env` ni tus DAGs. Al final puedes borrar la carpeta del repo a mano.
- **No cambian** el perfil de red. El de Windows te lo muestra y te da el comando por si lo cambiaste a `Private` solo para esto.
