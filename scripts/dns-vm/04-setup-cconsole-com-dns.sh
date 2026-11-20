#!/usr/bin/env bash
# Programmatically claim cconsole.com under the 'nextdp' tenant and configure all live AWS
# records (DNS-VM, Mail-VM / CConsole Hub, Apps-Core-VM / LocalCen + Next iDP, MX/SPF/DMARC).
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
z = next((item for item in zones if item.get("fqdn", "").lower() == "cconsole.com"), None)
if z is None:
    st, res = api("POST", "/zones", {"fqdn": "cconsole.com", "ref": "aws-cconsole-core", "seed_scan": False})
    z = must_ok("claim-cconsole.com", st, res)["zone"]
    print(f"Created zone cconsole.com (id={z['id']}, status={z['status']})")
else:
    print(f"Found existing zone cconsole.com (id={z['id']}, status={z['status']})")

zid = z["id"]

RECORDS = [
    # Apex & www -> Mail VM (52.66.111.138) maintenance/catch-all
    ("@",              "A",   "3600", ["52.66.111.138"]),
    ("www",            "A",   "3600", ["52.66.111.138"]),
    # DNS-VM consoles -> 52.66.165.1
    ("dns",            "A",   "3600", ["52.66.165.1"]),
    ("admin.dns",      "A",   "3600", ["52.66.165.1"]),
    # CConsole Hub (reseller-mw) on Mail VM -> 52.66.111.138
    ("hub",            "A",   "3600", ["52.66.111.138"]),
    ("admin.hub",      "A",   "3600", ["52.66.111.138"]),
    ("api.hub",        "A",   "3600", ["52.66.111.138"]),
    ("sandbox.hub",    "A",   "3600", ["52.66.111.138"]),
    ("docs.hub",       "A",   "3600", ["52.66.111.138"]),
    # Apps-Core-VM (LocalCen + Next iDP) -> 43.204.42.99
    ("localcen",       "A",   "3600", ["43.204.42.99"]),
    ("admin.localcen", "A",   "3600", ["43.204.42.99"]),
    ("accounts",       "A",   "3600", ["43.204.42.99"]),
    # Email / SPF / DMARC
    ("@",              "MX",  "3600", ["0 mx.nextdp.com"]),
    ("@",              "TXT", "3600", ["v=spf1 ip4:52.66.111.138 include:transmail.net ~all"]),
    ("_dmarc",         "TXT", "3600", ["v=DMARC1; p=none; rua=mailto:dmarc@nextdp.com; fo=1; adkim=r; aspf=r; pct=100"]),
]

for name, rtype, ttl, vals in RECORDS:
    st, res = api("PUT", f"/zones/{zid}/records", {"name": name, "type": rtype, "ttl": ttl, "values": vals})
    must_ok(f"save-{name}-{rtype}", st, res)
    fqdn_label = "cconsole.com" if name == "@" else f"{name}.cconsole.com"
    print(f"  OK {fqdn_label:28s} {rtype:4s} -> {', '.join(vals)}")

# Trigger immediate honest NS/delegation re-check
st, res = api("POST", f"/zones/{zid}/check")
fresh = must_ok("force-check", st, res).get("zone") or {}
print(f"Zone check completed: status={fresh.get('status')} ns_status={fresh.get('ns_status')}")
PY

echo "=== Verify authoritative PowerDNS replies on BOTH NS-1 and NS-2 ==="
source <(sudo cat /root/.dns-vm-secrets.env)
for ns_ip in "$DNS_VM_PRIV1" "$DNS_VM_PRIV2"; do
  echo "  --- Authoritative check @$ns_ip ---"
  for host in cconsole.com www.cconsole.com dns.cconsole.com admin.dns.cconsole.com hub.cconsole.com admin.hub.cconsole.com api.hub.cconsole.com sandbox.hub.cconsole.com docs.hub.cconsole.com localcen.cconsole.com admin.localcen.cconsole.com accounts.cconsole.com; do
    val=$(dig +short +norecurse +tries=1 +time=2 @"$ns_ip" "$host" A | tr '\n' ' ' | sed 's/[[:space:]]*$//')
    printf "    %-28s A   -> %s\n" "$host" "$val"
  done
  printf "    %-28s MX  -> %s\n" "cconsole.com" "$(dig +short +norecurse +tries=1 +time=2 @"$ns_ip" cconsole.com MX | tr '\n' ' ')"
  printf "    %-28s NS  -> %s\n" "cconsole.com" "$(dig +short +norecurse +tries=1 +time=2 @"$ns_ip" cconsole.com NS | sort | tr '\n' ',' | sed 's/,$//')"
  printf "    %-28s TXT -> %s\n" "cconsole.com" "$(dig +short +norecurse +tries=1 +time=2 @"$ns_ip" cconsole.com TXT | tr '\n' ' ')"
  printf "    %-28s TXT -> %s\n" "_dmarc.cconsole.com" "$(dig +short +norecurse +tries=1 +time=2 @"$ns_ip" _dmarc.cconsole.com TXT | tr '\n' ' ')"
done
