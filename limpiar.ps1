# Deshace en WINDOWS todo lo que agregan este repo y sus instrucciones,
# para dejar el PC como estaba. Sirve tanto en el maestro como en un worker.
#
# Que limpia:
#   1. Docker: contenedores, volumenes y redes de los proyectos "airflow" (maestro)
#      y "airflow-worker" (worker). OJO: borra la base de datos de Airflow.
#   2. Reglas de firewall "Airflow maestro" y "Airflow worker logs"
#      (necesita PowerShell como administrador; si no, avisa y sigue).
#   3. Archivos generados dentro del repo (logs, config/airflow.cfg...).
#   4. Te muestra el perfil de tu red por si lo cambiaste a Private.
#
# Uso (PowerShell en la carpeta del repo):
#   .\limpiar.ps1              limpieza normal
#   .\limpiar.ps1 -Imagenes    ademas borra las imagenes de Docker (airflow, postgres, rabbitmq)
#   .\limpiar.ps1 -Si          no pide confirmacion
#
# Si Windows bloquea el script:
#   powershell -ExecutionPolicy Bypass -File .\limpiar.ps1
#
# No borra: el .env, tus DAGs ni la carpeta del repo (borrala a mano al final si quieres).

param(
    [switch]$Imagenes,
    [switch]$Si
)

Set-Location -Path $PSScriptRoot

function Ok($m)   { Write-Host "   [ok] $m" -ForegroundColor Green }
function Info($m) { Write-Host "   [--] $m" -ForegroundColor Gray }
function Warn($m) { Write-Host "   [!!] $m" -ForegroundColor Yellow }

if (-not $Si) {
    Write-Host "Esto borrara los contenedores y volumenes de Airflow (base de datos incluida),"
    Write-Host "y las reglas de firewall creadas para el cluster."
    $r = Read-Host "Continuar? [s/N]"
    if ($r -notmatch '^[sS]$') { Write-Host "Cancelado."; exit 0 }
}

# 1. Docker -------------------------------------------------------------------
Write-Host ">> 1. Docker" -ForegroundColor Cyan
docker info *> $null
if ($LASTEXITCODE -eq 0) {
    foreach ($proyecto in "airflow", "airflow-worker") {
        $filtro = "label=com.docker.compose.project=$proyecto"
        $c = docker ps -aq --filter $filtro
        if ($c) { docker rm -f $c | Out-Null; Ok "contenedores de '$proyecto' borrados" }
        $v = docker volume ls -q --filter $filtro
        if ($v) { docker volume rm $v | Out-Null; Ok "volumenes de '$proyecto' borrados" }
        $n = docker network ls -q --filter $filtro
        if ($n) { docker network rm $n | Out-Null; Ok "redes de '$proyecto' borradas" }
    }
    if ($Imagenes) {
        foreach ($img in "apache/airflow:3.1.5", "postgres:16", "rabbitmq:3.13-management") {
            docker image rm $img *> $null
            if ($LASTEXITCODE -eq 0) { Ok "imagen $img borrada" }
        }
    } else {
        Info "imagenes conservadas (usa -Imagenes para borrarlas)"
    }
} else {
    Warn "Docker no responde: abre Docker Desktop y vuelve a ejecutar para limpiar contenedores"
}

# 2. Firewall -----------------------------------------------------------------
Write-Host ">> 2. Firewall" -ForegroundColor Cyan
$esAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
foreach ($regla in "Airflow maestro", "Airflow worker logs") {
    $existe = Get-NetFirewallRule -DisplayName $regla -ErrorAction SilentlyContinue
    if (-not $existe) { Info "regla '$regla' no existe"; continue }
    if ($esAdmin) {
        Remove-NetFirewallRule -DisplayName $regla
        Ok "regla '$regla' borrada"
    } else {
        Warn "regla '$regla' existe, pero hace falta PowerShell como ADMINISTRADOR para borrarla"
    }
}

# 3. Archivos generados en el repo -------------------------------------------
Write-Host ">> 3. Archivos generados en el repo" -ForegroundColor Cyan
foreach ($f in "logs", "config\airflow.cfg", "dags\__pycache__", "airflow.cfg", "webserver_config.py") {
    if (Test-Path $f) {
        Remove-Item -Recurse -Force $f -ErrorAction SilentlyContinue
        if (Test-Path $f) { Warn "$f no se pudo borrar" } else { Ok $f }
    }
}
foreach ($d in "plugins", "config") {
    if ((Test-Path $d) -and -not (Get-ChildItem $d -Force)) { Remove-Item $d; Ok "carpeta vacia $d" }
}

# 4. Perfil de red ------------------------------------------------------------
Write-Host ">> 4. Perfil de red" -ForegroundColor Cyan
Get-NetConnectionProfile | ForEach-Object {
    Info "$($_.Name) ($($_.InterfaceAlias)): $($_.NetworkCategory)"
}
Info "Si cambiaste una red a Private solo para esto, devuelvela a Public (como administrador):"
Info '   Set-NetConnectionProfile -InterfaceAlias "Wi-Fi" -NetworkCategory Public'

Write-Host ""
Write-Host ">> Listo. Para terminar, puedes borrar la carpeta del repo (contiene tu .env)." -ForegroundColor Green
