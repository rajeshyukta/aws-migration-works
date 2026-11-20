#!/usr/bin/env bash
# Programmatically provision NextDP tenant, super-admin + tenant-admin users, API key,
# and all Web-1 OGCEN zones + @/www/dev* A records (3.6.143.66) + MX (0 mx.nextdp.com)
# through dns-service CLI + REST API on DNS-VM (127.0.0.1:8080).
# Never echoes secret passwords or raw API keys to stdout/stderr.
set -Eeuo pipefail

INPUT_ENV="${INPUT_ENV:?INPUT_ENV must be set}"
OUTPUT_ENV="${OUTPUT_ENV:?OUTPUT_ENV must be set}"
SECRETS_ONBOX=/root/.dns-nextdp-secrets.env

# Load on-box secrets if already provisioned, else read local generated passwords from INPUT_ENV
if sudo test -f "$SECRETS_ONBOX"; then
  # shellcheck disable=SC1090
  source <(sudo cat "$SECRETS_ONBOX")
fi
# shellcheck disable=SC1090
source "$INPUT_ENV"

if [ -z "${SUPER_ADMIN_PASSWORD:-}" ] || [ -z "${TENANT_ADMIN_PASSWORD:-}" ]; then
  echo "FATAL: missing admin passwords in env input" >&2
  exit 1
fi

echo "=== [1/4] Ensure super admin rajesh@nextdp.com via dns seed-admin ==="
SUPER_COUNT=$(cd /tmp && sudo -u postgres psql -d dns_db -Atc "SELECT count(*) FROM users WHERE role = 'admin' AND tenant_id IS NULL;")
if [ "$SUPER_COUNT" -eq 0 ]; then
  (cd /srv/apps/dns-service/current && sudo -u webapps ./dns seed-admin \
    --email "rajesh@nextdp.com" \
    --name "Rajesh Yukta" \
    --password "$SUPER_ADMIN_PASSWORD" >/dev/null)
  echo "  created super admin: rajesh@nextdp.com"
else
  EXISTS_RAJESH=$(cd /tmp && sudo -u postgres psql -d dns_db -Atc "SELECT count(*) FROM users WHERE LOWER(email)='rajesh@nextdp.com' AND role='admin';")
  if [ "$EXISTS_RAJESH" -eq 0 ]; then
    echo "FATAL: another super admin already exists in dns_db; refusing to overwrite" >&2
    exit 1
  fi
  echo "  super admin already present: rajesh@nextdp.com"
fi

echo "=== [2/4] Provision tenant nextdp, tenant user nextdp@nextdp.com & API key via REST API ==="
export SUPER_ADMIN_PASSWORD TENANT_ADMIN_PASSWORD EXISTING_API_KEY="${NEXTDP_API_KEY:-}" OUTPUT_ENV
python3 - <<'PY'
import json, os, urllib.request, urllib.error

BASE = "http://127.0.0.1:8080/api/v1"

def api(method, path, body=None, headers=None):
    hdrs = {"Content-Type": "application/json", "Accept": "application/json"}
    if headers:
        hdrs.update(headers)
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(BASE + path, data=data, headers=hdrs, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read().decode("utf-8")
            return resp.status, json.loads(raw)
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", "replace")
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, {"error": raw}

def must_ok(step, status, payload):
    if status < 200 or status >= 300 or not payload.get("success"):
        msg = payload.get("error") or str(payload)
        raise SystemExit(f"FATAL [{step}]: HTTP {status}: {msg}")
    return payload.get("data")

# 1) Login as super admin rajesh@nextdp.com
st, res = api("POST", "/auth/login", {
    "email": "rajesh@nextdp.com",
    "password": os.environ["SUPER_ADMIN_PASSWORD"],
})
admin_tok = must_ok("super-admin-login", st, res)["access_token"]
admin_hdr = {"Authorization": f"Bearer {admin_tok}"}

# 2) Ensure tenant 'nextdp' with ns1.nextdp.com,ns2.nextdp.com
st, res = api("GET", "/admin/tenants?q=nextdp&per_page=50", headers=admin_hdr)
tenants = must_ok("list-tenants", st, res) or []
tenant = next((t for t in tenants if t.get("slug") == "nextdp" or t.get("account") == "nextdp"), None)
if tenant is None:
    st, res = api("POST", "/admin/tenants", {
        "name": "NextDP",
        "slug": "nextdp",
        "brand": "nextdp",
        "account": "nextdp",
        "nameservers": "ns1.nextdp.com,ns2.nextdp.com",
        "soa_contact": "dns-admin@nextdp.com",
    }, headers=admin_hdr)
    tenant = must_ok("create-tenant", st, res)
    print(f"  created tenant nextdp (id={tenant['id']})")
else:
    if tenant.get("nameservers") != "ns1.nextdp.com,ns2.nextdp.com" or tenant.get("soa_contact") != "dns-admin@nextdp.com":
        st, res = api("PATCH", f"/admin/tenants/{tenant['id']}", {
            "nameservers": "ns1.nextdp.com,ns2.nextdp.com",
            "soa_contact": "dns-admin@nextdp.com",
        }, headers=admin_hdr)
        tenant = must_ok("patch-tenant", st, res)
        print(f"  updated tenant nextdp NS/SOA (id={tenant['id']})")
    else:
        print(f"  tenant nextdp already present (id={tenant['id']})")

tenant_id = tenant["id"]

# 3) Ensure tenant admin user nextdp@nextdp.com
st, res = api("GET", f"/admin/users?tenant_id={tenant_id}&per_page=50", headers=admin_hdr)
users = must_ok("list-tenant-users", st, res) or []
tuser = next((u for u in users if u.get("email", "").lower() == "nextdp@nextdp.com"), None)
if tuser is None:
    st, res = api("POST", "/admin/users", {
        "tenant_id": tenant_id,
        "name": "NextDP Admin",
        "email": "nextdp@nextdp.com",
        "password": os.environ["TENANT_ADMIN_PASSWORD"],
        "role": "tenant",
    }, headers=admin_hdr)
    tuser = must_ok("create-tenant-user", st, res)["user"]
    print(f"  created tenant admin: nextdp@nextdp.com (id={tuser['id']})")
else:
    print(f"  tenant admin already present: nextdp@nextdp.com (id={tuser['id']})")

# 4) Obtain tenant API key (reuse validated on-box key or mint new dk_ key)
api_key = os.environ.get("EXISTING_API_KEY", "").strip()
key_valid = False
if api_key:
    st, res = api("GET", "/whoami", headers={"X-API-Key": api_key})
    if st == 200 and res.get("success") and (res.get("data") or {}).get("account") == "nextdp":
        key_valid = True
        print(f"  reusing active API key (prefix={api_key[:12]})")

if not key_valid:
    st, res = api("POST", "/auth/login", {
        "email": "nextdp@nextdp.com",
        "password": os.environ["TENANT_ADMIN_PASSWORD"],
    })
    ten_tok = must_ok("tenant-admin-login", st, res)["access_token"]
    ten_hdr = {"Authorization": f"Bearer {ten_tok}"}
    st, res = api("POST", "/api-keys", {"name": "nextdp-web1-dns"}, headers=ten_hdr)
    created = must_ok("create-api-key", st, res)
    api_key = created["key"]
    print(f"  minted tenant API key (prefix={api_key[:12]})")

# 5) Create all Web-1 apex zones & records via X-API-Key machine plane
key_hdr = {"X-API-Key": api_key}
st, res = api("GET", "/whoami", headers=key_hdr)
who = must_ok("whoami", st, res)
if who.get("account") != "nextdp" or who.get("tenant_id") != tenant_id:
    raise SystemExit(f"FATAL: whoami mismatch: {who}")
print(f"  machine API verified: account={who['account']} tenant_id={who['tenant_id']}")

APEX_DOMAINS = [
    "softskills.training",
    "daiskills.com",
    "nextskillclub.com",
    "localcen.com",
    "mrajesh.com",
    "organicgrowth.center",
    "ogcen.com",
    "afteraiwork.com",
    "nextdigital.in",
    "proseva.org",
    "rajeshforbharat.com",
    "forbharat.in",
    "forbharat.com",
    "forbharat.org",
    "haindaviswaraj.org.in",
    "jyothularajesh.com",
    "navduta.com",
    "srikalabhairavam.com",
    "srikalabhairavam.in",
    "kalabhairavam.com",
]

EXTRA_SUBDOMAINS = {
    "haindaviswaraj.org.in": ["dev"],
    "srikalabhairavam.com":  ["dev", "dev2", "dev8", "dev9", "dev10"],
}

st, res = api("GET", "/zones", headers=key_hdr)
existing_zones = {z["fqdn"].lower(): z for z in (must_ok("list-zones", st, res).get("zones") or [])}

created_cnt = 0
for fqdn in APEX_DOMAINS:
    z = existing_zones.get(fqdn)
    if z is None:
        st, res = api("POST", "/zones", {"fqdn": fqdn, "ref": "web-1-ogcen", "seed_scan": False}, headers=key_hdr)
        z = must_ok(f"claim-{fqdn}", st, res)["zone"]
        created_cnt += 1
        tag = "created"
    else:
        tag = "exists"
    zid = z["id"]

    # @ A -> 3.6.143.66
    st, res = api("PUT", f"/zones/{zid}/records", {"name": "@", "type": "A", "ttl": "3600", "values": ["3.6.143.66"]}, headers=key_hdr)
    must_ok(f"{fqdn}-apex-A", st, res)
    # www A -> 3.6.143.66
    st, res = api("PUT", f"/zones/{zid}/records", {"name": "www", "type": "A", "ttl": "3600", "values": ["3.6.143.66"]}, headers=key_hdr)
    must_ok(f"{fqdn}-www-A", st, res)
    # @ MX -> 0 mx.nextdp.com
    st, res = api("PUT", f"/zones/{zid}/records", {"name": "@", "type": "MX", "ttl": "3600", "values": ["0 mx.nextdp.com"]}, headers=key_hdr)
    must_ok(f"{fqdn}-MX", st, res)

    subs = EXTRA_SUBDOMAINS.get(fqdn, [])
    for sub in subs:
        st, res = api("PUT", f"/zones/{zid}/records", {"name": sub, "type": "A", "ttl": "3600", "values": ["3.6.143.66"]}, headers=key_hdr)
        must_ok(f"{fqdn}-{sub}-A", st, res)

    sub_note = f" + subs({','.join(subs)})" if subs else ""
    print(f"  {fqdn:28s} [{tag}] -> @ A, www A = 3.6.143.66 | MX = 0 mx.nextdp.com{sub_note}")

print(f"Summary: {len(APEX_DOMAINS)} domains synced ({created_cnt} newly created)")

# Write secrets output file without ever printing secret lines to stdout
lines = [
    "# NextDP DNS Service Credentials (DNS-VM: 52.66.165.1 / 52.66.25.51)",
    "# Generated programmatically — DO NOT COMMIT OR PRINT IN LOGS",
    "DNS_SERVICE_BASE_URL=http://127.0.0.1:8080/api/v1",
    "DNS_ADMIN_CONSOLE_URL=https://admin.dns.cconsole.com",
    "DNS_TENANT_CONSOLE_URL=https://dns.cconsole.com",
    "DNS_NAMESERVERS=ns1.nextdp.com,ns2.nextdp.com",
    "DNS_NS1_IP=52.66.165.1",
    "DNS_NS2_IP=52.66.25.51",
    f"TENANT_ID={tenant_id}",
    "TENANT_SLUG=nextdp",
    "TENANT_ACCOUNT=nextdp",
    "SUPER_ADMIN_EMAIL=rajesh@nextdp.com",
    f"SUPER_ADMIN_PASSWORD={os.environ['SUPER_ADMIN_PASSWORD']}",
    "TENANT_ADMIN_EMAIL=nextdp@nextdp.com",
    f"TENANT_ADMIN_PASSWORD={os.environ['TENANT_ADMIN_PASSWORD']}",
    f"NEXTDP_API_KEY={api_key}",
    f"NEXTDP_API_KEY_PREFIX={api_key[:12]}",
    "",
]
with open(os.environ["OUTPUT_ENV"], "w", encoding="utf-8", newline="\n") as fh:
    fh.write("\n".join(lines))
os.chmod(os.environ["OUTPUT_ENV"], 0o600)
PY

echo "=== [3/4] Persist encrypted/mode-0600 copy on DNS-VM (/root/.dns-nextdp-secrets.env) ==="
sudo install -o root -g root -m 0600 "$OUTPUT_ENV" "$SECRETS_ONBOX"

echo "=== [4/4] Verify PowerDNS answers authoritatively on BOTH NS-1 and NS-2 ==="
source <(sudo cat /root/.dns-vm-secrets.env)
FAIL=0
for dom in softskills.training daiskills.com nextskillclub.com localcen.com mrajesh.com organicgrowth.center ogcen.com afteraiwork.com nextdigital.in proseva.org rajeshforbharat.com forbharat.in forbharat.com forbharat.org haindaviswaraj.org.in jyothularajesh.com navduta.com srikalabhairavam.com srikalabhairavam.in kalabhairavam.com; do
  for ns_ip in "$DNS_VM_PRIV1" "$DNS_VM_PRIV2"; do
    a_apex=$(dig +short +norecurse +tries=1 +time=2 @"$ns_ip" "$dom" A | tr '\n' ' ' | sed 's/[[:space:]]*$//')
    a_www=$(dig +short +norecurse +tries=1 +time=2 @"$ns_ip" "www.$dom" A | tr '\n' ' ' | sed 's/[[:space:]]*$//')
    mx=$(dig +short +norecurse +tries=1 +time=2 @"$ns_ip" "$dom" MX | tr '\n' ' ' | sed 's/[[:space:]]*$//')
    ns=$(dig +short +norecurse +tries=1 +time=2 @"$ns_ip" "$dom" NS | sort | tr '\n' ',' | sed 's/,$//')
    if [ "$a_apex" != "3.6.143.66" ] || [ "$a_www" != "3.6.143.66" ] || [ "$mx" != "0 mx.nextdp.com." ] || [ "$ns" != "ns1.nextdp.com.,ns2.nextdp.com." ]; then
      echo "  FAIL $dom @$ns_ip -> apex=[$a_apex] www=[$a_www] mx=[$mx] ns=[$ns]" >&2
      FAIL=$((FAIL+1))
    fi
  done
done
for sub in dev.haindaviswaraj.org.in dev.srikalabhairavam.com dev2.srikalabhairavam.com dev8.srikalabhairavam.com dev9.srikalabhairavam.com dev10.srikalabhairavam.com; do
  for ns_ip in "$DNS_VM_PRIV1" "$DNS_VM_PRIV2"; do
    a_sub=$(dig +short +norecurse +tries=1 +time=2 @"$ns_ip" "$sub" A | tr '\n' ' ' | sed 's/[[:space:]]*$//')
    if [ "$a_sub" != "3.6.143.66" ]; then
      echo "  FAIL sub $sub @$ns_ip -> [$a_sub]" >&2
      FAIL=$((FAIL+1))
    fi
  done
done
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
echo "Authoritative dig passed across all 20 apexes (+ www + MX + NS) and 6 dev subdomains on BOTH NS-1 and NS-2."
