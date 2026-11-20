#!/usr/bin/env bash
# Ensure platform master_admin account (rajesh@nextdp.com) exists for core.nextdp.com
# on Apps-Core-VM (43.204.42.99) via NextDP Core's `ops:make-superadmin` / `ops:set-user-password`,
# save credentials strictly to 0600 /root/.nextdp-core-admin-secrets.env (never echoed to stdout),
# and verify live HTTPS login at https://core.nextdp.com/login.
set -Eeuo pipefail

APP_DIR=/srv/apps/nextdp/current
ENV_FILE=/srv/apps/nextdp/shared/.env
SECRETS_OUT=/root/.nextdp-core-admin-secrets.env
TARGET_EMAIL="rajesh@nextdp.com"

sudo test -x "$APP_DIR/nextdp" || { echo "FATAL: missing $APP_DIR/nextdp" >&2; exit 1; }
sudo test -f "$ENV_FILE" || { echo "FATAL: missing $ENV_FILE" >&2; exit 1; }

EXISTING_ID=$(sudo -u postgres psql -d nextdp_core -Atc \
  "SELECT u.id FROM users u JOIN auth_groups_users g ON g.user_id = u.id JOIN auth_identities ai ON ai.user_id = u.id WHERE g.\"group\" = 'master_admin' AND ai.type = 'email_password' AND lower(ai.secret) = lower('${TARGET_EMAIL}') LIMIT 1;" || true)

if [ -z "$EXISTING_ID" ] || ! sudo test -f "$SECRETS_OUT"; then
  echo "==> Provisioning/resetting core.nextdp.com master_admin (${TARGET_EMAIL}) via ops CLI"
  sudo python3 - "$APP_DIR" "$ENV_FILE" "$SECRETS_OUT" "$TARGET_EMAIL" "$EXISTING_ID" <<'PY'
import os, re, subprocess, sys

app_dir, env_file, out_path, email, existing_id = sys.argv[1:6]
env = os.environ.copy()
with open(env_file, "r", encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip().strip('"').strip("'")

if not existing_id:
    args = [os.path.join(app_dir, "nextdp"), "ops:make-superadmin", "--group", "master_admin", "--random-password", email]
else:
    args = [os.path.join(app_dir, "nextdp"), "ops:set-user-password", "--random-password", email]

proc = subprocess.run(
    args,
    cwd=app_dir,
    env=env,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
)
combined = (proc.stdout or "") + "\n" + (proc.stderr or "")
if proc.returncode != 0:
    raise SystemExit(f"FATAL ops CLI failed ({proc.returncode}): {combined}")

m = re.search(r"Temporary password[^:]*:\s*(\S+)", combined)
if not m:
    raise SystemExit("FATAL: could not parse generated password from ops CLI output")
pw = m.group(1).strip()

content = (
    f"NEXTDP_CORE_URL=https://core.nextdp.com\n"
    f"NEXTDP_CORE_ADMIN_EMAIL={email}\n"
    f"NEXTDP_CORE_ADMIN_PASSWORD={pw}\n"
    f"NEXTDP_CORE_ADMIN_GROUP=master_admin\n"
    f"NEXTDP_CORE_VM_IP=43.204.42.99\n"
)
fd = os.open(out_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as f:
    f.write(content)
os.chmod(out_path, 0o600)
print("Credentials written safely to", out_path)
PY
else
  echo "==> core.nextdp.com master_admin ${TARGET_EMAIL} already exists (id=${EXISTING_ID}) with secrets file present"
fi

ROW=$(sudo -u postgres psql -d nextdp_core -Atc \
  "SELECT u.id || '|' || u.brand_id || '|' || ai.secret || '|' || u.role || '|' || g.\"group\" || '|' || u.active || '|' || coalesce(u.public_id, '') FROM users u JOIN auth_groups_users g ON g.user_id = u.id JOIN auth_identities ai ON ai.user_id = u.id WHERE ai.type = 'email_password' AND lower(ai.secret) = lower('${TARGET_EMAIL}') AND g.\"group\" = 'master_admin' LIMIT 1;")
if [ -z "$ROW" ]; then
  echo "FATAL: master_admin user ${TARGET_EMAIL} not found in nextdp_core DB" >&2
  exit 1
fi
IFS='|' read -r UID_DB BRAND_DB EMAIL_DB ROLE_DB GROUP_DB ACTIVE_DB PUBID_DB <<< "$ROW"
echo "==> DB verified: id=${UID_DB} brand_id=${BRAND_DB} email=${EMAIL_DB} role=${ROLE_DB} group=${GROUP_DB} active=${ACTIVE_DB} public_id=${PUBID_DB}"

sudo python3 - "$SECRETS_OUT" "$UID_DB" "$BRAND_DB" "$PUBID_DB" <<'PY'
import sys
p, uid, bid, pub = sys.argv[1:5]
with open(p, "r", encoding="utf-8") as f:
    lines = f.read().splitlines()
kv = {}
for line in lines:
    if "=" in line and not line.startswith("#"):
        k, v = line.split("=", 1)
        kv[k] = v
kv["NEXTDP_CORE_ADMIN_USER_ID"] = uid
kv["NEXTDP_CORE_ADMIN_BRAND_ID"] = bid
kv["NEXTDP_CORE_ADMIN_PUBLIC_ID"] = pub
with open(p, "w", encoding="utf-8", newline="\n") as f:
    for k, v in kv.items():
        f.write(f"{k}={v}\n")
PY
sudo chmod 0600 "$SECRETS_OUT"

echo "==> Verifying live HTTPS form login at https://core.nextdp.com/login"
sudo python3 - "$SECRETS_OUT" <<'PY'
import http.cookiejar, re, sys, urllib.parse, urllib.request, urllib.error

cfg = {}
with open(sys.argv[1], "r", encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if "=" in line and not line.startswith("#"):
            k, v = line.split("=", 1)
            cfg[k] = v

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None

jar = http.cookiejar.CookieJar()
opener = urllib.request.build_opener(urllib.request.HTTPRedirectHandler(), urllib.request.HTTPCookieProcessor(jar))

# Use non-redirecting opener first to observe exact POST /login 302 Location
nr_opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar), NoRedirect())

with nr_opener.open("https://core.nextdp.com/login", timeout=10) as r:
    html = r.read().decode("utf-8", "replace")
m = re.search(r'name="_csrf_token"\s+value="([^"]+)"', html)
if not m:
    raise SystemExit("FATAL: _csrf_token not found on https://core.nextdp.com/login")
csrf = m.group(1)

data = urllib.parse.urlencode({
    "_csrf_token": csrf,
    "email": cfg["NEXTDP_CORE_ADMIN_EMAIL"],
    "password": cfg["NEXTDP_CORE_ADMIN_PASSWORD"],
}).encode("utf-8")
req = urllib.request.Request(
    "https://core.nextdp.com/login",
    data=data,
    headers={
        "Content-Type": "application/x-www-form-urlencoded",
        "Origin": "https://core.nextdp.com",
        "Referer": "https://core.nextdp.com/login",
    },
    method="POST",
)
try:
    resp = nr_opener.open(req, timeout=10)
    st, loc = resp.status, resp.headers.get("Location", "")
except urllib.error.HTTPError as e:
    st, loc = e.code, e.headers.get("Location", "")

print(f"POST /login -> HTTP={st} Location={loc}")
if st not in (302, 303) or "/login" in loc:
    raise SystemExit(f"FATAL: core.nextdp.com login failed (HTTP {st}, Location={loc})")

dash_url = urllib.parse.urljoin("https://core.nextdp.com", loc or "/")
with nr_opener.open(dash_url, timeout=10) as r2:
    print(f"Dashboard {dash_url} -> HTTP={r2.status}")
    if r2.status != 200:
        raise SystemExit(f"FATAL: expected 200 on {dash_url}, got {r2.status}")
PY

sudo -u postgres psql -d nextdp_core -c "DELETE FROM auth_sessions WHERE user_id = '${UID_DB}';" >/dev/null || true
