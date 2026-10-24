#!/usr/bin/env bash
# Live demo, one step per Enter. Each step prints the request, the response, why it happened and,
# where a service logs it, the log line as evidence. Passwords and tokens are masked on screen.
# Prerequisite: bash scripts/run.sh. Usage (from MCSC6002_System): bash scripts/demo.sh
set -u
source <(tr -d '\r' < .env)
G=https://localhost:7000
BODY=$(mktemp); trap 'rm -f "$BODY"' EXIT
B=$'\e[1m'; DIM=$'\e[2m'; CY=$'\e[36m'; GR=$'\e[32m'; RD=$'\e[31m'; YE=$'\e[33m'; N=$'\e[0m'

json() { python -c "import sys,json; d=json.load(sys.stdin); print($1)"; }
step() { echo; echo "${B}━━ $1 ━━${N}"; read -rs; }
show() { echo "${CY}\$ $1${N}"; }
why() { echo "${YE}Why:${N} $1"; }
mask() { echo "${1:0:20}…"; }

# call METHOD PATH TOKEN BODY: request through the gateway; prints the status and a short body.
call() {
  local args=(-sk -o "$BODY" -w "%{http_code}" -X "$1" "$G$2")
  [ -n "$3" ] && args+=(-H "Authorization: Bearer $3")
  [ -n "$4" ] && args+=(-H "Content-Type: application/json" -d "$4")
  CODE=$(curl "${args[@]}")
  local color=$GR; [ "$CODE" -ge 400 ] && color=$RD
  local text; text=$(head -c 110 "$BODY"); [ -z "$text" ] && text="(empty body)"
  echo "${color}← HTTP $CODE${N}  ${DIM}${text}${N}"
}

# evidence SERVICE MARK PATTERN: first matching line the container logged since time MARK (waits up to 10 s).
mark() { date -u -d '-1 sec' +%Y-%m-%dT%H:%M:%SZ; } # 1 s margin for clock skew with Docker.
evidence() {
  local hit=""
  for _ in $(seq 10); do
    hit=$(docker compose logs "$1" --no-log-prefix --since "$2" 2> /dev/null | grep -a -m1 "$3" | sed 's/^ *//')
    [ -n "$hit" ] && break; sleep 1
  done
  echo "${DIM}$1 log:${N} ${hit:-(no log line)}"
}

login() { curl -sk -X POST -H "Content-Type: application/json" -d "{\"userName\":\"$1\",\"password\":\"$2\"}" $G/auth/login | json "(d.get('data') or {}).get('token', '')" 2> /dev/null; }
# need_token TOKEN USER: stop with a fix instead of tracebacks when a login fails.
need_token() {
  [ -n "$1" ] && return
  echo "${RD}Login failed for $2.${N} Wait a minute (5 logins per minute per IP) and run the demo again."
  echo "On a fresh setup over an old data volume, reset it (deletes all data): docker compose down -v, then bash scripts/run.sh"
  exit 1
}

curl -sk -o /dev/null -m 5 "$G/" || { echo "${RD}Gateway not reachable at $G.${N} Start the system first: bash scripts/run.sh"; exit 1; }
claims() { echo "$1" | python -c "
import sys,json,base64
h,p,_=sys.stdin.read().strip().split('.'); dec=lambda s: json.loads(base64.urlsafe_b64decode(s+'=='))
$2"; }

step "Step 1 · Admin logs in through the gateway"
show "curl -X POST $G/auth/login -d '{\"userName\":\"admin@cloudbase.com\",\"password\":\"••••\"}'"
ADMIN=$(login admin@cloudbase.com "$SEED_ADMIN_PASSWORD"); need_token "$ADMIN" admin@cloudbase.com
echo "${GR}← HTTP 200${N}  ${DIM}{\"token\":\"$(mask "$ADMIN")\",\"refreshToken\":\"••••\", ...}${N}"
claims "$ADMIN" "
import time; pl=dec(p); r=pl['http://schemas.microsoft.com/ws/2008/06/identity/claims/role']
print('token header: ', dec(h))
print('token payload:', pl['http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress'], '| roles', ', '.join(r if isinstance(r, list) else [r]), '|', len(pl['permission']), 'permissions | expires in', round((pl['exp']-time.time())/60), 'min')"
why "Only Identity holds the RSA private key; the gateway and services verify the signature with the public key."

step "Step 2 · Basic user tries to create a product"
show "curl -X POST $G/auth/login -d '{\"userName\":\"basic@cloudbase.com\",\"password\":\"••••\"}'"
BASIC=$(login basic@cloudbase.com "$SEED_BASIC_PASSWORD"); need_token "$BASIC" basic@cloudbase.com
LOGIN_AT=$SECONDS
echo "${GR}← HTTP 200${N}  ${DIM}{\"token\":\"$(mask "$BASIC")\", ...}${N}"
claims "$BASIC" "print('basic user may:', ', '.join(x.removeprefix('Permission.') for x in dec(p)['permission']))"
BRAND=$(curl -sk -H "Authorization: Bearer $ADMIN" $G/product-service/brands/all | json "(d.get('data') or [{}])[0].get('id', '')" 2> /dev/null)
# A fresh database has no brands, and Product answers 400 to an empty list: create one.
[ -n "$BRAND" ] || BRAND=$(curl -sk -X POST -H "Authorization: Bearer $ADMIN" -H "Content-Type: application/json" \
  -d '{"name":"Demo brand","description":"live demo"}' $G/product-service/brands/create | json "d['data']")
PRODUCT="{\"brandId\":$BRAND,\"name\":\"Demo widget\",\"description\":\"live demo\",\"quantity\":3,\"reOrderThreshold\":1}"
show "curl -X POST $G/product-service/products/create -H \"Authorization: Bearer $(mask "$BASIC")\" -d '$PRODUCT'"
M=$(mark)
call POST /product-service/products/create "$BASIC" "$PRODUCT"
evidence gateway "$M" "ClaimValueNotAuthorizedError" | sed 's/claim value: .* is not the same as/… is not the same as/'
why "The route needs Products.Create. The gateway refuses before Product is called; Product would check it again."

step "Step 3 · Admin creates a product (quantity 3); Inventory gets the signed event"
show "curl -X POST $G/product-service/products/create -H \"Authorization: Bearer $(mask "$ADMIN")\" -d '$PRODUCT'"
M=$(mark)
call POST /product-service/products/create "$ADMIN" "$PRODUCT"
ID=$(json "d['data']" < "$BODY")
evidence inventory "$M" "Product $ID created"
show "curl $G/inventory-service/items/get-by-product-id/$ID -H \"Authorization: Bearer $(mask "$ADMIN")\""
call GET /inventory-service/items/get-by-product-id/$ID "$ADMIN" ""
json "f\"{len(d['data'])} stock items: \" + ', '.join(i['barcode'] for i in d['data'])" < "$BODY"
why "Product published a signed ProductCreated event to RabbitMQ; Inventory checked the signature, then created one item per unit."

step "Step 4 · Basic user edits the token to add the Create permission"
TAMPERED=$(echo "$BASIC" | python -c "
import sys,base64
h,p,s=sys.stdin.read().strip().split('.'); raw=base64.urlsafe_b64decode(p+'==').decode()
print(h+'.'+base64.urlsafe_b64encode(raw.replace('Products.Read','Products.Create').encode()).decode().rstrip('=')+'.'+s)")
echo "payload edit: \"Permission.Product.Products.Read\" → \"Permission.Product.Products.Create\"; signature kept as it was"
show "curl -X POST $G/product-service/products/create -H \"Authorization: Bearer $(mask "$TAMPERED")\" -d '$PRODUCT'"
M=$(mark)
call POST /product-service/products/create "$TAMPERED" "$PRODUCT"
evidence gateway "$M" "UnauthenticatedError: Request" | sed 's/Client has NOT been authenticated.* \(UnauthenticatedError\)/\1/'
why "The RS256 signature covers the header and payload; any edit breaks it, and only Identity's private key can re-sign."

step "Step 5 · Direct call to the Product service, skipping the gateway"
show "curl -k https://localhost:7280/api/products/all      # Product's own port, no client certificate"
ERR=$(curl -ksS -m 10 https://localhost:7280/api/products/all 2>&1 >/dev/null); EXIT=$?
echo "${RD}← curl exit $EXIT${N}  ${DIM}${ERR}${N}"
show "curl $G/product-service/products/all -H \"Authorization: Bearer $(mask "$ADMIN")\"      # same request through the gateway"
call GET /product-service/products/all "$ADMIN" ""
why "Services accept only the client certificate our CA issued to the gateway (mutual TLS); anything else fails the TLS handshake."

step "Step 6 · Attacker with RabbitMQ credentials publishes an unsigned event (quantity 3)"
FAKE=$((900000 + RANDOM))
EXCHANGE="ResponseLibrary.Models.Requests.Product.Events:ProductCreatedEvent"
errors() { curl -s -u "$RABBITMQ_USER:$RABBITMQ_PASSWORD" http://127.0.0.1:15672/api/queues/%2F/ProductCreatedEventQueue_error | json "d.get('messages', 0)"; }
BEFORE=$(errors)
EVENT="{\"Id\":$FAKE,\"Name\":\"forged\",\"Quantity\":3,\"ReOrderThreshold\":0}"
echo "event body: $EVENT   (no signature headers)"
show "curl -u $RABBITMQ_USER:•••• -X POST http://127.0.0.1:15672/api/exchanges/%2F/$EXCHANGE/publish -d '{...event...}'"
M=$(mark)
python -c "
import json,uuid
evt=json.loads('$EVENT')
env={'messageId':str(uuid.uuid4()),'messageType':['urn:message:ResponseLibrary.Models.Requests.Product.Events:ProductCreatedEvent'],'message':evt,'headers':{}}
print(json.dumps({'properties':{'content_type':'application/vnd.masstransit+json','headers':{}},'routing_key':'','payload':json.dumps(env),'payload_encoding':'string'}))" |
curl -s -u "$RABBITMQ_USER:$RABBITMQ_PASSWORD" -H "Content-Type: application/json" -d @- \
  "http://127.0.0.1:15672/api/exchanges/%2F/$EXCHANGE/publish" > "$BODY"
echo "${GR}← $(cat "$BODY")${N}  ${DIM}(RabbitMQ accepted and delivered it)${N}"
evidence inventory "$M" "Rejected ProductCreatedEvent"
show "curl $G/inventory-service/items/get-by-product-id/$FAKE -H \"Authorization: Bearer $(mask "$ADMIN")\""
call GET /inventory-service/items/get-by-product-id/$FAKE "$ADMIN" ""
for _ in $(seq 10); do AFTER=$(errors); [ "$AFTER" -gt "$BEFORE" ] && break; sleep 1; done # Management stats lag ~5 s.
echo "error queue ProductCreatedEventQueue_error: $BEFORE → $AFTER messages"
why "Inventory checks the HMAC before any consumer runs; unsigned, altered or old events go to the error queue, not into stock."

step "Step 7 · Full attack suite (37 cases)"
WAIT=$((61 - (SECONDS - LOGIN_AT))); [ $WAIT -gt 0 ] && { echo "waiting ${WAIT}s for the login rate-limit window"; sleep $WAIT; }
show "dotnet run tests/AttackTests.cs"
dotnet run tests/AttackTests.cs | python -c "
import sys,re,collections
names={'A':'Authentication and access','N':'Service-to-service transport','V':'Input validation','M':'Messaging','I':'Information disclosure'}
runs=collections.OrderedDict((k,[0,0]) for k in names); last=''
for line in sys.stdin:
    m=re.match(r'(PASS|FAIL)\s+([A-Z])\d', line)
    if m: runs[m.group(2)][0]+=m.group(1)=='PASS'; runs[m.group(2)][1]+=1
    if 'passed.' in line: last=line.strip()
for k,(ok,n) in runs.items(): print(f'  {names[k]:30} {ok}/{n}')
print(last)"
why "Each case attacks one threat from the STRIDE model; together they cover tokens, access control, transport, input and messaging."
