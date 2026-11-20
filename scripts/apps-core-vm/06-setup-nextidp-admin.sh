#!/usr/bin/env bash
# Programmatically bootstrap the Next iDP platform master admin (rajesh@nextidp.com)
# on Apps-Core-VM (43.204.42.99) via `./nextidp db:seed` (seedMinimal), store the generated
# credentials in 0600 /root/.nextidp-admin-secrets.env (never echoed to stdout), and verify
# programmatic authentication against http://127.0.0.1:8080/api/v1/auth/login.
set -Eeuo pipefail

APP_DIR=/opt/nextidp
ENV_FILE=/etc/nextidp/env
ADMIN_SECRETS=/root/.nextidp-admin-secrets.env
TARGET_EMAIL="rajesh@nextidp.com"
TARGET_NAME="Rajesh"

sudo test -x "$APP_DIR/current/nextidp" || { echo "FATAL: $APP_DIR/current/nextidp missing" >&2; exit 1; }
sudo test -f "$ENV_FILE" || { echo "FATAL: $ENV_FILE missing" >&2; exit 1; }

EXISTING_ID=$(sudo -u postgres psql -d nextidp -Atc \
  "SELECT id FROM users WHERE realm_id = '' AND lower(email) = lower('${TARGET_EMAIL}') LIMIT 1;" || true)

if [ -z "$EXISTING_ID" ]; then
  SUPER_COUNT=$(sudo -u postgres psql -d nextidp -Atc \
    "SELECT count(*) FROM users WHERE is_super_admin = true AND active = true;" || echo "0")
  if [ "$SUPER_COUNT" != "0" ]; then
    echo "FATAL: another active super admin exists while ${TARGET_EMAIL} is absent; inspect nextidp users table" >&2
    exit 1
  fi

  # Generate a 24-char strong password + write /root/.nextidp-admin-secrets.env without echoing to stdout.
  PASS=$(python3 - <<'PY'
import secrets
upper = "ABCDEFGHJKLMNPQRSTUVWXYZ"
lower = "abcdefghijkmnopqrstuvwxyz"
digits = "23456789"
special = "@#%_-!"
all_chars = upper + lower + digits + special
chars = [secrets.choice(upper), secrets.choice(lower), secrets.choice(digits), secrets.choice(special)]
chars += [secrets.choice(all_chars) for _ in range(20)]
secrets.SystemRandom().shuffle(chars)
print("".join(chars), end="")
PY
)

  sudo install -m 0600 /dev/null "$ADMIN_SECRETS"
  sudo tee "$ADMIN_SECRETS" >/dev/null <<EOF
NEXTIDP_MASTER_URL=https://nextidp.com
NEXTIDP_ADMIN_EMAIL=${TARGET_EMAIL}
NEXTIDP_ADMIN_NAME=${TARGET_NAME}
NEXTIDP_ADMIN_PASSWORD=${PASS}
NEXTIDP_ADMIN_ROLE=platform_admin
NEXTIDP_APPS_CORE_IP=43.204.42.99
EOF
  sudo chmod 0600 "$ADMIN_SECRETS"

  if ! sudo grep -q '^N1_BOOTSTRAP_ADMIN_EMAIL=' "$ENV_FILE"; then
    echo "N1_BOOTSTRAP_ADMIN_EMAIL=${TARGET_EMAIL}" | sudo tee -a "$ENV_FILE" >/dev/null
  fi

  echo "==> Seeding Next iDP master admin (${TARGET_EMAIL}) via native db:seed"
  set -a
  # shellcheck disable=SC1090
  source <(sudo cat "$ENV_FILE")
  set +a
  export N1_BOOTSTRAP_ADMIN_EMAIL="${TARGET_EMAIL}"
  export N1_BOOTSTRAP_ADMIN_PASSWORD="${PASS}"
  export N1_BOOTSTRAP_ADMIN_NAME="${TARGET_NAME}"
  unset PASS

  (cd "$APP_DIR/current" && sudo -E -u nextidp ./nextidp db:seed)
  unset N1_BOOTSTRAP_ADMIN_PASSWORD
else
  echo "==> Master admin ${TARGET_EMAIL} already exists (id=${EXISTING_ID})"
  if ! sudo test -f "$ADMIN_SECRETS"; then
    echo "FATAL: ${TARGET_EMAIL} exists in DB but ${ADMIN_SECRETS} is missing" >&2
    exit 1
  fi
fi

USER_ROW=$(sudo -u postgres psql -d nextidp -Atc \
  "SELECT id || '|' || email || '|' || role || '|' || is_super_admin || '|' || active || '|' || must_change_password FROM users WHERE realm_id = '' AND lower(email) = lower('${TARGET_EMAIL}') LIMIT 1;")
if [ -z "$USER_ROW" ]; then
  echo "FATAL: user ${TARGET_EMAIL} not found after db:seed" >&2
  exit 1
fi
IFS='|' read -r UID_DB EMAIL_DB ROLE_DB SUPER_DB ACTIVE_DB MUST_CHANGE_DB <<< "$USER_ROW"
echo "==> DB verified: id=${UID_DB} email=${EMAIL_DB} role=${ROLE_DB} super=${SUPER_DB} active=${ACTIVE_DB} must_change_password=${MUST_CHANGE_DB}"

if ! sudo grep -q '^NEXTIDP_ADMIN_USER_ID=' "$ADMIN_SECRETS"; then
  echo "NEXTIDP_ADMIN_USER_ID=${UID_DB}" | sudo tee -a "$ADMIN_SECRETS" >/dev/null
fi
if ! sudo grep -q '^NEXTIDP_MUST_CHANGE_PASSWORD=' "$ADMIN_SECRETS"; then
  echo "NEXTIDP_MUST_CHANGE_PASSWORD=${MUST_CHANGE_DB}" | sudo tee -a "$ADMIN_SECRETS" >/dev/null
fi

echo "==> Verifying programmatic login via POST http://127.0.0.1:8080/api/v1/auth/login"
sudo python3 - <<'PY'
import json, urllib.request, urllib.error

cfg = {}
with open("/root/.nextidp-admin-secrets.env", "r", encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if "=" in line and not line.startswith("#"):
            k, v = line.split("=", 1)
            cfg[k] = v

req = urllib.request.Request(
    "http://127.0.0.1:8080/api/v1/auth/login",
    data=json.dumps({
        "email": cfg["NEXTIDP_ADMIN_EMAIL"],
        "password": cfg["NEXTIDP_ADMIN_PASSWORD"],
    }).encode("utf-8"),
    headers={
        "Host": "nextidp.com",
        "X-N1-Client": "web-master",
        "Content-Type": "application/json",
        "Accept": "application/json",
    },
    method="POST",
)
try:
    with urllib.request.urlopen(req, timeout=10) as resp:
        body = json.loads(resp.read().decode("utf-8"))
        user = body.get("user") or {}
        sess = body.get("session") or {}
        print(
            f"LOGIN_OK HTTP={resp.status} email={user.get('email')} "
            f"super={user.get('is_super_admin')} mfa_required={body.get('mfa_required', False)} "
            f"must_change_password={user.get('must_change_password')} session_console={sess.get('console')}"
        )
        if not user.get("is_super_admin") and not body.get("mfa_required"):
            raise SystemExit("FATAL: login response missing super admin flag")
except urllib.error.HTTPError as e:
    err_body = e.read().decode("utf-8", "replace")
    raise SystemExit(f"FATAL: login failed HTTP {e.code}: {err_body}")
PY
