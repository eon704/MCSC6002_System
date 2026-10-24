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

SERVER="keyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth"

# issue NAME CN EXTENSIONS: NAME.key and NAME.crt signed by the project CA (run inside $KEYS/tls).
issue() {
  openssl req -new -newkey rsa:2048 -nodes -keyout "$1.key" -out "$1.csr" -subj "/CN=$2" 2> /dev/null
  printf "basicConstraints=CA:FALSE\n$3\n" > "$1.ext"
  openssl x509 -req -in "$1.csr" -CA ca.crt -CAkey ca.key -CAcreateserial -out "$1.crt" -days 825 -extfile "$1.ext" 2> /dev/null
  rm -f "$1.csr" "$1.ext" ca.srl
}

# pfx NAME: NAME.pfx for .NET (no password), then drop the separate key and certificate.
pfx() {
  openssl pkcs12 -export -inkey "$1.key" -in "$1.crt" -out "$1.pfx" -passout pass:
  rm -f "$1.key" "$1.crt"
}

if [ ! -f "$KEYS/tls/ca.crt" ]; then
  (
    cd "$KEYS/tls"
    openssl req -x509 -new -newkey rsa:2048 -nodes -keyout ca.key -out ca.crt -days 825 -subj "/CN=MCSC6002 Dev CA" \
      -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" 2> /dev/null
    issue service localhost "$SERVER\nsubjectAltName=DNS:localhost" && pfx service
    issue gateway-client api-gateway "keyUsage=critical,digitalSignature\nextendedKeyUsage=clientAuth" && pfx gateway-client
  )
  echo "created project CA, service and gateway client certificates"
fi

# One server certificate per container, named for its Docker host name and localhost (host-side tests).
for name in identity product inventory gateway; do
  [ -f "$KEYS/tls/$name.pfx" ] && continue
  (cd "$KEYS/tls" && issue "$name" "$name" "$SERVER\nsubjectAltName=DNS:$name,DNS:localhost" && pfx "$name")
  echo "created $name server certificate"
done

# Reissued when it lacks the Docker host name (older key folders).
if ! openssl x509 -in "$KEYS/tls/rabbitmq.crt" -noout -ext subjectAltName 2> /dev/null | grep -q "DNS:rabbitmq"; then
  (cd "$KEYS/tls" && issue rabbitmq rabbitmq "$SERVER\nsubjectAltName=DNS:rabbitmq,DNS:localhost,IP:127.0.0.1")
  echo "created RabbitMQ certificate"
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
