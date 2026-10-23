#!/usr/bin/env bash
# Starts SQL Server, RabbitMQ and Redis in Docker, then the four services in the background (logs in logs/).
# Usage (from MCSC6002_System): bash scripts/run.sh | bash scripts/run.sh stop
set -euo pipefail
cd "$(dirname "$0")/.."

PORTS="7000 7284 7280 7148"

stop_services() {
  for port in $PORTS; do
    if command -v powershell > /dev/null; then
      powershell -NoProfile -Command "Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id \$_.OwningProcess -Force }" || true
    else
      lsof -ti "tcp:$port" | xargs -r kill || true
    fi
  done
}

if [ "${1:-}" = "stop" ]; then
  stop_services
  echo "services stopped; infrastructure still up (docker compose stop)"
  exit 0
fi

[ -f .env ] || { echo "no .env: run bash scripts/setup.sh first"; exit 1; }

# Waits until a pattern appears in a command's output.
wait_for() {
  local what="$1" pattern="$2" seconds="$3"; shift 3
  for _ in $(seq "$seconds"); do
    "$@" 2> /dev/null | grep -q "$pattern" && return 0
    sleep 1
  done
  echo "timed out waiting for $what"; exit 1
}

docker compose up -d
wait_for "SQL Server" "ready for client connections" 120 docker compose logs sqlserver
wait_for "RabbitMQ" "Server startup complete" 120 docker compose logs rabbitmq

stop_services
mkdir -p logs
start() {
  dotnet run --project "../$2" --launch-profile https > "logs/$1.log" 2>&1 &
}
start identity  MCSC6002_IdentityService/IdentityService/WebApi
start product   MCSC6002_ProductService/ProductService/WebApi
start inventory MCSC6002_InventoryService/InventoryService/WebApi
start gateway   MCSC6002_ApiGateway/ApiGateway

for service in identity:"Now listening" product:"Bus started" inventory:"Bus started" gateway:"Now listening"; do
  name="${service%%:*}"
  wait_for "$name (see logs/$name.log)" "${service#*:}\|Unhandled exception" 300 cat "logs/$name.log"
  if grep -q "Unhandled exception" "logs/$name.log"; then echo "$name failed: see logs/$name.log"; exit 1; fi
  echo "$name up"
done

echo "gateway: https://localhost:7000 | RabbitMQ UI: http://127.0.0.1:15672"
echo "next: bash scripts/demo.sh, or dotnet run tests/AttackTests.cs; stop: bash scripts/run.sh stop"
