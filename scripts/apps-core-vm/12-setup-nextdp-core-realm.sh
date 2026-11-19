#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  exec sudo env \
    CORE_REALM_NAME="${CORE_REALM_NAME:-}" \
    CORE_REALM_SLUG="${CORE_REALM_SLUG:-}" \
    CORE_REALM_HOST="${CORE_REALM_HOST:-}" \
    CORE_REALM_ADMIN_EMAIL="${CORE_REALM_ADMIN_EMAIL:-}" \
    CORE_REALM_ADMIN_NAME="${CORE_REALM_ADMIN_NAME:-}" \
    CORE_ORIGIN="${CORE_ORIGIN:-}" \
    IDP_API_BASE="${IDP_API_BASE:-}" \
    IDP_MASTER_HOST="${IDP_MASTER_HOST:-}" \
    ENABLE_CORE_LOGIN="${ENABLE_CORE_LOGIN:-false}" \
    ADMIN_SECRETS_FILE="${ADMIN_SECRETS_FILE:-}" \
    OPERATOR_SECRETS_FILE="${OPERATOR_SECRETS_FILE:-}" \
    SETUP_KEY_FILE="${SETUP_KEY_FILE:-}" \
    CORE_IDP_ENV_FILE="${CORE_IDP_ENV_FILE:-}" \
    NEXTDP_ENV_FILE="${NEXTDP_ENV_FILE:-}" \
    bash "$0" "$@"
fi

# Programmatically create & wire the top-level NextDP Core platform realm
# (nextdp-core / id.nextdp.com) on Next iDP and wire /srv/apps/nextdp/shared/.env.
# Idempotent; preserves existing secrets from /root/.nextdp-core-idp.env and
# /srv/apps/nextdp/shared/.env; NEVER prints raw secrets.

export REALM_NAME="${CORE_REALM_NAME:-NextDP Core}"
export REALM_SLUG="${CORE_REALM_SLUG:-nextdp-core}"
export REALM_HOST="${CORE_REALM_HOST:-id.nextdp.com}"
export REALM_ADMIN_EMAIL="${CORE_REALM_ADMIN_EMAIL:-rajesh@nextdp.com}"
export REALM_ADMIN_NAME="${CORE_REALM_ADMIN_NAME:-Rajesh}"
export CORE_ORIGIN="${CORE_ORIGIN:-https://core.nextdp.com}"
export IDP_API_BASE="${IDP_API_BASE:-https://nextidp.com}"
export IDP_MASTER_HOST="${IDP_MASTER_HOST:-nextidp.com}"
export ENABLE_CORE_LOGIN="${ENABLE_CORE_LOGIN:-false}"
export ADMIN_SECRETS_FILE="${ADMIN_SECRETS_FILE:-/root/.nextidp-admin-secrets.env}"
export OPERATOR_SECRETS_FILE="${OPERATOR_SECRETS_FILE:-/root/.nextidp-operator.env}"
export SETUP_KEY_FILE="${SETUP_KEY_FILE:-/root/.nextdp-core-setup-key.env}"
export CORE_IDP_ENV_FILE="${CORE_IDP_ENV_FILE:-/root/.nextdp-core-idp.env}"
export NEXTDP_ENV_FILE="${NEXTDP_ENV_FILE:-/srv/apps/nextdp/shared/.env}"

if [[ ! -f "$ADMIN_SECRETS_FILE" && ! -f "$OPERATOR_SECRETS_FILE" && ! -f "$SETUP_KEY_FILE" ]]; then
  echo "FATAL: none of $SETUP_KEY_FILE, $OPERATOR_SECRETS_FILE, or $ADMIN_SECRETS_FILE found on VM" >&2
  exit 1
fi
if [[ ! -f "$NEXTDP_ENV_FILE" ]]; then
  echo "FATAL: $NEXTDP_ENV_FILE not found on VM" >&2
  exit 1
fi

python3 - <<'PY'
import http.cookiejar
import json
import os
import secrets
import string
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone

BASE = "http://127.0.0.1:8080"
MASTER_HOST = os.environ["IDP_MASTER_HOST"]
REALM_NAME = os.environ["REALM_NAME"]
REALM_SLUG = os.environ["REALM_SLUG"]
REALM_HOST = os.environ["REALM_HOST"]
ADMIN_EMAIL = os.environ["REALM_ADMIN_EMAIL"].strip().lower()
ADMIN_NAME = os.environ["REALM_ADMIN_NAME"].strip()
CORE_ORIGIN = os.environ["CORE_ORIGIN"].rstrip("/")
IDP_API_BASE = os.environ["IDP_API_BASE"].rstrip("/")
ENABLE_CORE_LOGIN = os.environ["ENABLE_CORE_LOGIN"].strip().lower() == "true"

ADMIN_SECRETS_FILE = os.environ["ADMIN_SECRETS_FILE"]
OPERATOR_SECRETS_FILE = os.environ["OPERATOR_SECRETS_FILE"]
SETUP_KEY_FILE = os.environ["SETUP_KEY_FILE"]
CORE_IDP_ENV_FILE = os.environ["CORE_IDP_ENV_FILE"]
NEXTDP_ENV_FILE = os.environ["NEXTDP_ENV_FILE"]


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
    up = string.ascii_uppercase
    lo = string.ascii_lowercase
    di = string.digits
    sy = "@#%_-+=."
    all_chars = up + lo + di + sy
    chars = [
        secrets.choice(up),
        secrets.choice(lo),
        secrets.choice(di),
        secrets.choice(sy),
    ]
    chars.extend(secrets.choice(all_chars) for _ in range(length - len(chars)))
    for i in range(len(chars) - 1, 0, -1):
        j = secrets.randbelow(i + 1)
        chars[i], chars[j] = chars[j], chars[i]
    return "".join(chars)


class Client:
    def __init__(self, host, origin, client_hdr):
        self.host = host
        self.origin = origin
        self.client_hdr = client_hdr
        self.jar = http.cookiejar.CookieJar()
        self.opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(self.jar))

    def request(self, method, path, body=None, headers=None, accept_status=(200, 201, 204)):
        hdrs = {
            "Host": self.host,
            "Origin": self.origin,
            "X-N1-Client": self.client_hdr,
            "Accept": "application/json",
        }
        if headers:
            hdrs.update(headers)
        data = None
        if body is not None:
            data = json.dumps(body).encode("utf-8")
            hdrs["Content-Type"] = "application/json"
        req = urllib.request.Request(BASE + path, data=data, method=method, headers=hdrs)
        try:
            with self.opener.open(req, timeout=20) as resp:
                raw = resp.read().decode("utf-8", errors="replace")
                if resp.status not in accept_status:
                    raise RuntimeError(f"{method} {path} -> HTTP {resp.status}")
                return resp.status, (json.loads(raw) if raw.strip() else {})
        except urllib.error.HTTPError as e:
            raw = e.read().decode("utf-8", errors="replace")
            if e.code in accept_status:
                return e.code, (json.loads(raw) if raw.strip() else {})
            raise RuntimeError(f"{method} {path} -> HTTP {e.code}: {raw[:300]}")


admin_secrets = parse_env_file(ADMIN_SECRETS_FILE)
operator_secrets = parse_env_file(OPERATOR_SECRETS_FILE)
setup_key_secrets = parse_env_file(SETUP_KEY_FILE)
saved_idp = parse_env_file(CORE_IDP_ENV_FILE)
saved_core = parse_env_file(NEXTDP_ENV_FILE)

setup_api_key = setup_key_secrets.get("NEXTDP_CORE_SETUP_KEY") or setup_key_secrets.get("NEXTIDP_REALM_API_KEY") or ""
master = None
realm_hdr = {}
edge_ips = []
dns_records = []

if setup_api_key:
    realm_client = Client(REALM_HOST, f"https://{REALM_HOST}", "web-brand")
    realm_hdr = {"Authorization": f"Bearer {setup_api_key}"}

    def api_call(method, path, body=None, accept_status=(200, 201, 204)):
        return realm_client.request(method, path, body=body, headers=realm_hdr, accept_status=accept_status)

    _, r_res = api_call("GET", "/api/v1/realm")
    realm_view = r_res.get("data") or {}
    realm_id = realm_view.get("id", "")
    if not realm_id:
        raise RuntimeError("GET /api/v1/realm returned no realm id")
    realm_action = "existing_via_api_key"
    issuer_url = realm_view.get("issuer") or f"https://{REALM_HOST}"
    host_status = realm_view.get("host_status") or "pending"

    _, d_res = api_call("GET", "/api/v1/realm/domains")
    domains = d_res.get("data") or []
    dom = next((d for d in domains if d.get("host") == REALM_HOST), (domains[0] if domains else {}))
    if dom:
        tok = dom.get("verification_token") or ""
        edge_ips = dom.get("edge_ips") or []
        if tok:
            dns_records.append({"type": "TXT", "name": f"_n1-verify.{REALM_HOST}", "value": tok})
        for ip in edge_ips:
            dns_records.append({"type": "A", "name": REALM_HOST, "value": ip})
else:
    master_email = (
        operator_secrets.get("NEXTIDP_OPERATOR_EMAIL")
        or operator_secrets.get("NEXTIDP_ADMIN_EMAIL")
        or admin_secrets.get("NEXTIDP_ADMIN_EMAIL", "")
    )
    master_pass = (
        operator_secrets.get("NEXTIDP_OPERATOR_PASSWORD")
        or operator_secrets.get("NEXTIDP_ADMIN_PASSWORD")
        or admin_secrets.get("NEXTIDP_ADMIN_PASSWORD", "")
    )
    if not master_email or not master_pass:
        raise RuntimeError("Missing platform_admin email/password or NEXTDP_CORE_SETUP_KEY")

    master = Client(MASTER_HOST, f"https://{MASTER_HOST}", "web-master")
    master.request("POST", "/api/v1/auth/login", {"email": master_email, "password": master_pass})
    master.request("POST", "/api/v1/auth/reauth", {"Password": master_pass})

    _, realms_res = master.request("GET", "/api/v1/admin/realms?q=" + urllib.parse.quote(REALM_SLUG))
    realm_obj = next((r for r in (realms_res.get("data") or []) if r.get("slug") == REALM_SLUG), None)
    if realm_obj is None:
        _, create_res = master.request(
            "POST",
            "/api/v1/admin/realms",
            {
                "name": REALM_NAME,
                "slug": REALM_SLUG,
                "hostname": REALM_HOST,
                "kind": "internal",
                "admin_email": ADMIN_EMAIL,
                "admin_name": ADMIN_NAME,
            },
            accept_status=(201,),
        )
        realm_obj = create_res.get("data") or {}
        realm_action = "created"
    else:
        realm_action = "existing"

    realm_id = realm_obj.get("id", "")
    if not realm_id:
        raise RuntimeError("Failed to determine nextdp-core realm ID")

    _, detail_res = master.request("GET", f"/api/v1/admin/realms/{realm_id}")
    detail = detail_res.get("data") or {}
    realm_view = detail.get("realm") or realm_obj
    issuer_url = realm_view.get("issuer") or f"https://{REALM_HOST}"
    host_status = realm_view.get("host_status") or "pending"
    dns_records = detail.get("dns") or []
    edge_ips = detail.get("edge_ips") or []
    realm_hdr = {"X-N1-Realm": realm_id}

    def api_call(method, path, body=None, accept_status=(200, 201, 204)):
        return master.request(method, path, body=body, headers=realm_hdr, accept_status=accept_status)

# 2) Ensure realm_admin user rajesh@nextdp.com + capture strong password once
_, users_res = api_call("GET", "/api/v1/realm/users?q=" + urllib.parse.quote(ADMIN_EMAIL))
admin_user = None
for u in users_res.get("data") or []:
    if (u.get("email") or "").lower() == ADMIN_EMAIL:
        admin_user = u
        break

admin_pw = saved_idp.get("NEXTDP_CORE_REALM_ADMIN_PASSWORD", "")
if admin_user is None:
    if not admin_pw:
        admin_pw = strong_password()
    _, u_res = api_call(
        "POST",
        "/api/v1/realm/users",
        {
            "name": ADMIN_NAME,
            "email": ADMIN_EMAIL,
            "role": "realm_admin",
            "password": admin_pw,
        },
        accept_status=(201,),
    )
    admin_user = u_res.get("data") or {}
    user_action = "created"
else:
    user_action = "existing"
    uid = admin_user["id"]
    if admin_user.get("role") != "realm_admin":
        _, patch_res = api_call("PATCH", f"/api/v1/realm/users/{uid}", {"role": "realm_admin"})
        admin_user = patch_res.get("data") or patch_res
uid = admin_user["id"]
if admin_user.get("must_change_password") and not admin_pw:
    admin_pw = strong_password()
    api_call("POST", f"/api/v1/realm/users/{uid}/reset-password", {"Password": admin_pw})
    user_action = "password_initialized"

if admin_user.get("must_change_password") and admin_pw:
    api_call("PATCH", f"/api/v1/realm/users/{uid}/required-actions", {"remove": ["change_password"]})

# 3) Ensure OIDC client "nextdp-core"
_, clients_res = api_call("GET", "/api/v1/realm/clients")
client_obj = None
for cl in clients_res.get("data") or []:
    if cl.get("name") == "nextdp-core":
        client_obj = cl
        break

client_secret = saved_idp.get("IDP_PLATFORM_CLIENT_SECRET") or saved_core.get("IDP_PLATFORM_CLIENT_SECRET") or ""
if client_obj is None:
    _, c_res = api_call(
        "POST",
        "/api/v1/realm/clients",
        {
            "name": "nextdp-core",
            "description": "NextDP Core control plane",
            "type": "confidential",
            "token_auth": "client_secret_basic",
            "grant_types": ["authorization_code", "refresh_token"],
            "scopes": ["openid", "profile", "email", "offline_access"],
            "redirect_uris": [f"{CORE_ORIGIN}/auth/callback"],
            "post_logout_redirect_uris": [f"{CORE_ORIGIN}/"],
            "backchannel_logout_uri": f"{CORE_ORIGIN}/auth/backchannel-logout",
            "home_uri": f"{CORE_ORIGIN}/",
            "first_party": True,
            "access_mode": "open",
        },
        accept_status=(201,),
    )
    client_obj = c_res.get("data") or {}
    client_secret = c_res.get("client_secret") or ""
    client_action = "created"
else:
    client_action = "existing"
    if not client_secret:
        _, rot_res = api_call("POST", f"/api/v1/realm/clients/{client_obj['id']}/rotate-secret", {})
        client_secret = rot_res.get("client_secret") or ""
        client_action = "secret_rotated"

client_id = client_obj.get("client_id") or client_obj.get("id") or ""
if not client_id or not client_secret:
    raise RuntimeError("Missing OIDC client_id or client_secret")

# 4) Ensure API keys: nextdp-core-tenants & nextdp-core-contract
_, keys_res = api_call("GET", "/api/v1/realm/api-keys")
existing_keys = keys_res.get("data") or []


def ensure_api_key(name, scopes, saved_val, bind_client_id=""):
    found = next((k for k in existing_keys if k.get("name") == name), None)
    if found is not None and saved_val and saved_val.startswith("n1k_"):
        return found, saved_val, "existing"
    if found is not None and not saved_val:
        api_call("DELETE", f"/api/v1/realm/api-keys/{found['id']}")
    payload = {
        "name": name,
        "scopes": scopes,
        "expires_at": (datetime.now(timezone.utc) + timedelta(days=365)).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    if bind_client_id:
        payload["client_id"] = bind_client_id
    _, k_res = api_call("POST", "/api/v1/realm/api-keys", payload, accept_status=(201,))
    return k_res.get("api_key") or {}, k_res.get("secret_key") or "", "created"


tenant_key_saved = saved_idp.get("IDP_TENANT_KEY") or saved_core.get("IDP_TENANT_KEY") or ""
tenant_key_row, tenant_key_secret, tenant_key_action = ensure_api_key(
    "nextdp-core-tenants",
    ["tenants.admin"],
    tenant_key_saved,
)

contract_key_saved = saved_idp.get("IDP_PLATFORM_API_KEY") or saved_core.get("IDP_PLATFORM_API_KEY") or ""
contract_key_row, contract_key_secret, contract_key_action = ensure_api_key(
    "nextdp-core-contract",
    ["events.read", "clients.self", "signals.write", "dsr.ack"],
    contract_key_saved,
    bind_client_id=client_id,
)

if not tenant_key_secret or not contract_key_secret:
    raise RuntimeError("Missing minted tenant or contract API key")

# 5) Ensure webhook https://core.nextdp.com/api/v1/idp/webhook
webhook_url = f"{CORE_ORIGIN}/api/v1/idp/webhook"
_, hooks_res = api_call("GET", "/api/v1/realm/webhooks")
hook_obj = next((w for w in (hooks_res.get("data") or []) if w.get("url") == webhook_url), None)
webhook_secret = saved_idp.get("IDP_WEBHOOK_SECRET") or saved_core.get("IDP_WEBHOOK_SECRET") or ""

if hook_obj is None:
    _, h_res = api_call(
        "POST",
        "/api/v1/realm/webhooks",
        {
            "url": webhook_url,
            "description": "NextDP Core tree sync & DSR",
            "events": ["user.updated", "user.email_changed", "user.deleted", "privacy.dsr.erasure_requested"],
        },
        accept_status=(201,),
    )
    hook_obj = h_res.get("webhook") or {}
    webhook_secret = h_res.get("secret") or ""
    hook_action = "created"
else:
    hook_action = "existing"
    if not webhook_secret:
        _, rot_h = api_call("POST", f"/api/v1/realm/webhooks/{hook_obj['id']}/rotate-secret", {})
        webhook_secret = rot_h.get("secret") or ""
        hook_action = "secret_rotated"

webhook_id = hook_obj.get("id") or ""
if not webhook_id or not webhook_secret:
    raise RuntimeError("Missing webhook ID or secret")

# 6) Save /root/.nextdp-core-idp.env (0600)
txt_rec = next((d for d in dns_records if d.get("type") == "TXT"), {})
a_rec = next((d for d in dns_records if d.get("type") == "A"), {})
core_login_str = "true" if ENABLE_CORE_LOGIN else (saved_core.get("IDP_CORE_LOGIN") or "false")
if not ENABLE_CORE_LOGIN:
    core_login_str = "false"

idp_env_lines = [
    f"# Next iDP nextdp-core realm credentials (generated {datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')})",
    f"NEXTDP_CORE_REALM_ID={realm_id}",
    f"NEXTDP_CORE_REALM_SLUG={REALM_SLUG}",
    f"NEXTDP_CORE_REALM_HOST={REALM_HOST}",
    f"NEXTDP_CORE_REALM_ISSUER={issuer_url}",
    f"NEXTDP_CORE_REALM_HOST_STATUS={host_status}",
    f"NEXTDP_CORE_REALM_ADMIN_USER_ID={uid}",
    f"NEXTDP_CORE_REALM_ADMIN_EMAIL={ADMIN_EMAIL}",
    f"NEXTDP_CORE_REALM_ADMIN_PASSWORD={admin_pw}",
    f"IDP_PLATFORM_ISSUER={issuer_url}",
    f"IDP_PLATFORM_REALM_ID={realm_id}",
    f"IDP_PLATFORM_CLIENT_ID={client_id}",
    f"IDP_PLATFORM_CLIENT_SECRET={client_secret}",
    f"IDP_API_BASE={IDP_API_BASE}",
    f"IDP_TENANT_KEY_ID={tenant_key_row.get('id', '')}",
    f"IDP_TENANT_KEY={tenant_key_secret}",
    f"IDP_PLATFORM_API_KEY_ID={contract_key_row.get('id', '')}",
    f"IDP_PLATFORM_API_KEY={contract_key_secret}",
    f"IDP_WEBHOOK_ID={webhook_id}",
    f"IDP_WEBHOOK_URL={webhook_url}",
    f"IDP_WEBHOOK_SECRET={webhook_secret}",
    f"IDP_CORE_ORIGIN={CORE_ORIGIN}",
    f"IDP_OWNER_CONTACT={ADMIN_EMAIL}",
    f"IDP_CORE_LOGIN={core_login_str}",
    f"DNS_A_NAME={a_rec.get('name', REALM_HOST)}",
    f"DNS_A_VALUE={a_rec.get('value', (edge_ips[0] if edge_ips else ''))}",
    f"DNS_TXT_NAME={txt_rec.get('name', '_n1-verify.' + REALM_HOST)}",
    f"DNS_TXT_VALUE={txt_rec.get('value', '')}",
]

fd, tmp_path = tempfile.mkstemp(prefix="ndp-core-idp-", dir=os.path.dirname(CORE_IDP_ENV_FILE))
os.chmod(tmp_path, 0o600)
with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as f:
    f.write("\n".join(idp_env_lines) + "\n")
os.replace(tmp_path, CORE_IDP_ENV_FILE)
os.chmod(CORE_IDP_ENV_FILE, 0o600)

# 7) Atomically patch /srv/apps/nextdp/shared/.env preserving non-IDP vars
idp_updates = {
    "IDP_PLATFORM_ISSUER": issuer_url,
    "IDP_PLATFORM_REALM_ID": realm_id,
    "IDP_PLATFORM_CLIENT_ID": client_id,
    "IDP_PLATFORM_CLIENT_SECRET": client_secret,
    "IDP_API_BASE": IDP_API_BASE,
    "IDP_TENANT_KEY": tenant_key_secret,
    "IDP_PLATFORM_API_KEY": contract_key_secret,
    "IDP_WEBHOOK_SECRET": webhook_secret,
    "IDP_CORE_ORIGIN": CORE_ORIGIN,
    "IDP_OWNER_CONTACT": ADMIN_EMAIL,
    "IDP_CORE_LOGIN": core_login_str,
}

with open(NEXTDP_ENV_FILE, "r", encoding="utf-8") as f:
    orig_lines = f.read().splitlines()

seen_keys = set()
new_lines = []
for line in orig_lines:
    stripped = line.strip()
    if stripped and not stripped.startswith("#") and "=" in line:
        k = line.split("=", 1)[0].strip()
        if k in idp_updates:
            new_lines.append(f"{k}={idp_updates[k]}")
            seen_keys.add(k)
            continue
    new_lines.append(line)

missing = [k for k in idp_updates if k not in seen_keys]
if missing:
    if new_lines and new_lines[-1].strip() != "":
        new_lines.append("")
    new_lines.append("# Next iDP wiring (nextdp-core)")
    for k in missing:
        new_lines.append(f"{k}={idp_updates[k]}")

st = os.stat(NEXTDP_ENV_FILE)
fd2, tmp_env = tempfile.mkstemp(prefix=".env.", dir=os.path.dirname(NEXTDP_ENV_FILE))
os.chmod(tmp_env, st.st_mode & 0o777)
with os.fdopen(fd2, "w", encoding="utf-8", newline="\n") as f:
    f.write("\n".join(new_lines) + "\n")
os.chown(tmp_env, st.st_uid, st.st_gid)
os.chmod(tmp_env, st.st_mode & 0o777)
os.replace(tmp_env, NEXTDP_ENV_FILE)

# 8) Verify minted keys & realm_admin login on Next iDP loopback
bearer_hdr = {
    "Host": MASTER_HOST,
    "Accept": "application/json",
    "X-N1-Realm": realm_id,
    "Authorization": f"Bearer {tenant_key_secret}",
}
req_t = urllib.request.Request(f"{BASE}/api/v1/realm/tenants", headers=bearer_hdr)
with urllib.request.urlopen(req_t, timeout=15) as r_t:
    if r_t.status != 200:
        raise RuntimeError(f"Tenant key probe failed: {r_t.status}")

bearer_c = {
    "Host": REALM_HOST,
    "Accept": "application/json",
    "Authorization": f"Bearer {contract_key_secret}",
}
req_c = urllib.request.Request(f"{BASE}/api/v1/realm/events?limit=1", headers=bearer_c)
with urllib.request.urlopen(req_c, timeout=15) as r_c:
    if r_c.status != 200:
        raise RuntimeError(f"Contract key probe failed: {r_c.status}")

issuer_client = Client(REALM_HOST, issuer_url, "web-brand")
if admin_pw:
    _, login_res = issuer_client.request("POST", "/api/v1/auth/login", {"email": ADMIN_EMAIL, "password": admin_pw})
    u_logged = login_res.get("user") or {}
    if (u_logged.get("tenant_role") or u_logged.get("role")) != "realm_admin":
        raise RuntimeError(f"Unexpected realm role on {REALM_HOST}: {u_logged}")
    issuer_client.request("POST", "/api/v1/auth/logout", {})
    login_probe_status = "200"
else:
    login_probe_status = "skipped_owner_password_kept"

print(f"realm={REALM_SLUG} id={realm_id} status={realm_action} host={REALM_HOST} host_status={host_status}")
print(f"admin={ADMIN_EMAIL} user_id={uid} action={user_action} role=realm_admin login_probe={login_probe_status}")
print(f"client=nextdp-core client_id={client_id} action={client_action}")
print(f"tenant_key={tenant_key_row.get('key_prefix', tenant_key_secret[:12])} action={tenant_key_action} scopes=tenants.admin")
print(f"contract_key={contract_key_row.get('key_prefix', contract_key_secret[:12])} action={contract_key_action} client_id={client_id}")
print(f"webhook_id={webhook_id} url={webhook_url} action={hook_action}")
for d in dns_records:
    print(f"dns_required type={d.get('type')} name={d.get('name')} value={d.get('value')}")
PY

echo "==> Restarting nextdp, nextdp-worker, nextdp-scheduler..."
systemctl restart nextdp nextdp-worker nextdp-scheduler
for i in $(seq 1 20); do
  if curl -fsS http://127.0.0.1:8090/health >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

curl -fsS http://127.0.0.1:8090/health
echo
echo "services=$(systemctl is-active nextdp nextdp-worker nextdp-scheduler | tr '\n' ' ')"
stat -c "secrets_mode=%a" "$CORE_IDP_ENV_FILE"
