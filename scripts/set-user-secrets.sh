#!/usr/bin/env bash
# Copies the infrastructure credentials from .env into each service's dotnet user-secrets,
# so no password is stored in the service repos. Run from MCSC6002_System after `docker compose up -d`.
# User secrets are loaded only when ASPNETCORE_ENVIRONMENT=Development (the launch profiles use it).
set -euo pipefail
cd "$(dirname "$0")/.."
source <(tr -d '\r' < .env)

sql() { echo "Server=127.0.0.1,1433;Database=$1;User Id=sa;Password=$SQL_SA_PASSWORD;Encrypt=True;TrustServerCertificate=True;"; }

set_secrets() {
  local project="$1"; shift
  dotnet user-secrets init --project "$project" > /dev/null
  while [ $# -gt 0 ]; do
    dotnet user-secrets set "$1" "$2" --project "$project" > /dev/null
    shift 2
  done
  echo "secrets set: $project"
}

set_secrets ../MCSC6002_IdentityService/IdentityService/WebApi \
  "ConnectionStrings:DefaultConnection" "$(sql MCSC6002_IdentityDB)"

set_secrets ../MCSC6002_ProductService/ProductService/WebApi \
  "ConnectionStrings:DefaultConnection" "$(sql MCSC6002_ProductDB)" \
  "RabbitMqSettings:UserName" "$RABBITMQ_USER" \
  "RabbitMqSettings:Password" "$RABBITMQ_PASSWORD" \
  "CacheSettings:DestinationUrl" "127.0.0.1:6379,password=$REDIS_PASSWORD"

set_secrets ../MCSC6002_InventoryService/InventoryService/WebApi \
  "ConnectionStrings:DefaultConnection" "$(sql MCSC6002_InventoryDB)" \
  "RabbitMqSettings:UserName" "$RABBITMQ_USER" \
  "RabbitMqSettings:Password" "$RABBITMQ_PASSWORD"
