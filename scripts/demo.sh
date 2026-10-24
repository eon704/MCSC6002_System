#!/usr/bin/env bash
# Live demo, one step per Enter. Prerequisite: bash scripts/run.sh. Usage (from MCSC6002_System): bash scripts/demo.sh
set -u
source <(tr -d '\r' < .env)
G=https://localhost:7000
json() { python -c "import sys,json; d=json.load(sys.stdin); print($1)"; }
step() { echo; read -r -p "--- $1 [Enter]"; }

step "1. Admin logs in through the gateway"
ADMIN=$(curl -sk -X POST -H "Content-Type: application/json" -d "{\"userName\":\"admin@cloudbase.com\",\"password\":\"$SEED_ADMIN_PASSWORD\"}" $G/auth/login | json "d['data']['token']")
echo "$ADMIN" | python -c "
import sys,json,base64,time
h,p,_=sys.stdin.read().strip().split('.'); dec=lambda s: json.loads(base64.urlsafe_b64decode(s+'=='*2))
print('header:', dec(h)); print('valid for', round((dec(p)['exp']-time.time())/60), 'minutes')"

step "2. Basic user tries to create a product"
BASIC=$(curl -sk -X POST -H "Content-Type: application/json" -d "{\"userName\":\"basic@cloudbase.com\",\"password\":\"$SEED_BASIC_PASSWORD\"}" $G/auth/login | json "d['data']['token']")
LOGIN_AT=$SECONDS
BRAND=$(curl -sk -H "Authorization: Bearer $ADMIN" $G/product-service/brands/all | json "d['data'][0]['id']")
PRODUCT="{\"brandId\":$BRAND,\"name\":\"Demo widget\",\"description\":\"live demo\",\"quantity\":3,\"reOrderThreshold\":1}"
curl -sk -o /dev/null -w "HTTP %{http_code}\n" -X POST -H "Authorization: Bearer $BASIC" -H "Content-Type: application/json" -d "$PRODUCT" $G/product-service/products/create

step "3. Admin creates a product (quantity 3); Inventory gets the signed event"
ID=$(curl -sk -X POST -H "Authorization: Bearer $ADMIN" -H "Content-Type: application/json" -d "$PRODUCT" $G/product-service/products/create | json "d['data']")
echo "product id: $ID"; sleep 3
curl -sk -H "Authorization: Bearer $ADMIN" $G/inventory-service/items/get-by-product-id/$ID | json "f\"{len(d['data'])} stock items: \" + ', '.join(i['barcode'] for i in d['data'])"

step "4. Basic user edits the token payload to add the Create permission"
TAMPERED=$(echo "$BASIC" | python -c "
import sys,base64
h,p,s=sys.stdin.read().strip().split('.'); raw=base64.urlsafe_b64decode(p+'==').decode()
print(h+'.'+base64.urlsafe_b64encode(raw.replace('Products.Read','Products.Create').encode()).decode().rstrip('=')+'.'+s)")
curl -sk -w " HTTP %{http_code}\n" -X POST -H "Authorization: Bearer $TAMPERED" -H "Content-Type: application/json" -d "$PRODUCT" $G/product-service/products/create

step "5. Direct call to the Product service, skipping the gateway"
curl -sk -m 10 https://localhost:7280/api/products/all || echo "curl exit $?: TLS handshake rejected (no gateway certificate)"

step "6. Attacker with RabbitMQ credentials publishes an unsigned event (quantity 3)"
FAKE=$((900000 + RANDOM))
errors() { curl -s -u "$RABBITMQ_USER:$RABBITMQ_PASSWORD" http://127.0.0.1:15672/api/queues/%2F/ProductCreatedEventQueue_error | json "d.get('messages', 0)"; }
BEFORE=$(errors)
python -c "
import json,uuid
evt={'Id':$FAKE,'Name':'forged','Quantity':3,'ReOrderThreshold':0}
env={'messageId':str(uuid.uuid4()),'messageType':['urn:message:ResponseLibrary.Models.Requests.Product.Events:ProductCreatedEvent'],'message':evt,'headers':{}}
print(json.dumps({'properties':{'content_type':'application/vnd.masstransit+json','headers':{}},'routing_key':'','payload':json.dumps(env),'payload_encoding':'string'}))" |
curl -s -u "$RABBITMQ_USER:$RABBITMQ_PASSWORD" -H "Content-Type: application/json" -d @- \
  "http://127.0.0.1:15672/api/exchanges/%2F/ResponseLibrary.Models.Requests.Product.Events:ProductCreatedEvent/publish"; echo
sleep 3
curl -sk -H "Authorization: Bearer $ADMIN" $G/inventory-service/items/get-by-product-id/$FAKE | json "f\"stock items for forged product $FAKE: {len(d.get('data') or [])}\""
for _ in $(seq 10); do AFTER=$(errors); [ "$AFTER" -gt "$BEFORE" ] && break; sleep 1; done # Management stats lag ~5 s.
echo "error queue: $BEFORE -> $AFTER messages"

step "7. Full attack suite"
WAIT=$((61 - (SECONDS - LOGIN_AT))); [ $WAIT -gt 0 ] && { echo "waiting ${WAIT}s for the login rate-limit window"; sleep $WAIT; }
dotnet run tests/AttackTests.cs | tail -1
