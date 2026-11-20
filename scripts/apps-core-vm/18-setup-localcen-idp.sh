#!/usr/bin/env bash
# Runs on Apps-Core-VM. Sets up everything LocalCen needs in Next iDP (docs/localcen-saas-integration.md):
#   A. realm cconsole: apps localcen-console (access assigned, organisations) + localcen-admin (roles
#      realm_admin/support), realm key localcen-contract, webhook -> LocalCen /v1/idp/webhook,
#      organisations on, the owner's cconsole account as realm_admin
#   B. top-level realm localcen (API-only, platform reverse-OTP gateway allowed) + tenant key localcen-tenants
#   C. child realm localcen-people on myaccount.localcen.com (hosted): phone-only sign-in with Reverse OTP
#      only (reverse SMS + reverse WhatsApp), sign-up by phone, en/hi/te, gateways "inherit",
#      webhook -> LocalCen /v1/idp/tenant-webhook
#   D. all values in 0600 /root/.localcen-idp.env (never printed)
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
BASE = "http://127.0.0.1:8080"
MASTER = "nextidp.com"
OUT = "/root/.localcen-idp.env"
LC = "https://localcen.cconsole.com"
LC_ADMIN = "https://admin.localcen.cconsole.com"
PEOPLE_HOST = "myaccount.localcen.com"
APPLY = MODE == "apply"

def envf(p):
    d = {}
    if os.path.exists(p):
        for l in open(p, encoding="utf-8"):
            s = l.strip()
            if s and not s.startswith("#") and "=" in s:
                k, v = s.split("=", 1); d[k.strip()] = v.strip().strip('"').strip("'")
    return d

saved = envf(OUT)
adm = envf("/root/.nextidp-operator.env") or {}
adm2 = envf("/root/.nextidp-admin-secrets.env")
email = adm.get("NEXTIDP_OPERATOR_EMAIL") or adm.get("NEXTIDP_ADMIN_EMAIL") or adm2.get("NEXTIDP_ADMIN_EMAIL", "")
pw = adm.get("NEXTIDP_OPERATOR_PASSWORD") or adm.get("NEXTIDP_ADMIN_PASSWORD") or adm2.get("NEXTIDP_ADMIN_PASSWORD", "")
if not email or not pw:
    sys.exit("FATAL: no Next iDP platform admin credentials on this VM")

jar = http.cookiejar.CookieJar()
opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))

def call(method, path, body=None, realm=None, bearer=None, host=MASTER, ok=(200, 201, 204), quiet404=False):
    h = {"Host": host, "Accept": "application/json"}
    if not bearer:
        h.update({"Origin": f"https://{host}", "X-N1-Client": "web-master"})
    else:
        h["Authorization"] = f"Bearer {bearer}"
    if realm:
        h["X-N1-Realm"] = realm
    data = None
    if body is not None:
        data = json.dumps(body).encode(); h["Content-Type"] = "application/json"
    req = urllib.request.Request(BASE + path, data=data, method=method, headers=h)
    try:
        with opener.open(req, timeout=30) as r:
            raw = r.read().decode("utf-8", "replace")
            return r.status, (json.loads(raw) if raw.strip() else {})
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", "replace")
        try:
            j = json.loads(raw) if raw.strip() else {}
        except Exception:
            j = {"raw": raw[:300]}
        if e.code in ok:
            return e.code, j
        if quiet404 and e.code == 404:
            return 404, j
        raise SystemExit(f"FATAL: {method} {path} -> HTTP {e.code}: {json.dumps(j)[:400]}")

call("POST", "/api/v1/auth/login", {"email": email, "password": pw})
call("POST", "/api/v1/auth/reauth", {"Password": pw})
print(f"master session OK; MODE={MODE}")

def realm_by_slug(slug):
    _, r = call("GET", "/api/v1/admin/realms?q=" + urllib.parse.quote(slug) + "&limit=100")
    return next((x for x in (r.get("data") or []) if x.get("slug") == slug), None)

def realm_detail(rid):
    _, r = call("GET", f"/api/v1/admin/realms/{rid}")
    d = r.get("data") or {}
    return d.get("realm") or d, d

out = dict(saved)

# ---------- A. cconsole ----------
cc = realm_by_slug("cconsole")
if not cc:
    sys.exit("FATAL: realm cconsole not found")
ccid = cc["id"]
ccv, _ = realm_detail(ccid)
print(f"[A] cconsole {ccid} host={ccv.get('issuer_host')} status={ccv.get('host_status')} organizations_enabled={ccv.get('organizations_enabled')}")
_, us = call("GET", "/api/v1/realm/users?limit=100", realm=ccid)
for u in us.get("data") or []:
    print(f"    user {u.get('email')} role={u.get('role')}")
owner = next((u for u in (us.get("data") or []) if (u.get("email") or "").lower() == OWNER_EMAIL), None)
_, cl = call("GET", "/api/v1/realm/clients?limit=100", realm=ccid)
clients = cl.get("data") or []
print("    apps: " + ", ".join(sorted(c.get("client_id", "") for c in clients)))
_, ks = call("GET", "/api/v1/realm/api-keys", realm=ccid)
print("    keys: " + ", ".join(sorted(k.get("name", "") for k in (ks.get("data") or []))))
_, wh = call("GET", "/api/v1/realm/webhooks", realm=ccid)
print("    webhooks: " + ", ".join(sorted(w.get("url", "") for w in (wh.get("data") or []))))

# ---------- B/C. localcen + localcen-people ----------
lc = realm_by_slug("localcen")
pp = realm_by_slug("localcen-people")
print(f"[B] realm localcen: {'exists ' + lc['id'] if lc else 'missing'}; [C] localcen-people: {'exists ' + pp['id'] if pp else 'missing'}")
_, sfx = call("GET", "/api/v1/admin/system/suffixes", ok=(200,), quiet404=True)
print(f"    platform suffixes: {json.dumps(sfx.get('data', sfx))[:200]}")
_, gw = call("GET", "/api/v1/admin/smsgw", ok=(200,), quiet404=True)
print(f"    platform reverse-OTP gateway: {json.dumps(gw.get('data', gw))[:300]}")

if not APPLY:
    print("CHECK DONE (nothing written)")
    sys.exit(0)

# ===== APPLY =====
# A1 organisations on cconsole
if not ccv.get("organizations_enabled"):
    call("PATCH", f"/api/v1/admin/realms/{ccid}", {"organizations_enabled": True})
    print("[A] cconsole organizations_enabled -> true")

def ensure_client(realm, ext, body, secret_key):
    _, r = call("GET", "/api/v1/realm/clients?external_id=" + urllib.parse.quote(ext), realm=realm)
    found = next((c for c in (r.get("data") or []) if c.get("external_id") == ext), None)
    if found:
        cid = found["client_id"]
        sec = out.get(secret_key, "")
        if not sec:
            _, rs = call("POST", f"/api/v1/realm/clients/{found.get('id') or cid}/rotate-secret", {}, realm=realm)
            sec = rs.get("client_secret", ""); act = "secret_rotated"
        else:
            act = "existing"
        return cid, sec, act
    _, r = call("POST", "/api/v1/realm/clients", body, realm=realm, ok=(201,))
    return (r.get("data") or {}).get("client_id", ""), r.get("client_secret", ""), "created"

common = {"type": "confidential", "token_auth": "client_secret_basic", "grant_types": ["authorization_code", "refresh_token"],
          "scopes": ["openid", "profile", "email", "offline_access"], "first_party": True, "require_pkce": True}
cid, sec, act = ensure_client(ccid, "localcen-console", dict(common, name="localcen-console", external_id="localcen-console",
    description="LocalCen tenant console", redirect_uris=[f"{LC}/auth/callback"], post_logout_redirect_uris=[f"{LC}/"],
    backchannel_logout_uri=f"{LC}/auth/backchannel-logout", home_uri=f"{LC}/", access_mode="assigned", allowed_organizations=[]),
    "IDP_CONSOLE_CLIENT_SECRET")
out.update(IDP_CONSOLE_CLIENT_ID=cid, IDP_CONSOLE_CLIENT_SECRET=sec); print(f"[A] app localcen-console {cid} {act}")
cid, sec, act = ensure_client(ccid, "localcen-admin", dict(common, name="localcen-admin", external_id="localcen-admin",
    description="LocalCen platform admin", redirect_uris=[f"{LC_ADMIN}/auth/callback"], post_logout_redirect_uris=[f"{LC_ADMIN}/"],
    backchannel_logout_uri=f"{LC_ADMIN}/auth/backchannel-logout", home_uri=f"{LC_ADMIN}/", access_mode="roles",
    allowed_roles=["realm_admin", "support"]), "IDP_ADMIN_CLIENT_SECRET")
out.update(IDP_ADMIN_CLIENT_ID=cid, IDP_ADMIN_CLIENT_SECRET=sec); print(f"[A] app localcen-admin {cid} {act}")

def ensure_key(realm, name, scopes, saved_key, bearer=None, host=MASTER):
    _, r = call("GET", "/api/v1/realm/api-keys", realm=realm, bearer=bearer, host=host)
    found = next((k for k in (r.get("data") or []) if k.get("name") == name), None)
    if found and out.get(saved_key, "").startswith("n1k_"):
        return out[saved_key], "existing"
    if found:
        call("DELETE", f"/api/v1/realm/api-keys/{found['id']}", realm=realm, bearer=bearer, host=host)
    exp = (datetime.now(timezone.utc) + timedelta(days=365)).strftime("%Y-%m-%dT%H:%M:%SZ")
    _, r = call("POST", "/api/v1/realm/api-keys", {"name": name, "scopes": scopes, "expires_at": exp}, realm=realm,
                bearer=bearer, host=host, ok=(201,))
    return r.get("secret_key", ""), "created"

k, act = ensure_key(ccid, "localcen-contract", ["users.read", "users.write", "orgs.read", "orgs.write", "clients.write",
                    "clients.self", "events.read", "signals.write", "dsr.ack"], "IDP_API_KEY")
out["IDP_API_KEY"] = k; print(f"[A] key localcen-contract {act}")

def ensure_webhook(realm, url, events, saved_key, desc, bearer=None):
    _, r = call("GET", "/api/v1/realm/webhooks", realm=realm, bearer=bearer)
    found = next((w for w in (r.get("data") or []) if w.get("url") == url), None)
    if found and out.get(saved_key):
        return out[saved_key], "existing"
    if found:
        _, rs = call("POST", f"/api/v1/realm/webhooks/{found['id']}/rotate-secret", {}, realm=realm, bearer=bearer)
        return rs.get("secret", ""), "secret_rotated"
    _, r = call("POST", "/api/v1/realm/webhooks", {"url": url, "description": desc, "events": events}, realm=realm,
                bearer=bearer, ok=(201,))
    return r.get("secret", ""), "created"

s, act = ensure_webhook(ccid, f"{LC}/v1/idp/webhook", ["user.updated", "user.email_changed", "user.deleted",
                        "privacy.dsr.erasure_requested"], "IDP_WEBHOOK_SECRET", "LocalCen consoles")
out["IDP_WEBHOOK_SECRET"] = s; print(f"[A] webhook {LC}/v1/idp/webhook {act}")

if owner and owner.get("role") != "realm_admin":
    call("PATCH", f"/api/v1/realm/users/{owner['id']}", {"role": "realm_admin"}, realm=ccid)
    print(f"[A] {OWNER_EMAIL} -> realm_admin")
elif owner:
    print(f"[A] {OWNER_EMAIL} already realm_admin")
else:
    print(f"[A] WARNING: {OWNER_EMAIL} has no cconsole account; create it, then rerun")

# B. top-level localcen (API-only) + platform gateway flag + tenant key
if not lc:
    _, r = call("POST", "/api/v1/admin/realms", {"name": "LocalCen", "slug": "localcen", "hosting_mode": "api_only"}, ok=(201,))
    lc = r.get("data") or {}
    print(f"[B] realm localcen created {lc.get('id')}")
lcid = lc["id"]
lcv, _ = realm_detail(lcid)
if not lcv.get("allow_platform_smsgw"):
    call("PATCH", f"/api/v1/admin/realms/{lcid}", {"allow_platform_smsgw": True})
    print("[B] localcen allow_platform_smsgw -> true")
tk, act = ensure_key(lcid, "localcen-tenants", ["tenants.admin"], "IDP_TENANT_KEY")
out["IDP_TENANT_KEY"] = tk; print(f"[B] tenant key localcen-tenants {act}")

# C. child localcen-people (hosted, myaccount.localcen.com) via the tenant key
if not pp:
    _, r = call("POST", "/api/v1/realm/tenants", {"name": "LocalCen ID", "slug": "localcen-people", "hostname": PEOPLE_HOST,
                "hosting_mode": "hosted"}, realm=lcid, bearer=tk, ok=(201,))
    pp = r.get("data") or {}
    print(f"[C] realm localcen-people created {pp.get('id')}")
ppid = pp["id"]
_, td = call("GET", f"/api/v1/realm/tenants/{ppid}", realm=lcid, bearer=tk)
tdd = td.get("data") or {}
dns = tdd.get("dns") or []
ppv = tdd.get("realm") or tdd
call("PATCH", "/api/v1/realm", {"login_policy": {"identifier_policy": "phone", "sign_in_identifiers": ["phone"], "password": False,
     "passkeys": False, "magic_link": False, "phone_otp": True, "otp_signup": True,
     "phone_verification_channels": ["reverse_sms", "reverse_whatsapp"], "require_mfa": False, "allowed_mfa": [],
     "require_verified_email": False}, "default_locale": "en", "supported_locales": ["en", "hi", "te"]}, realm=ppid, bearer=tk)
print("[C] login policy: phone only, Reverse OTP (reverse_sms, reverse_whatsapp), sign-up by phone; languages en/hi/te")
ppd, _ = realm_detail(ppid)
if not ppd.get("allow_platform_smsgw"):
    call("PATCH", f"/api/v1/admin/realms/{ppid}", {"allow_platform_smsgw": True})
    print("[C] localcen-people allow_platform_smsgw -> true")
for ch in ("sms", "whatsapp"):
    call("PUT", f"/api/v1/realm/smsgw/{ch}", {"mode": "inherit"}, realm=ppid)
print("[C] reverse-OTP gateways: sms=inherit whatsapp=inherit")
s, act = ensure_webhook(ppid, f"{LC}/v1/idp/tenant-webhook", ["user.status_changed", "user.suspended", "user.deactivated",
                        "user.deleted", "session.revoked_all", "user.updated", "user.phone_verified", "session.revoked"],
                        "IDP_PEOPLE_WEBHOOK_SECRET", "LocalCen people", bearer=tk)
out["IDP_PEOPLE_WEBHOOK_SECRET"] = s; print(f"[C] webhook {LC}/v1/idp/tenant-webhook {act}")

txt = next((d for d in dns if d.get("type") == "TXT"), {})
out.update({
    "IDP_LOGIN": "true", "IDP_ISSUER": ccv.get("issuer") or "https://accounts.cconsole.com", "IDP_REALM_ID": ccid,
    "IDP_PUBLIC_ORIGIN": LC, "IDP_OWNER_CONTACT": OWNER_EMAIL, "IDP_MASTER_URL": "https://nextidp.com",
    "IDP_PARENT_REALM_ID": lcid, "IDP_PEOPLE_REALM_ID": ppid, "IDP_PEOPLE_ISSUER": f"https://{PEOPLE_HOST}",
    "IDP_PEOPLE_CLIENT_KEYS_FILE": "/srv/apps/localcen/shared/keys/local-apps.jwks.json", "IDP_TENANT_WEBHOOK_SECRET": "",
    "PEOPLE_HOST_STATUS": ppv.get("host_status", ""), "DNS_TXT_NAME": txt.get("name", f"_n1-verify.{PEOPLE_HOST}"),
    "DNS_TXT_VALUE": txt.get("value", ""),
})
missing = [k for k in ("IDP_CONSOLE_CLIENT_ID", "IDP_CONSOLE_CLIENT_SECRET", "IDP_ADMIN_CLIENT_ID", "IDP_ADMIN_CLIENT_SECRET",
                       "IDP_API_KEY", "IDP_WEBHOOK_SECRET", "IDP_TENANT_KEY", "IDP_PEOPLE_WEBHOOK_SECRET") if not out.get(k)]
if missing:
    sys.exit(f"FATAL: missing values: {missing}")
fd, tmp = tempfile.mkstemp(prefix=".localcen-idp-", dir="/root")
os.chmod(tmp, 0o600)
with os.fdopen(fd, "w") as fh:
    fh.write(f"# LocalCen <-> Next iDP values ({datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}); never print\n")
    fh.write("".join(f"{k}={v}\n" for k, v in out.items()))
os.replace(tmp, OUT)
print(f"saved {OUT} (0600)")
print(f"people realm host_status={ppv.get('host_status')}")
for d in dns:
    print(f"dns_required type={d.get('type')} name={d.get('name')} value={d.get('value')}")
print("APPLY DONE")
PY
