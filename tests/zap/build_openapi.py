# Prepares an authenticated OWASP ZAP API scan of the gateway:
#  1. openapi.json: the gateway's routes (ocelot.json) with request/response schemas taken from each
#     service's /openapi/v1.json (fetched over mTLS with the gateway client cert).
#  2. token.txt: an admin JWT valid for 3 hours, so tokens don't expire mid-scan. TEST USE ONLY:
#     it is re-signed with the local dev private key.
# Usage (from MCSC6002_System, stack running): python tests/zap/build_openapi.py https://host.docker.internal:7000
import base64, json, ssl, sys, time, urllib.request
from pathlib import Path
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding

server_url = sys.argv[1]
here = Path(__file__).parent
project = here.parents[2]
keys = project / "keys"
env = dict(l.strip().split("=", 1) for l in open(here.parents[1] / ".env") if "=" in l and not l.startswith("#"))

tls = ssl.create_default_context()
tls.check_hostname, tls.verify_mode = False, ssl.CERT_NONE  # local dev certificates
tls.load_cert_chain(keys / "tls" / "gateway-client.crt", keys / "tls" / "gateway-client.key")

def get_json(url):
    return json.load(urllib.request.urlopen(url, context=tls))

def strip_comment(line):  # ocelot.json allows // comments
    in_string = False
    for i, c in enumerate(line):
        if c == '"' and (i == 0 or line[i - 1] != "\\"):
            in_string = not in_string
        elif not in_string and line.startswith("//", i):
            return line[:i]
    return line

ocelot_text = (project / "MCSC6002_ApiGateway" / "ApiGateway" / "ocelot.json").read_text(encoding="utf-8-sig")
ocelot = json.loads("\n".join(strip_comment(l) for l in ocelot_text.splitlines()))

service_specs, spec = {}, {"openapi": "3.0.1", "info": {"title": "API Gateway", "version": "1"}, "servers": [{"url": server_url}],
                           "paths": {}, "components": {"schemas": {}}}
for route in ocelot["Routes"]:
    hop = route["DownstreamHostAndPorts"][0]
    base = f"https://{hop['Host']}:{hop['Port']}"
    if base not in service_specs:
        service_specs[base] = get_json(base + "/openapi/v1.json")
        for name, schema in service_specs[base].get("components", {}).get("schemas", {}).items():
            spec["components"]["schemas"].setdefault(name, schema)
    down_paths = {p.lower(): ops for p, ops in service_specs[base]["paths"].items()}
    ops = down_paths.get(route["DownstreamPathTemplate"].lower(), {})
    for method in route["UpstreamHttpMethod"]:
        op = ops.get(method.lower())
        if op:
            spec["paths"].setdefault(route["UpstreamPathTemplate"], {})[method.lower()] = op
(here / "openapi.json").write_text(json.dumps(spec, indent=1))

# Long-lived admin token: real admin claims, new expiry, re-signed (RS256) with the dev private key.
login = urllib.request.Request(server_url.replace("host.docker.internal", "localhost") + "/auth/login", method="POST",
                               data=json.dumps({"userName": "admin@cloudbase.com", "password": env["SEED_ADMIN_PASSWORD"]}).encode(),
                               headers={"Content-Type": "application/json"})
token = json.load(urllib.request.urlopen(login, context=tls))["data"]["token"]
header_b64, payload_b64, _ = token.split(".")
payload = json.loads(base64.urlsafe_b64decode(payload_b64 + "=" * (-len(payload_b64) % 4)))
payload["exp"] = int(time.time()) + 3 * 3600
b64 = lambda raw: base64.urlsafe_b64encode(raw).rstrip(b"=").decode()
signing_input = f"{header_b64}.{b64(json.dumps(payload, separators=(',', ':')).encode())}"
private_key = serialization.load_pem_private_key((keys / "jwt-private.pem").read_bytes(), password=None)
signature = private_key.sign(signing_input.encode(), padding.PKCS1v15(), hashes.SHA256())
(here / "token.txt").write_text(f"{signing_input}.{b64(signature)}")
print(f"{sum(len(v) for v in spec['paths'].values())} operations written to openapi.json; token.txt valid 3 h")
