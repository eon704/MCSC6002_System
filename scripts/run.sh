#!/usr/bin/env bash
# Builds and starts the whole system in Docker (infrastructure and the four services), then waits until it is ready.
# Usage (from MCSC6002_System): bash scripts/run.sh | bash scripts/run.sh stop
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "${1:-}" = "stop" ]; then
  docker compose stop
  exit 0
fi

[ -f .env ] || { echo "no .env: run bash scripts/setup.sh first"; exit 1; }

# Compose starts the services once SQL Server and RabbitMQ are healthy.
docker compose build --quiet
docker compose up -d

for service in identity:"Now listening" product:"Bus started" inventory:"Bus started" gateway:"Now listening"; do
  name="${service%%:*}"
  for _ in $(seq 120); do
    docker compose logs "$name" 2> /dev/null | grep -q "${service#*:}" && break
    sleep 1
  done
  docker compose logs "$name" 2> /dev/null | grep -q "${service#*:}" || { echo "$name not ready: docker compose logs $name"; exit 1; }
  echo "$name up"
done

echo "gateway: https://localhost:7000 | RabbitMQ UI: http://127.0.0.1:15672 | logs: docker compose logs <service>"
echo "next: bash scripts/demo.sh, or dotnet run tests/AttackTests.cs; stop: bash scripts/run.sh stop"
