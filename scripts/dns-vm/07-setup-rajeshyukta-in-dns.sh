#!/usr/bin/env bash
# Programmatically claim rajeshyukta.in under the 'nextdp' tenant on DNS-VM,
# configure @ A and www A -> 3.6.143.66 (matching mrajesh.com on Web-1) plus MX 0 mx.nextdp.com,
# trigger NS check, and verify BOTH NS-1 and NS-2 authoritative replies.
set -Eeuo pipefail

SECRETS_ONBOX=/root/.dns-nextdp-secrets.env
if ! sudo test -f "$SECRETS_ONBOX"; then
  echo "FATAL: $SECRETS_ONBOX missing; run 03-setup-nextdp-tenant-and-zones first" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source <(sudo cat "$SECRETS_ONBOX")
set +a

export NEXTDP_API_KEY
python3 - <<'PY'
import json, os, urllib.request, urllib.error

BASE = "http://127.0.0.1:8080/api/v1"
KEY_HDR = {"X-API-Key": os.environ["NEXTDP_API_KEY"]}
ZONE_FQDN = "rajeshyukta.in"
WEB1_IP = "3.6.143.66"
MX_TARGET = "0 mx.nextdp.com"

def api(method, path, body=None):
    hdrs = {"Content-Type": "application/json", "Accept": "application/json"}
    hdrs.update(KEY_HDR)
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(BASE + path, data=data, headers=hdrs, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.status, json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", "replace")
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, {"error": raw}

def must_ok(step, status, payload):
    if status < 200 or status >= 300 or not payload.get("success"):
        raise SystemExit(f"FATAL [{step}]: HTTP {status}: {payload.get('error') or payload}")
    return payload.get("data")

st, res = api("GET", "/whoami")
who = must_ok("whoami", st, res)
print(f"Authenticated as tenant account={who['account']} ({who['tenant_id']})")

st, res = api("GET", "/zones")
zones = must_ok("list-zones", st, res).get("zones") or []
z = next((item for item in zones if item.get("fqdn", "").lower() == ZONE_FQDN), None)
if z is None:
    st, res = api("POST", "/zones", {"fqdn": ZONE_FQDN, "ref": "web-1-ogcen", "seed_scan": False})
    z = must_ok(f"claim-{ZONE_FQDN}", st, res)["zone"]
    print(f"Created zone {ZONE_FQDN} (id={z['id']}, status={z['status']})")
else:
    print(f"Found existing zone {ZONE_FQDN} (id={z['id']}, status={z['status']})")

zid = z["id"]

RECORDS = [
    ("@",   "A",  "3600", [WEB1_IP]),
    ("www", "A",  "3600", [WEB1_IP]),
    ("@",   "MX", "3600", [MX_TARGET]),
]

for name, rtype, ttl, vals in RECORDS:
    st, res = api("PUT", f"/zones/{zid}/records", {"name": name, "type": rtype, "ttl": ttl, "values": vals})
    must_ok(f"save-{name}-{rtype}", st, res)
    fqdn_label = ZONE_FQDN if name == "@" else f"{name}.{ZONE_FQDN}"
    print(f"  OK {fqdn_label:24s} {rtype:4s} -> {', '.join(vals)}")

st, res = api("POST", f"/zones/{zid}/check")
fresh = must_ok("force-check", st, res).get("zone") or {}
print(f"Zone check completed: status={fresh.get('status')} ns_status={fresh.get('ns_status')}")
PY

echo "=== Verify authoritative PowerDNS replies on BOTH NS-1 and NS-2 ==="
source <(sudo cat /root/.dns-vm-secrets.env)
FAIL=0
for ns_ip in "$DNS_VM_PRIV1" "$DNS_VM_PRIV2"; do
  a_apex=$(dig +short +norecurse +tries=1 +time=2 @"$ns_ip" rajeshyukta.in A | tr '\n' ' ' | sed 's/[[:space:]]*$//')
  a_www=$(dig +short +norecurse +tries=1 +time=2 @"$ns_ip" www.rajeshyukta.in A | tr '\n' ' ' | sed 's/[[:space:]]*$//')
  mx=$(dig +short +norecurse +tries=1 +time=2 @"$ns_ip" rajeshyukta.in MX | tr '\n' ' ' | sed 's/[[:space:]]*$//')
  ns=$(dig +short +norecurse +tries=1 +time=2 @"$ns_ip" rajeshyukta.in NS | sort | tr '\n' ',' | sed 's/,$//')
  printf "  @%-14s -> apex=[%s] www=[%s] mx=[%s] ns=[%s]\n" "$ns_ip" "$a_apex" "$a_www" "$mx" "$ns"
  if [ "$a_apex" != "3.6.143.66" ] || [ "$a_www" != "3.6.143.66" ] || [ "$mx" != "0 mx.nextdp.com." ] || [ "$ns" != "ns1.nextdp.com.,ns2.nextdp.com." ]; then
    FAIL=$((FAIL+1))
  fi
done
if [ "$FAIL" -gt 0 ]; then
  echo "FATAL: authoritative verification failed on $FAIL NS target(s)" >&2
  exit 1
fi
echo "Authoritative verification passed cleanly on NS-1 and NS-2."
