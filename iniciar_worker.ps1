# Worker de Airflow (CeleryExecutor) para WINDOWS, usando Docker Desktop.
# Airflow no corre nativo en Windows: este script valida la configuracion,
# prueba la conexion con el maestro y levanta docker-compose.worker.yaml.
#
# Uso (PowerShell, en la carpeta del repo):
#   .\iniciar_worker.ps1            -> levanta el worker en segundo plano
#   .\iniciar_worker.ps1 -Logs      -> ademas muestra sus logs en vivo (Ctrl+C para salir de los logs)
#   .\iniciar_worker.ps1 -Detener   -> detiene el worker
#
# Si Windows bloquea el script:
#   powershell -ExecutionPolicy Bypass -File .\iniciar_worker.ps1

param(
    [switch]$Logs,
    [switch]$Detener
)

$ErrorActionPreference = "Stop"
Set-Location -Path $PSScriptRoot
$compose = "docker-compose.worker.yaml"

if ($Detener) {
    docker compose -f $compose down
    Write-Host ">> Worker detenido." -ForegroundColor Yellow
    exit 0
}

# 1. Leer .env
if (-not (Test-Path ".env")) {
    Write-Host "ERROR: no existe .env. Crealo con:  Copy-Item .env.example .env  y rellenalo." -ForegroundColor Red
    exit 1
}
$envVars = @{}
Get-Content ".env" | ForEach-Object {
    if ($_ -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') {
        $envVars[$Matches[1]] = $Matches[2].Trim().Trim('"').Trim("'")
    }
}

$faltan = @("MASTER_IP", "WORKER_IP", "AIRFLOW_FERNET_KEY", "AIRFLOW_JWT_SECRET") |
    Where-Object { -not $envVars[$_] }
if ($faltan) {
    Write-Host "ERROR: faltan en .env: $($faltan -join ', ')" -ForegroundColor Red
    exit 1
}
$master = $envVars["MASTER_IP"]

# 2. Docker Desktop encendido
docker info *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Docker no responde. Abre Docker Desktop y espera a que inicie." -ForegroundColor Red
    exit 1
}

# 3. Probar conexion con el maestro
Write-Host ">> Probando conexion con el maestro $master ..." -ForegroundColor Cyan
$ok = $true
$pgPort = if ($envVars["POSTGRES_PORT"]) { [int]$envVars["POSTGRES_PORT"] } else { 5433 }
foreach ($puerto in $pgPort, 5672, 8080) {
    $r = Test-NetConnection -ComputerName $master -Port $puerto -WarningAction SilentlyContinue
    if ($r.TcpTestSucceeded) {
        Write-Host "   puerto $puerto OK" -ForegroundColor Green
    } else {
        Write-Host "   puerto $puerto SIN CONEXION" -ForegroundColor Red
        $ok = $false
    }
}
if (-not $ok) {
    Write-Host "ERROR: no se llega al maestro. Revisa que su compose este arriba, su firewall y la IP." -ForegroundColor Red
    exit 1
}

# 4. Carpetas que no vienen en git
"dags", "logs", "plugins", "config" | ForEach-Object {
    if (-not (Test-Path $_)) { New-Item -ItemType Directory -Path $_ | Out-Null }
}

# 5. Levantar el worker
Write-Host ">> Levantando worker ($($envVars['WORKER_IP'])) | colas: $($envVars['WORKER_QUEUES'])" -ForegroundColor Cyan
docker compose -f $compose up -d
if ($LASTEXITCODE -ne 0) { exit 1 }

Write-Host ">> Worker en marcha. Verificalo en Flower: http://$($master):5555" -ForegroundColor Green
Write-Host "   Ver logs:  .\iniciar_worker.ps1 -Logs    |    Detener:  .\iniciar_worker.ps1 -Detener"

if ($Logs) {
    docker compose -f $compose logs -f
}
