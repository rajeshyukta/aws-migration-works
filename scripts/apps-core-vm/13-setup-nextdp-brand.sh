#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  exec sudo env \
    BRAND_BOOT_BIN="${BRAND_BOOT_BIN:-}" \
    BRAND_NAME="${BRAND_NAME:-}" \
    BRAND_SLUG="${BRAND_SLUG:-}" \
    BRAND_PRIMARY_DOMAIN="${BRAND_PRIMARY_DOMAIN:-}" \
    BRAND_ADMIN_DOMAIN="${BRAND_ADMIN_DOMAIN:-}" \
    BRAND_CONSOLE_DOMAIN="${BRAND_CONSOLE_DOMAIN:-}" \
    BRAND_PRIMARY_PRODUCT="${BRAND_PRIMARY_PRODUCT:-}" \
    BRAND_SENDER_NAME="${BRAND_SENDER_NAME:-}" \
    BRAND_SENDER_EMAIL="${BRAND_SENDER_EMAIL:-}" \
    BRAND_ADMIN_EMAIL="${BRAND_ADMIN_EMAIL:-}" \
    BRAND_ADMIN_NAME="${BRAND_ADMIN_NAME:-}" \
    IDP_MASTER_HOST="${IDP_MASTER_HOST:-}" \
    bash "$0" "$@"
fi

# Programmatically onboard the NextDP brand in NextDP Core (via BrandProvisioner +
# idp.Service.Provision), verify child realm ndp-nextdp (accounts.nextdp.com), ensure
# rajesh@nextdp.com (brand superadmin + child realm_admin), save credentials to
# 0600 /root/.nextdp-brand-idp.env, restart nextdp units, and probe Caddy/TLS routing.
# Idempotent; NEVER prints raw secrets.

export BRAND_BOOT_BIN="${BRAND_BOOT_BIN:-}"
export BRAND_NAME="${BRAND_NAME:-NextDP}"
export BRAND_SLUG="${BRAND_SLUG:-nextdp}"
export BRAND_PRIMARY_DOMAIN="${BRAND_PRIMARY_DOMAIN:-nextdp.com}"
export BRAND_ADMIN_DOMAIN="${BRAND_ADMIN_DOMAIN:-admin.nextdp.com}"
export BRAND_CONSOLE_DOMAIN="${BRAND_CONSOLE_DOMAIN:-console.nextdp.com}"
export BRAND_PRIMARY_PRODUCT="${BRAND_PRIMARY_PRODUCT:-domains}"
export BRAND_SENDER_NAME="${BRAND_SENDER_NAME:-NextDP}"
export BRAND_SENDER_EMAIL="${BRAND_SENDER_EMAIL:-noreply@nextdp.com}"
export BRAND_ADMIN_EMAIL="${BRAND_ADMIN_EMAIL:-rajesh@nextdp.com}"
export BRAND_ADMIN_NAME="${BRAND_ADMIN_NAME:-Rajesh}"
export IDP_MASTER_HOST="${IDP_MASTER_HOST:-nextidp.com}"

CORE_IDP_ENV="/root/.nextdp-core-idp.env"
BRAND_IDP_ENV="/root/.nextdp-brand-idp.env"
NEXTDP_ENV="/srv/apps/nextdp/shared/.env"

for f in "$CORE_IDP_ENV" "$NEXTDP_ENV"; do
  if [[ ! -f "$f" ]]; then
    echo "FATAL: required file $f not found on VM" >&2
    exit 1
  fi
done
if [[ -z "$BRAND_BOOT_BIN" || ! -x "$BRAND_BOOT_BIN" ]]; then
  echo "FATAL: BRAND_BOOT_BIN missing or not executable: $BRAND_BOOT_BIN" >&2
  exit 1
fi

WORK_TMP="$(mktemp -d /tmp/awsmig-brand-XXXXXX)"
chmod 0700 "$WORK_TMP"
trap 'rm -rf -- "$WORK_TMP"' EXIT

BOOT_META="$WORK_TMP/brand-meta.json"
BOOT_SECRETS="$WORK_TMP/brand-secrets.env"
touch "$BOOT_META" "$BOOT_SECRETS"
chmod 0600 "$BOOT_META" "$BOOT_SECRETS"

echo "==> Provisioning brand & ndp-nextdp child realm via NextDP Core runtime..."
(
  set -a
  # shellcheck disable=SC1090
  . "$NEXTDP_ENV"
  set +a
  cd /srv/apps/nextdp/current
  "$BRAND_BOOT_BIN" -meta-out "$BOOT_META" -secret-out "$BOOT_SECRETS"
)

python3 - "$BOOT_META" "$BOOT_SECRETS" <<'PY'
import http.cookiejar
import json
import os
import secrets
import string
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

BOOT_META_PATH = sys.argv[1]
BOOT_SECRETS_PATH = sys.argv[2]
IDP_BASE = "http://127.0.0.1:8080"
IDP_MASTER_HOST = os.environ["IDP_MASTER_HOST"]

BRAND_NAME = os.environ["BRAND_NAME"]
BRAND_SLUG = os.environ["BRAND_SLUG"]
PRIMARY_DOMAIN = os.environ["BRAND_PRIMARY_DOMAIN"]
ADMIN_DOMAIN = os.environ["BRAND_ADMIN_DOMAIN"]
CONSOLE_DOMAIN = os.environ["BRAND_CONSOLE_DOMAIN"]
PRIMARY_PRODUCT = os.environ["BRAND_PRIMARY_PRODUCT"]
ADMIN_EMAIL = os.environ["BRAND_ADMIN_EMAIL"].strip().lower()
ADMIN_NAME = os.environ["BRAND_ADMIN_NAME"].strip()

CORE_IDP_ENV = "/root/.nextdp-core-idp.env"
BRAND_IDP_ENV = "/root/.nextdp-brand-idp.env"
NEXTDP_ENV = "/srv/apps/nextdp/shared/.env"


def parse_env_file(path):
    data = {}
    if not os.path.exists(path):
        return data
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            s = line.strip()
            if not s or s.startswith("#") or "=" not in s:
                continue
            k, v = s.split("=", 1)
            v = v.strip()
            if len(v) >= 2 and ((v[0] == '"' and v[-1] == '"') or (v[0] == "'" and v[-1] == "'")):
                v = v[1:-1]
            data[k.strip()] = v
    return data


def strong_password(length=24):
    up, lo, di, sy = string.ascii_uppercase, string.ascii_lowercase, string.digits, "@#%_-+=."
    all_c = up + lo + di + sy
    chars = [secrets.choice(up), secrets.choice(lo), secrets.choice(di), secrets.choice(sy)]
    chars.extend(secrets.choice(all_c) for _ in range(length - 4))
    for i in range(len(chars) - 1, 0, -1):
        j = secrets.randbelow(i + 1)
        chars[i], chars[j] = chars[j], chars[i]
    return "".join(chars)


def psql_core(sql):
    return subprocess.check_output(
        ["sudo", "-u", "postgres", "psql", "-d", "nextdp_core", "-tAc", sql],
        text=True,
    ).strip()


with open(BOOT_META_PATH, "r", encoding="utf-8") as f:
    meta = json.load(f)

boot_secrets = parse_env_file(BOOT_SECRETS_PATH)
core_idp = parse_env_file(CORE_IDP_ENV)
saved_brand = parse_env_file(BRAND_IDP_ENV)
nextdp_env = parse_env_file(NEXTDP_ENV)

brand_id = meta["brand_id"]
child_realm_id = meta["idp_realm_id"]
child_host = meta["idp_host"]
child_issuer = meta["idp_issuer"]
admin_client_id = meta["idp_admin_client_id"]
console_client_id = meta["idp_console_client_id"]

tenant_key = core_idp.get("IDP_TENANT_KEY") or nextdp_env.get("IDP_TENANT_KEY", "")
parent_realm_id = core_idp.get("NEXTDP_CORE_REALM_ID") or nextdp_env.get("IDP_PLATFORM_REALM_ID", "")
if not tenant_key or not parent_realm_id:
    raise RuntimeError("Missing IDP_TENANT_KEY or NEXTDP_CORE_REALM_ID")


def idp_tenant_req(method, path, body=None, target_realm_id=parent_realm_id, accept_status=(200, 201, 204)):
    hdrs = {
        "Host": IDP_MASTER_HOST,
        "Accept": "application/json",
        "X-N1-Realm": target_realm_id,
        "Authorization": f"Bearer {tenant_key}",
    }
    data = None
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        hdrs["Content-Type"] = "application/json"
    req = urllib.request.Request(IDP_BASE + path, data=data, method=method, headers=hdrs)
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
            if resp.status not in accept_status:
                raise RuntimeError(f"{method} {path} -> HTTP {resp.status}")
            return resp.status, (json.loads(raw) if raw.strip() else {})
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", errors="replace")
        if e.code in accept_status:
            return e.code, (json.loads(raw) if raw.strip() else {})
        raise RuntimeError(f"{method} {path} -> HTTP {e.code}: {raw[:300]}")


# 1) Inspect child realm ndp-nextdp details + DNS instructions
_, tenant_detail_res = idp_tenant_req("GET", f"/api/v1/realm/tenants/{child_realm_id}", target_realm_id=parent_realm_id)
tenant_detail = tenant_detail_res.get("data") or {}
tenant_realm = tenant_detail.get("realm") or {}
child_slug = tenant_realm.get("slug") or f"ndp-{BRAND_SLUG}"
child_host_status = tenant_realm.get("host_status") or meta.get("idp_status") or "pending"
dns_records = tenant_detail.get("dns") or []
edge_ips = tenant_detail.get("edge_ips") or []

# 2) Ensure rajesh@nextdp.com is realm_admin inside ndp-nextdp
_, u_list = idp_tenant_req(
    "GET",
    "/api/v1/realm/users?q=" + urllib.parse.quote(ADMIN_EMAIL),
    target_realm_id=child_realm_id,
)
idp_user = next((u for u in (u_list.get("data") or []) if (u.get("email") or "").lower() == ADMIN_EMAIL), None)
brand_env_exists = os.path.exists(BRAND_IDP_ENV)
child_idp_pw = saved_brand.get("NEXTDP_BRAND_IDP_ADMIN_PASSWORD", "")

if idp_user is None:
    if not child_idp_pw:
        child_idp_pw = strong_password()
    _, u_cre = idp_tenant_req(
        "POST",
        "/api/v1/realm/users",
        {"name": ADMIN_NAME, "email": ADMIN_EMAIL, "role": "realm_admin", "password": child_idp_pw},
        target_realm_id=child_realm_id,
        accept_status=(201,),
    )
    idp_user = u_cre.get("data") or {}
    idp_user_action = "created"
else:
    idp_user_action = "existing"
    if idp_user.get("role") != "realm_admin":
        _, p_res = idp_tenant_req(
            "PATCH",
            f"/api/v1/realm/users/{idp_user['id']}",
            {"role": "realm_admin"},
            target_realm_id=child_realm_id,
        )
        idp_user = p_res.get("data") or p_res
    if (not brand_env_exists or idp_user.get("must_change_password")) and not child_idp_pw:
        child_idp_pw = strong_password()
        idp_tenant_req(
            "POST",
            f"/api/v1/realm/users/{idp_user['id']}/reset-password",
            {"Password": child_idp_pw},
            target_realm_id=child_realm_id,
        )
        idp_user_action = "password_initialized"

idp_uid = idp_user["id"]
if (not brand_env_exists or idp_user.get("must_change_password")) and child_idp_pw:
    idp_tenant_req(
        "PATCH",
        f"/api/v1/realm/users/{idp_uid}/required-actions",
        {"remove": ["change_password"]},
        target_realm_id=child_realm_id,
    )

# Verify login on child host loopback when host is live; otherwise verify via realm user API
if child_idp_pw and child_host_status == "live":
    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
    l_req = urllib.request.Request(
        IDP_BASE + "/api/v1/auth/login",
        data=json.dumps({"email": ADMIN_EMAIL, "password": child_idp_pw}).encode("utf-8"),
        method="POST",
        headers={
            "Host": child_host,
            "Origin": child_issuer,
            "X-N1-Client": "web-brand",
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
    )
    with opener.open(l_req, timeout=15) as l_resp:
        if l_resp.status != 200:
            raise RuntimeError(f"Login probe on {child_host} returned {l_resp.status}")
        l_body = json.loads(l_resp.read().decode("utf-8"))
        role_got = (l_body.get("user") or {}).get("tenant_role") or (l_body.get("user") or {}).get("role")
        if role_got != "realm_admin":
            raise RuntimeError(f"Unexpected role on {child_host}: {role_got}")
    out_req = urllib.request.Request(
        IDP_BASE + "/api/v1/auth/logout",
        data=b"{}",
        method="POST",
        headers={"Host": child_host, "Origin": child_issuer, "X-N1-Client": "web-brand", "Content-Type": "application/json"},
    )
    try:
        opener.open(out_req, timeout=10).read()
    except Exception:
        pass
    child_login_probe = "200"
else:
    _, u_chk = idp_tenant_req("GET", f"/api/v1/realm/users/{idp_uid}", target_realm_id=child_realm_id)
    chk_wrap = u_chk.get("data") or {}
    chk_data = chk_wrap.get("user") or chk_wrap
    if chk_data.get("role") != "realm_admin" or not chk_data.get("active"):
        raise RuntimeError(f"Unexpected child realm user state: {chk_wrap}")
    child_login_probe = f"pending_host({child_host_status})_api_verified"

# 3) Ensure brand-scoped superadmin rajesh@nextdp.com in nextdp_core DB
brand_users_count = int(psql_core(f"SELECT count(*) FROM users WHERE brand_id = '{brand_id}'") or "0")
brand_super_pw = saved_brand.get("NEXTDP_BRAND_SUPERADMIN_PASSWORD", "")
if brand_users_count == 0:
    if not brand_super_pw:
        brand_super_pw = strong_password()
    cmd_make = (
        f"set -a && . {NEXTDP_ENV} && set +a && cd /srv/apps/nextdp/current && "
        f"./nextdp ops:make-superadmin --brand-id '{brand_id}' --group superadmin '{ADMIN_EMAIL}'"
    )
    subprocess.run(
        ["bash", "-c", cmd_make],
        input=f"{brand_super_pw}\n{brand_super_pw}\n",
        text=True,
        check=True,
        capture_output=True,
    )
    brand_super_action = "created"
else:
    brand_super_action = "existing"

# 4) Verify clients in ndp-nextdp via tenant key
_, c_list = idp_tenant_req("GET", "/api/v1/realm/clients", target_realm_id=child_realm_id)
client_names = [c.get("name", "") for c in (c_list.get("data") or [])]

# 5) Check enabled features in nextdp_core
enabled_feats = psql_core(
    f"SELECT string_agg(feature_key, ',' ORDER BY feature_key) FROM brand_features WHERE brand_id = '{brand_id}' AND is_enabled = true"
)

# 6) Save /root/.nextdp-brand-idp.env (0600)
txt_rec = next((d for d in dns_records if d.get("type") == "TXT"), {})
a_rec = next((d for d in dns_records if d.get("type") == "A"), {})
lines = [
    f"# NextDP brand & ndp-nextdp sub-realm credentials (generated {datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')})",
    f"NEXTDP_BRAND_ID={brand_id}",
    f"NEXTDP_BRAND_SLUG={BRAND_SLUG}",
    f"NEXTDP_BRAND_NAME={BRAND_NAME}",
    f"NEXTDP_BRAND_PRIMARY_DOMAIN={PRIMARY_DOMAIN}",
    f"NEXTDP_BRAND_ADMIN_DOMAIN={ADMIN_DOMAIN}",
    f"NEXTDP_BRAND_CONSOLE_DOMAIN={CONSOLE_DOMAIN}",
    f"NEXTDP_BRAND_PRIMARY_PRODUCT={meta.get('primary_product', PRIMARY_PRODUCT)}",
    f"NEXTDP_BRAND_ENABLED_FEATURES={enabled_feats}",
    f"NEXTDP_BRAND_SUPERADMIN_EMAIL={ADMIN_EMAIL}",
    f"NEXTDP_BRAND_SUPERADMIN_PASSWORD={brand_super_pw}",
    f"NEXTDP_BRAND_IDP_PARENT_REALM_ID={parent_realm_id}",
    f"NEXTDP_BRAND_IDP_REALM_ID={child_realm_id}",
    f"NEXTDP_BRAND_IDP_REALM_SLUG={child_slug}",
    f"NEXTDP_BRAND_IDP_HOST={child_host}",
    f"NEXTDP_BRAND_IDP_ISSUER={child_issuer}",
    f"NEXTDP_BRAND_IDP_HOST_STATUS={child_host_status}",
    f"NEXTDP_BRAND_IDP_ADMIN_CLIENT_ID={admin_client_id}",
    f"NEXTDP_BRAND_IDP_ADMIN_SECRET={boot_secrets.get('NEXTDP_BRAND_IDP_ADMIN_SECRET', '')}",
    f"NEXTDP_BRAND_IDP_CONSOLE_CLIENT_ID={console_client_id}",
    f"NEXTDP_BRAND_IDP_CONSOLE_SECRET={boot_secrets.get('NEXTDP_BRAND_IDP_CONSOLE_SECRET', '')}",
    f"NEXTDP_BRAND_IDP_REALM_KEY={boot_secrets.get('NEXTDP_BRAND_IDP_REALM_KEY', '')}",
    f"NEXTDP_BRAND_IDP_ADMIN_USER_ID={idp_uid}",
    f"NEXTDP_BRAND_IDP_ADMIN_EMAIL={ADMIN_EMAIL}",
    f"NEXTDP_BRAND_IDP_ADMIN_PASSWORD={child_idp_pw}",
    f"DNS_A_NAME={a_rec.get('name', child_host)}",
    f"DNS_A_VALUE={a_rec.get('value', (edge_ips[0] if edge_ips else ''))}",
    f"DNS_TXT_NAME={txt_rec.get('name', '_n1-verify.' + child_host)}",
    f"DNS_TXT_VALUE={txt_rec.get('value', '')}",
]

fd, tmp_env = tempfile.mkstemp(prefix="ndp-brand-idp-", dir="/root")
os.chmod(tmp_env, 0o600)
with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as f:
    f.write("\n".join(lines) + "\n")
os.replace(tmp_env, BRAND_IDP_ENV)
os.chmod(BRAND_IDP_ENV, 0o600)

print(f"brand={BRAND_SLUG} id={brand_id} brand_action={meta.get('brand_action')} provision_action={meta.get('provision_action')} primary_product={meta.get('primary_product')} features={enabled_feats}")
print(f"hosts primary={PRIMARY_DOMAIN} admin={ADMIN_DOMAIN} console={CONSOLE_DOMAIN}")
print(f"child_realm={child_slug} id={child_realm_id} parent={parent_realm_id} issuer={child_issuer} host_status={child_host_status}")
print(f"clients admin_client={admin_client_id} console_client={console_client_id} idp_clients={','.join(sorted(client_names))}")
print(f"brand_superadmin={ADMIN_EMAIL} action={brand_super_action}")
print(f"realm_admin={ADMIN_EMAIL} user_id={idp_uid} action={idp_user_action} login_probe={child_login_probe}")
for d in dns_records:
    print(f"dns_required type={d.get('type')} name={d.get('name')} value={d.get('value')}")
PY

echo "==> Restarting nextdp services to refresh brand/host cache..."
systemctl restart nextdp nextdp-worker nextdp-scheduler
for i in $(seq 1 20); do
  if curl -fsS http://127.0.0.1:8090/health >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

echo "==> Probing Caddy ask & HTTPS endpoints for NextDP brand..."
curl -fsS -w "admin_ask=%{http_code}\n" "http://127.0.0.1:8099/ask?domain=$BRAND_ADMIN_DOMAIN"
curl -fsS -w "console_ask=%{http_code}\n" "http://127.0.0.1:8099/ask?domain=$BRAND_CONSOLE_DOMAIN"
curl -sS -o /dev/null -w "https_${BRAND_ADMIN_DOMAIN}_login=%{http_code}\n" --resolve "${BRAND_ADMIN_DOMAIN}:443:127.0.0.1" "https://${BRAND_ADMIN_DOMAIN}/login"
curl -sS -o /dev/null -w "https_${BRAND_CONSOLE_DOMAIN}_login=%{http_code}\n" --resolve "${BRAND_CONSOLE_DOMAIN}:443:127.0.0.1" "https://${BRAND_CONSOLE_DOMAIN}/login"
stat -c "brand_secrets_mode=%a" "$BRAND_IDP_ENV"
