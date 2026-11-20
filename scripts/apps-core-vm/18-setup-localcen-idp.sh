#!/usr/bin/env bash
# Runs on Apps-Core-VM. Sets up what LocalCen needs in Next iDP (docs/localcen-saas-integration.md):
#   A. realm cconsole (signed in as its realm admin, /root/.nextidp-cconsole-dns.env): apps
#      localcen-console (access assigned) + localcen-admin (roles realm_admin/support), realm key
#      localcen-contract, webhook -> LocalCen /v1/idp/webhook, the owner's cconsole account as realm_admin
#   B. top-level realm localcen (made by the owner; hosted on localcen.nextidp.com) is only checked:
#      its tenant key comes from /root/.localcen-idp-input.env (LOCALCEN_REALM_ID, LOCALCEN_TENANT_KEY)
#   C. child realm localcen-people on myaccount.localcen.com (hosted), made with the tenant key:
#      phone-only sign-in with Reverse OTP only (reverse SMS + reverse WhatsApp), sign-up by phone,
#      en/hi/te, webhook -> LocalCen /v1/idp/tenant-webhook
#   D. all values in 0600 /root/.localcen-idp.env (never printed)
# Not done here (need a signed-in session, owner steps): master "Allow platform SMS gateway" on localcen,
# and Reverse OTP -> SMS / WhatsApp = inherit in the localcen console (localcen-people uses the parent's).
# MODE=check (read-only report) | apply. Idempotent: existing objects are kept; secrets kept from the env file.
set -Eeuo pipefail
exec 2>&1
MODE="${MODE:-check}"
OWNER_EMAIL="${OWNER_EMAIL:-rajesh@cconsole.com}"
[[ "$MODE" =~ ^(check|apply)$ ]] || { echo "FATAL: MODE must be check or apply"; exit 1; }
sudo env MODE="$MODE" OWNER_EMAIL="$OWNER_EMAIL" python3 - <<'PY'
import http.cookiejar, json, os, sys, tempfile, urllib.error, urllib.parse, urllib.request
from datetime import datetime, timedelta, timezone

MODE, OWNER_EMAIL = os.environ["MODE"], os.environ["OWNER_EMAIL"].lower()
APPLY = MODE == "apply"
BASE = "http://127.0.0.1:8080"
MASTER = "nextidp.com"
CC_HOST = "accounts.cconsole.com"
OUT = "/root/.localcen-idp.env"
LC = "https://localcen.cconsole.com"
LC_ADMIN = "https://admin.localcen.cconsole.com"
PEOPLE_HOST = "myaccount.localcen.com"
PEOPLE_SLUG = "localcen-people"

def envf(p):
    d = {}
    if os.path.exists(p):
        for l in open(p, encoding="utf-8"):
            s = l.strip()
            if s and not s.startswith("#") and "=" in s:
                k, v = s.split("=", 1); d[k.strip()] = v.strip().strip('"').strip("'")
    return d

saved = envf(OUT)
inp = envf("/root/.localcen-idp-input.env")
LCID, TK = inp.get("LOCALCEN_REALM_ID", ""), inp.get("LOCALCEN_TENANT_KEY", "")
if not LCID or not TK.startswith("n1k_"):
    sys.exit("FATAL: /root/.localcen-idp-input.env needs LOCALCEN_REALM_ID and LOCALCEN_TENANT_KEY (n1k_...)")
# cconsole access: an owner-made realm key (CCONSOLE_SETUP_KEY, scope realm.admin) in the input file;
# else the realm admin login in /root/.nextidp-cconsole-dns.env (fails when it asks for a second factor).
CC_KEY = inp.get("CCONSOLE_SETUP_KEY", "")
ccf = envf("/root/.nextidp-cconsole-dns.env")
CC_EMAIL, CC_PW = ccf.get("CCONSOLE_ADMIN_EMAIL", ""), ccf.get("CCONSOLE_ADMIN_PASSWORD", "")

class Api:
    """bearer=None: a console session on host (cookies); else Authorization: Bearer."""
    def __init__(self, host, client=None, bearer=None):
        self.host, self.client, self.bearer = host, client, bearer
        self.op = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))

    def __call__(self, method, path, body=None, realm=None, ok=(200, 201, 204), soft=()):
        h = {"Host": self.host, "Accept": "application/json"}
        if self.bearer:
            h["Authorization"] = f"Bearer {self.bearer}"
        else:
            h.update({"Origin": f"https://{self.host}", "X-N1-Client": self.client})
        if realm:
            h["X-N1-Realm"] = realm
        data = None
        if body is not None:
            data = json.dumps(body).encode(); h["Content-Type"] = "application/json"
        req = urllib.request.Request(BASE + path, data=data, method=method, headers=h)
        try:
            with self.op.open(req, timeout=30) as r:
                raw = r.read().decode("utf-8", "replace")
                return r.status, (json.loads(raw) if raw.strip() else {})
        except urllib.error.HTTPError as e:
            raw = e.read().decode("utf-8", "replace")
            try:
                j = json.loads(raw) if raw.strip() else {}
            except Exception:
                j = {"raw": raw[:300]}
            if e.code in ok or e.code in soft:
                return e.code, j
            raise SystemExit(f"FATAL: {method} {path} -> HTTP {e.code}: {json.dumps(j)[:400]}")

def data(j):
    return j.get("data", j) if isinstance(j, dict) else j

out = dict(saved)
print(f"MODE={MODE}")

# ---------- A. cconsole ----------
def cconsole():
    if CC_KEY:
        return Api(CC_HOST, bearer=CC_KEY), "key CCONSOLE_SETUP_KEY"
    if not CC_EMAIL or not CC_PW:
        return None, "no cconsole login or key"
    api = Api(CC_HOST, client="web-brand")
    st, j = api("POST", "/api/v1/auth/login", {"email": CC_EMAIL, "password": CC_PW}, soft=(401, 403, 429))
    if st != 200:
        return None, f"sign-in as {CC_EMAIL} -> HTTP {st}"
    if j.get("mfa_required"):
        return None, f"sign-in as {CC_EMAIL} asks for a second factor"
    return api, f"session {CC_EMAIL}"

cc, how = cconsole()
CC_SESSION = how.startswith("session")
if cc is None:
    print(f"[A] cconsole: NO ACCESS ({how}); add CCONSOLE_SETUP_KEY to private-data/localcen-idp-input.env")
    if APPLY:
        sys.exit("FATAL: cconsole access needed for apply")
ccv, ccid, owner = {}, "", None
if cc is not None:
    print(f"[A] cconsole access: {how}")
    _, j = cc("GET", "/api/v1/realm")
    ccv = data(j)
    ccid = ccv.get("id", "")
    print(f"[A] cconsole {ccid} issuer={ccv.get('issuer')} organizations_enabled={ccv.get('organizations_enabled')}")
    _, j = cc("GET", "/api/v1/realm/users?limit=100")
    users = data(j) or []
    for u in users:
        print(f"    user {u.get('email')} role={u.get('role')}")
    owner = next((u for u in users if (u.get("email") or "").lower() == OWNER_EMAIL), None)
    _, j = cc("GET", "/api/v1/realm/clients?limit=100")
    print("    apps: " + (", ".join(sorted(c.get("client_id", "") for c in (data(j) or []))) or "-"))
    _, j = cc("GET", "/api/v1/realm/api-keys")
    print("    keys: " + (", ".join(sorted(k.get("name", "") for k in (data(j) or []))) or "-"))
    _, j = cc("GET", "/api/v1/realm/webhooks")
    print("    webhooks: " + (", ".join(sorted(w.get("url", "") for w in (data(j) or []))) or "-"))

# ---------- B. localcen (tenant key on the master host) ----------
tk = Api(MASTER, bearer=TK)
st, j = tk("GET", "/api/v1/realm", realm=LCID, soft=(401, 403, 404))
if st != 200:
    sys.exit(f"FATAL: tenant key on realm {LCID} -> HTTP {st} {json.dumps(j)[:200]}")
lcv = data(j)
print(f"[B] localcen {lcv.get('id')} slug={lcv.get('slug')} hosting={lcv.get('hosting_mode')} host={lcv.get('issuer_host')} "
      f"status={lcv.get('host_status')} allow_platform_smsgw={lcv.get('allow_platform_smsgw')}")
if lcv.get("slug") != "localcen" or lcv.get("parent_realm_id"):
    sys.exit("FATAL: LOCALCEN_REALM_ID is not the top-level realm 'localcen'")
_, j = tk("GET", "/api/v1/realm/tenants?limit=100", realm=LCID)
kids = data(j) or []
pp = next((x for x in kids if x.get("slug") == PEOPLE_SLUG), None)
print("    tenants: " + (", ".join(f"{x.get('slug')}({x.get('issuer_host') or 'api-only'})" for x in kids) or "-"))
if not pp:
    _, j = tk("POST", "/api/v1/realm/tenants/check-hostname", {"hostname": PEOPLE_HOST}, realm=LCID)
    print(f"[C] {PEOPLE_SLUG} missing; hostname {PEOPLE_HOST}: {json.dumps(data(j))[:200]}")
else:
    print(f"[C] {PEOPLE_SLUG} exists {pp.get('id')} host={pp.get('issuer_host')} status={pp.get('host_status')}")

if not APPLY:
    print("CHECK DONE (nothing written)")
    sys.exit(0)

# ===== APPLY =====
if CC_SESSION:
    cc("POST", "/api/v1/auth/reauth", {"Password": CC_PW})

def ensure_client(api, ext, body, secret_key, realm=None):
    _, r = api("GET", "/api/v1/realm/clients?external_id=" + urllib.parse.quote(ext), realm=realm)
    found = next((c for c in (data(r) or []) if c.get("external_id") == ext), None)
    if found:
        cid = found["client_id"]
        sec = out.get(secret_key, "")
        if sec:
            return cid, sec, "existing"
        _, rs = api("POST", f"/api/v1/realm/clients/{found.get('id') or cid}/rotate-secret", {}, realm=realm)
        return cid, rs.get("client_secret", "") or data(rs).get("client_secret", ""), "secret_rotated"
    _, r = api("POST", "/api/v1/realm/clients", body, realm=realm, ok=(201,))
    return data(r).get("client_id", ""), r.get("client_secret", ""), "created"

common = {"type": "confidential", "token_auth": "client_secret_basic", "grant_types": ["authorization_code", "refresh_token"],
          "scopes": ["openid", "profile", "email", "offline_access"], "first_party": True, "require_pkce": True}
cid, sec, act = ensure_client(cc, "localcen-console", dict(common, name="localcen-console", external_id="localcen-console",
    description="LocalCen tenant console", redirect_uris=[f"{LC}/auth/callback"], post_logout_redirect_uris=[f"{LC}/"],
    backchannel_logout_uri=f"{LC}/auth/backchannel-logout", home_uri=f"{LC}/", access_mode="assigned", allowed_organizations=[]),
    "IDP_CONSOLE_CLIENT_SECRET")
out.update(IDP_CONSOLE_CLIENT_ID=cid, IDP_CONSOLE_CLIENT_SECRET=sec); print(f"[A] app localcen-console {cid} {act}")
cid, sec, act = ensure_client(cc, "localcen-admin", dict(common, name="localcen-admin", external_id="localcen-admin",
    description="LocalCen platform admin", redirect_uris=[f"{LC_ADMIN}/auth/callback"], post_logout_redirect_uris=[f"{LC_ADMIN}/"],
    backchannel_logout_uri=f"{LC_ADMIN}/auth/backchannel-logout", home_uri=f"{LC_ADMIN}/", access_mode="roles",
    allowed_roles=["realm_admin", "support"]), "IDP_ADMIN_CLIENT_SECRET")
out.update(IDP_ADMIN_CLIENT_ID=cid, IDP_ADMIN_CLIENT_SECRET=sec); print(f"[A] app localcen-admin {cid} {act}")

_, r = cc("GET", "/api/v1/realm/api-keys")
found = next((k for k in (data(r) or []) if k.get("name") == "localcen-contract"), None)
if found and out.get("IDP_API_KEY", "").startswith("n1k_"):
    print("[A] key localcen-contract existing")
else:
    if found:
        cc("DELETE", f"/api/v1/realm/api-keys/{found['id']}")
    exp = (datetime.now(timezone.utc) + timedelta(days=365)).strftime("%Y-%m-%dT%H:%M:%SZ")
    _, r = cc("POST", "/api/v1/realm/api-keys", {"name": "localcen-contract", "expires_at": exp, "scopes": ["users.read",
              "users.write", "orgs.read", "orgs.write", "clients.write", "clients.self", "events.read", "signals.write", "dsr.ack"]},
              ok=(201,))
    out["IDP_API_KEY"] = r.get("secret_key", "") or data(r).get("secret_key", "")
    print("[A] key localcen-contract " + ("recreated" if found else "created"))

def ensure_webhook(api, url, events, saved_key, desc, realm=None):
    _, r = api("GET", "/api/v1/realm/webhooks", realm=realm)
    found = next((w for w in (data(r) or []) if w.get("url") == url), None)
    if found and out.get(saved_key):
        return out[saved_key], "existing"
    if found:
        _, rs = api("POST", f"/api/v1/realm/webhooks/{found['id']}/rotate-secret", {}, realm=realm)
        return rs.get("secret", "") or data(rs).get("secret", ""), "secret_rotated"
    _, r = api("POST", "/api/v1/realm/webhooks", {"url": url, "description": desc, "events": events}, realm=realm, ok=(201,))
    return r.get("secret", "") or data(r).get("secret", ""), "created"

s, act = ensure_webhook(cc, f"{LC}/v1/idp/webhook", ["user.updated", "user.email_changed", "user.deleted",
                        "privacy.dsr.erasure_requested"], "IDP_WEBHOOK_SECRET", "LocalCen consoles")
out["IDP_WEBHOOK_SECRET"] = s; print(f"[A] webhook {LC}/v1/idp/webhook {act}")

if owner and owner.get("role") != "realm_admin":
    cc("PATCH", f"/api/v1/realm/users/{owner['id']}", {"role": "realm_admin"})
    print(f"[A] {OWNER_EMAIL} -> realm_admin")
elif owner:
    print(f"[A] {OWNER_EMAIL} already realm_admin")
else:
    print(f"[A] WARNING: {OWNER_EMAIL} has no cconsole account; create it, then rerun")
if not ccv.get("organizations_enabled"):
    print("[A] WARNING: cconsole organizations are off (master console: Organizations on)")

# C. child localcen-people (hosted, myaccount.localcen.com) via the tenant key
if not pp:
    _, r = tk("POST", "/api/v1/realm/tenants", {"name": "LocalCen ID", "slug": PEOPLE_SLUG, "hostname": PEOPLE_HOST,
              "hosting_mode": "hosted"}, realm=LCID, ok=(201,))
    pp = data(r)
    print(f"[C] realm {PEOPLE_SLUG} created {pp.get('id')}")
ppid = pp["id"]
tk("PATCH", "/api/v1/realm", {"login_policy": {"identifier_policy": "phone", "sign_in_identifiers": ["phone"], "password": False,
   "passkeys": False, "magic_link": False, "phone_otp": True, "otp_signup": True,
   "phone_verification_channels": ["reverse_sms", "reverse_whatsapp"], "require_mfa": False, "allowed_mfa": [],
   "require_verified_email": False}, "default_locale": "en", "supported_locales": ["en", "hi", "te"]}, realm=ppid)
_, r = tk("GET", "/api/v1/realm", realm=ppid)
ppv = data(r)
lp = ppv.get("login_policy") or {}
print(f"[C] login policy: identifiers={lp.get('sign_in_identifiers')} phone_otp={lp.get('phone_otp')} otp_signup={lp.get('otp_signup')} "
      f"channels={lp.get('phone_verification_channels')} password={lp.get('password')}; locales={ppv.get('supported_locales')}")
s, act = ensure_webhook(tk, f"{LC}/v1/idp/tenant-webhook", ["user.status_changed", "user.suspended", "user.deactivated",
                        "user.deleted", "session.revoked_all", "user.updated", "user.phone_verified", "session.revoked"],
                        "IDP_PEOPLE_WEBHOOK_SECRET", "LocalCen people", realm=ppid)
out["IDP_PEOPLE_WEBHOOK_SECRET"] = s; print(f"[C] webhook {LC}/v1/idp/tenant-webhook {act}")
_, r = tk("GET", f"/api/v1/realm/tenants/{ppid}", realm=LCID)
td = data(r)
dns = td.get("dns") or (td.get("domains") or [{}])[0].get("dns") or []

out.update({
    "IDP_LOGIN": "true", "IDP_ISSUER": ccv.get("issuer") or f"https://{CC_HOST}", "IDP_REALM_ID": ccid,
    "IDP_PUBLIC_ORIGIN": LC, "IDP_OWNER_CONTACT": OWNER_EMAIL, "IDP_MASTER_URL": "https://nextidp.com",
    "IDP_PARENT_REALM_ID": LCID, "IDP_TENANT_KEY": TK, "IDP_PEOPLE_REALM_ID": ppid, "IDP_PEOPLE_ISSUER": f"https://{PEOPLE_HOST}",
    "IDP_PEOPLE_CLIENT_KEYS_FILE": "/srv/apps/localcen/shared/keys/local-apps.jwks.json",
})
missing = [k for k in ("IDP_CONSOLE_CLIENT_ID", "IDP_CONSOLE_CLIENT_SECRET", "IDP_ADMIN_CLIENT_ID", "IDP_ADMIN_CLIENT_SECRET",
                       "IDP_API_KEY", "IDP_WEBHOOK_SECRET", "IDP_TENANT_KEY", "IDP_PEOPLE_WEBHOOK_SECRET") if not out.get(k)]
fd, tmp = tempfile.mkstemp(prefix=".localcen-idp-", dir="/root")
os.chmod(tmp, 0o600)
with os.fdopen(fd, "w") as fh:
    fh.write(f"# LocalCen <-> Next iDP values ({datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}); never print\n")
    fh.write("".join(f"{k}={v}\n" for k, v in out.items()))
os.replace(tmp, OUT)
print(f"saved {OUT} (0600)")
if missing:
    sys.exit(f"FATAL: missing values: {missing}")
print(f"people realm host={ppv.get('issuer_host')} host_status={ppv.get('host_status')}")
for d in dns:
    print(f"dns_required type={d.get('type')} name={d.get('name')} value={d.get('value')}")
print("APPLY DONE")
PY
