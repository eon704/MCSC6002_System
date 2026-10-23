#!/usr/bin/env bash
# One-time setup on a fresh machine: JWT keys, mTLS certificates, .env with random passwords, user-secrets.
# Skips anything that already exists. Run from MCSC6002_System (Git Bash on Windows).
set -euo pipefail
cd "$(dirname "$0")/.."
export MSYS_NO_PATHCONV=1

for tool in openssl dotnet docker; do
  command -v "$tool" > /dev/null || { echo "missing: $tool"; exit 1; }
done
for repo in MCSC6002_ApiGateway MCSC6002_IdentityService MCSC6002_ProductService MCSC6002_InventoryService; do
  [ -d "../$repo" ] || { echo "missing ../$repo: clone all repos into one folder"; exit 1; }
done

KEYS=../keys
mkdir -p "$KEYS/tls"

if [ ! -f "$KEYS/jwt-private.pem" ]; then
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$KEYS/jwt-private.pem" 2> /dev/null
  openssl pkey -in "$KEYS/jwt-private.pem" -pubout -out "$KEYS/jwt-public.pem"
  echo "created JWT key pair"
fi

if [ ! -f "$KEYS/tls/ca.crt" ]; then
  (
    cd "$KEYS/tls"
    openssl req -x509 -new -newkey rsa:2048 -nodes -keyout ca.key -out ca.crt -days 825 -subj "/CN=MCSC6002 Dev CA" \
      -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" 2> /dev/null
    openssl req -new -newkey rsa:2048 -nodes -keyout service.key -out service.csr -subj "/CN=localhost" 2> /dev/null
    printf "basicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:localhost\n" > service.ext
    openssl x509 -req -in service.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out service.crt -days 825 -extfile service.ext 2> /dev/null
    openssl req -new -newkey rsa:2048 -nodes -keyout gateway-client.key -out gateway-client.csr -subj "/CN=api-gateway" 2> /dev/null
    printf "basicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=clientAuth\n" > client.ext
    openssl x509 -req -in gateway-client.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out gateway-client.crt -days 825 -extfile client.ext 2> /dev/null
    openssl pkcs12 -export -inkey service.key -in service.crt -out service.pfx -passout pass:
    openssl pkcs12 -export -inkey gateway-client.key -in gateway-client.crt -out gateway-client.pfx -passout pass:
    rm -f ./*.csr ./*.ext ca.srl
  )
  echo "created project CA, service and gateway certificates"
fi

# Letters and digits only, plus a fixed tail for SQL Server's complexity rule; no ; or , (connection strings).
secret() { echo "$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20)Aa1-"; }

if [ ! -f .env ]; then
  cat > .env <<EOF
SQL_SA_PASSWORD=$(secret)
RABBITMQ_USER=mcsc6002
RABBITMQ_PASSWORD=$(secret)
REDIS_PASSWORD=$(secret)
MESSAGE_SIGNING_KEY=$(openssl rand -base64 32)
SEED_ADMIN_PASSWORD=$(secret)
SEED_BASIC_PASSWORD=$(secret)
EOF
  echo "created .env with random passwords (seeded users: admin@cloudbase.com, basic@cloudbase.com)"
fi

bash scripts/set-user-secrets.sh
echo "setup done; next: bash scripts/run.sh"
