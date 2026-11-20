#!/usr/bin/env bash
# Deploy domains-rajesh-app (CodeIgniter 4 + PG 16) onto Lightsail Web-1 (3.6.143.66):
# - Install Composer + vendor dependencies (--no-dev --optimize-autoloader)
# - Provision PostgreSQL 16 DB/role domains_rajesh + restore pg_dump -Fc backup + run spark migrate
# - Configure PHP 8.4-FPM pool (pm=ondemand) & hardened .env
# - Generate self-signed SAN TLS cert for domains.rajesh.in and Caddy auto-SSL for domains.rajesh1.com
# - Enable portfolio monitoring & expiry digest timers
set -Eeuo pipefail

STAGE_DIR="${STAGE_DIR:?STAGE_DIR must be set}"
OUTPUT_ENV="${OUTPUT_ENV:?OUTPUT_ENV must be set}"
APP_DIR=/srv/phpapps/domains.rajesh.app
ENV_FILE=$APP_DIR/.env
SECRETS_ONBOX=/root/.web1-domains-secrets.env
DUMP_FILE=$STAGE_DIR/domains_rajesh.dump
CADDY_SRC=$STAGE_DIR/domains.rajesh.app.caddy

[ -f "$STAGE_DIR/domains-app.tar.gz" ] || { echo "FATAL: missing domains-app.tar.gz" >&2; exit 1; }
[ -f "$DUMP_FILE" ] || { echo "FATAL: missing domains_rajesh.dump" >&2; exit 1; }
[ -f "$CADDY_SRC" ] || { echo "FATAL: missing domains.rajesh.app.caddy" >&2; exit 1; }

echo "=== [1/8] Ensure Composer & PHP extensions ==="
php -r 'foreach (["curl","mbstring","intl","pgsql","pdo_pgsql","xml","zip"] as $e) { if (!extension_loaded($e)) { fwrite(STDERR, "Missing PHP ext: $e\n"); exit(1); } }'
if ! command -v composer >/dev/null 2>&1; then
  TMP_C=$(mktemp)
  curl -fsSL https://getcomposer.org/installer -o "$TMP_C"
  sudo php "$TMP_C" -- --install-dir=/usr/local/bin --filename=composer >/dev/null
  rm -f "$TMP_C"
fi
composer --version

echo "=== [2/8] On-box secrets (/root/.web1-domains-secrets.env, 0600) ==="
if ! sudo test -f "$SECRETS_ONBOX"; then
  sudo tee "$SECRETS_ONBOX" >/dev/null <<EOF
# Generated on-box for domains-rajesh-app on Web-1 — NEVER echo or commit
DB_NAME=domains_rajesh
DB_USER=domains_rajesh
DB_PASS=$(openssl rand -hex 24)
ENC_KEY=hex2bin:$(openssl rand -hex 32)
API_KEY=$(openssl rand -hex 32)
EOF
  sudo chmod 600 "$SECRETS_ONBOX"
fi
set -a
# shellcheck disable=SC1090
source <(sudo cat "$SECRETS_ONBOX")
set +a

echo "=== [3/8] PostgreSQL 16 role/database + pg_restore from backup ==="
(cd /tmp && sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" | grep -q 1 \
  || sudo -u postgres psql -qc "CREATE ROLE ${DB_USER} LOGIN PASSWORD '${DB_PASS}';")
(cd /tmp && sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q 1 \
  || sudo -u postgres createdb -O "${DB_USER}" -E UTF8 "${DB_NAME}")
(cd /tmp && sudo -u postgres psql -d "${DB_NAME}" -qc "REVOKE ALL ON DATABASE ${DB_NAME} FROM PUBLIC; GRANT CONNECT, TEMP ON DATABASE ${DB_NAME} TO ${DB_USER}; ALTER SCHEMA public OWNER TO ${DB_USER}; GRANT ALL ON SCHEMA public TO ${DB_USER};")

echo "  restoring dump into ${DB_NAME}..."
PG_TMP_DUMP=$(mktemp /tmp/domains-pg-restore.XXXXXX.dump)
trap 'sudo rm -f "$PG_TMP_DUMP"' EXIT
cp "$DUMP_FILE" "$PG_TMP_DUMP"
sudo chown postgres:postgres "$PG_TMP_DUMP"
sudo chmod 0600 "$PG_TMP_DUMP"

echo "  inspecting dump archive entries..."
sudo -u postgres pg_restore -l "$PG_TMP_DUMP" | grep -E 'TABLE DATA public ' | head -n 20 || true

# Drop & recreate public schema cleanly before pg_restore so repeated restores are deterministic
(cd /tmp && sudo -u postgres psql -d "${DB_NAME}" -v ON_ERROR_STOP=1 -qc \
  "DROP SCHEMA IF EXISTS public CASCADE; CREATE SCHEMA public AUTHORIZATION ${DB_USER}; GRANT ALL ON SCHEMA public TO ${DB_USER};")
(cd /tmp && sudo -u postgres pg_restore --no-owner --no-privileges --role="${DB_USER}" -d "${DB_NAME}" "$PG_TMP_DUMP")
sudo rm -f "$PG_TMP_DUMP"
(cd /tmp && sudo -u postgres psql -d "${DB_NAME}" -v ON_ERROR_STOP=1 -qc \
  "ALTER SCHEMA public OWNER TO ${DB_USER}; GRANT ALL ON ALL TABLES IN SCHEMA public TO ${DB_USER}; GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO ${DB_USER};")

echo "=== [4/8] Extract app code & install Composer vendor deps ==="
sudo install -d -o webapps -g caddy -m 0755 "$APP_DIR"
KEEP_ENV=$(mktemp)
if sudo test -f "$ENV_FILE"; then
  sudo cp "$ENV_FILE" "$KEEP_ENV"
else
  rm -f "$KEEP_ENV"
  KEEP_ENV=""
fi

# Clean extract preserving writable runtime state and .env
sudo find "$APP_DIR" -mindepth 1 -maxdepth 1 ! -name 'writable' ! -name 'vendor' ! -name '.env' -exec rm -rf {} +
sudo tar -xzf "$STAGE_DIR/domains-app.tar.gz" -C "$APP_DIR"
sudo install -d -o webapps -g webapps -m 0775 "$APP_DIR/writable"/{cache,logs,session,uploads,debugbar}

if [ -n "$KEEP_ENV" ] && [ -f "$KEEP_ENV" ]; then
  sudo install -o webapps -g webapps -m 0600 "$KEEP_ENV" "$ENV_FILE"
  rm -f "$KEEP_ENV"
else
  sudo tee "$ENV_FILE" >/dev/null <<EOF
CI_ENVIRONMENT = production

app.baseURL = 'https://domains.rajesh.in/'
app.forceGlobalSecureRequests = true
app.indexPage = ''

encryption.key = '${ENC_KEY}'

database.default.hostname = 127.0.0.1
database.default.database = ${DB_NAME}
database.default.username = ${DB_USER}
database.default.password = '${DB_PASS}'
database.default.DBDriver = Postgre
database.default.DBPrefix =
database.default.port = 5432
database.default.schema = public

api.key = '${API_KEY}'

zeptomail.token = ''
zeptomail.from = 'noreply@rajesh.app'
zeptomail.alertTo = 'rajesh.yukta@gmail.com'
EOF
  sudo chown webapps:webapps "$ENV_FILE"
  sudo chmod 0600 "$ENV_FILE"
fi

sudo chown -R webapps:caddy "$APP_DIR"
sudo find "$APP_DIR" -type d -exec chmod 0755 {} +
sudo find "$APP_DIR" -type f -exec chmod 0644 {} +
sudo chown -R webapps:webapps "$APP_DIR/writable"
sudo chmod -R 0775 "$APP_DIR/writable"
sudo chown webapps:webapps "$ENV_FILE"
sudo chmod 0600 "$ENV_FILE"

# Install Composer vendor deps cleanly as webapps user
(cd "$APP_DIR" && sudo -u webapps COMPOSER_HOME=/tmp/.composer-webapps composer install --no-dev --optimize-autoloader --no-interaction)
sudo chown -R webapps:caddy "$APP_DIR/vendor"
sudo find "$APP_DIR/vendor" -type d -exec chmod 0755 {} +
sudo find "$APP_DIR/vendor" -type f -exec chmod 0644 {} +

echo "=== [5/8] Lint PHP & run spark migrate (delta check) ==="
sudo find "$APP_DIR/app" "$APP_DIR/public" -type f -name '*.php' -print0 | xargs -0 -n1 php -l >/dev/null
(cd "$APP_DIR" && sudo -u webapps php spark migrate --all)
(cd "$APP_DIR" && sudo -u webapps php spark migrate:status)

echo "  Database row counts after restore & migrate:"
(cd /tmp && sudo -u postgres psql -d "${DB_NAME}" -P pager=off -c "
  SELECT 'users' AS tbl, count(*) FROM users
  UNION ALL SELECT 'domains', count(*) FROM domains
  UNION ALL SELECT 'domain_monitors', count(*) FROM domain_monitors
  UNION ALL SELECT 'whois_history', count(*) FROM whois_history
  UNION ALL SELECT 'whois_servers', count(*) FROM whois_servers
  UNION ALL SELECT 'rdap_registry', count(*) FROM rdap_registry
  UNION ALL SELECT 'rdap_domains', count(*) FROM rdap_domains
  UNION ALL SELECT 'contacts', count(*) FROM contacts
  ORDER BY 1;
")

echo "=== [6/8] PHP 8.4-FPM pool (pm = ondemand) & monitoring timers ==="
sudo tee /etc/php/8.4/fpm/pool.d/app-domains.rajesh.app.conf >/dev/null <<'EOF'
; Managed: domains-rajesh-app PHP 8.4-FPM pool (Web-1)
[app-domains.rajesh.app]
user = webapps
group = webapps
listen = /run/php/app-domains.rajesh.app.sock
listen.owner = webapps
listen.group = caddy
listen.mode = 0660

pm = ondemand
pm.max_children = 6
pm.process_idle_timeout = 15s
pm.max_requests = 500
request_terminate_timeout = 45s

clear_env = yes
security.limit_extensions = .php
env[CI_ENVIRONMENT] = production

php_admin_value[memory_limit] = 192M
php_admin_value[max_execution_time] = 30
php_admin_flag[file_uploads] = off
php_admin_value[error_log] = /var/log/php-fpm/domains.rajesh.app.log
php_admin_flag[log_errors] = on
php_admin_flag[display_errors] = off
php_admin_value[open_basedir] = /srv/phpapps/domains.rajesh.app:/tmp:/usr/share/php:/etc/ssl/certs:/usr/share/ca-certificates
php_admin_value[session.save_path] = /srv/phpapps/domains.rajesh.app/writable/session
php_admin_value[expose_php] = 0
EOF

sudo php-fpm8.4 -t
sudo systemctl reload php8.4-fpm

sudo tee /etc/systemd/system/domains-rajesh-check.service >/dev/null <<'EOF'
[Unit]
Description=domains-rajesh-app due domain monitor checks
After=network-online.target postgresql.service
[Service]
Type=oneshot
User=webapps
Group=webapps
WorkingDirectory=/srv/phpapps/domains.rajesh.app
ExecStart=/usr/bin/php /srv/phpapps/domains.rajesh.app/spark domains:check --limit 200
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
EOF

sudo tee /etc/systemd/system/domains-rajesh-check.timer >/dev/null <<'EOF'
[Unit]
Description=Hourly domain monitor check (domains-rajesh-app)
[Timer]
OnBootSec=5min
OnUnitActiveSec=1h
Persistent=true
[Install]
WantedBy=timers.target
EOF

sudo tee /etc/systemd/system/domains-rajesh-digest.service >/dev/null <<'EOF'
[Unit]
Description=domains-rajesh-app owned domain expiry digest
After=network-online.target postgresql.service
[Service]
Type=oneshot
User=webapps
Group=webapps
WorkingDirectory=/srv/phpapps/domains.rajesh.app
ExecStart=/usr/bin/php /srv/phpapps/domains.rajesh.app/spark domains:expiry-digest
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
EOF

sudo tee /etc/systemd/system/domains-rajesh-digest.timer >/dev/null <<'EOF'
[Unit]
Description=Daily owned domain expiry digest (domains-rajesh-app)
[Timer]
OnCalendar=*-*-* 08:00:00
Persistent=true
[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now domains-rajesh-check.timer domains-rajesh-digest.timer

echo "=== [7/8] Self-signed SAN TLS cert for domains.rajesh.in & Caddy reload ==="
sudo install -d -o root -g caddy -m 0750 /etc/caddy/certs
if ! sudo test -f /etc/caddy/certs/domains.rajesh.in.crt || ! sudo test -f /etc/caddy/certs/domains.rajesh.in.key; then
  sudo openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
    -subj "/CN=domains.rajesh.in/O=NextDP/" \
    -addext "subjectAltName=DNS:domains.rajesh.in,DNS:www.domains.rajesh.in" \
    -addext "basicConstraints=critical,CA:FALSE" \
    -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
    -addext "extendedKeyUsage=serverAuth" \
    -keyout /etc/caddy/certs/domains.rajesh.in.key \
    -out /etc/caddy/certs/domains.rajesh.in.crt
fi
sudo chown root:caddy /etc/caddy/certs/domains.rajesh.in.crt /etc/caddy/certs/domains.rajesh.in.key
sudo chmod 0644 /etc/caddy/certs/domains.rajesh.in.crt
sudo chmod 0640 /etc/caddy/certs/domains.rajesh.in.key

sudo install -o root -g root -m 0644 "$CADDY_SRC" /etc/caddy/sites-enabled/domains.rajesh.app.caddy
for logfile in /var/log/caddy/domains.rajesh.in.log /var/log/caddy/domains.rajesh1.com.log; do
  if ! sudo test -e "$logfile"; then
    sudo install -o caddy -g caddy -m 0640 /dev/null "$logfile"
  else
    sudo chown caddy:caddy "$logfile"
    sudo chmod 0640 "$logfile"
  fi
done

sudo -u caddy caddy adapt --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null
sudo systemctl reload caddy
sleep 1

echo "=== [8/8] Verify TLS, Caddy routing & API filter ==="
echo "  Self-signed cert summary:"
sudo openssl x509 -in /etc/caddy/certs/domains.rajesh.in.crt -noout -subject -issuer -dates -ext subjectAltName

echo "  TLS handshake check (domains.rajesh.in self-signed):"
echo | openssl s_client -connect 127.0.0.1:443 -servername domains.rajesh.in 2>/dev/null | openssl x509 -noout -subject -issuer

IN_CODE=$(curl -sk --resolve domains.rajesh.in:443:127.0.0.1 -o /dev/null -w '%{http_code}' https://domains.rajesh.in/login)
echo "  https://domains.rajesh.in/login (self-signed HTTPS) -> HTTP ${IN_CODE}"
[ "$IN_CODE" = "200" ] || { echo "FATAL: expected 200 on https://domains.rajesh.in/login" >&2; exit 1; }

UNAUTH_API=$(curl -sk --resolve domains.rajesh.in:443:127.0.0.1 -o /dev/null -w '%{http_code}' 'https://domains.rajesh.in/api/v1/nameservers/validate?nameservers=ns1.nextdp.com,ns2.nextdp.com')
AUTH_RESP=$(curl -sk --resolve domains.rajesh.in:443:127.0.0.1 -H "X-API-Key: ${API_KEY}" -w '\n%{http_code}' 'https://domains.rajesh.in/api/v1/nameservers/validate?nameservers=ns1.nextdp.com,ns2.nextdp.com')
AUTH_API=$(printf '%s' "$AUTH_RESP" | tail -n1)
echo "  /api/v1/nameservers/validate -> unauth HTTP ${UNAUTH_API}, X-API-Key HTTP ${AUTH_API}"
[ "$UNAUTH_API" = "401" ] && [ "$AUTH_API" = "200" ] || { echo "FATAL: unexpected API check status" >&2; exit 1; }
printf '%s\n' "$AUTH_RESP" | head -n -1 | jq -c '{status, nameservers: [.results[] | {host: (.nameserver // .host), valid: .valid}]}' 2>/dev/null || true

COM_REDIRECT=$(curl -s --resolve domains.rajesh1.com:80:127.0.0.1 -o /dev/null -w '%{http_code}' http://domains.rajesh1.com/)
echo "  http://domains.rajesh1.com/ (auto-HTTPS redirect) -> HTTP ${COM_REDIRECT}"
[ "$COM_REDIRECT" = "308" ] || { echo "FATAL: expected 308 on http://domains.rajesh1.com/" >&2; exit 1; }

# FastCGI check as caddy user for domains.rajesh1.com (without waiting for DNS cutover for LE cert)
sudo -u caddy python3 - <<'PY'
import socket, struct, re
def rec(rt, req_id, payload=b""):
    pad = (-len(payload)) & 7
    return struct.pack("!BBHHBx", 1, rt, req_id, len(payload), pad) + payload + (b"\x00" * pad)
def kv(k, v):
    kb, vb = k.encode(), v.encode()
    out = bytearray()
    for b in (kb, vb):
        n = len(b)
        out += bytes([n]) if n < 128 else struct.pack("!I", n | 0x80000000)
    return bytes(out) + kb + vb
params = b"".join(kv(k, v) for k, v in {
    "REQUEST_METHOD": "GET",
    "SCRIPT_FILENAME": "/srv/phpapps/domains.rajesh.app/public/index.php",
    "SCRIPT_NAME": "/index.php",
    "REQUEST_URI": "/login",
    "DOCUMENT_ROOT": "/srv/phpapps/domains.rajesh.app/public",
    "SERVER_NAME": "domains.rajesh1.com",
    "SERVER_PORT": "443",
    "HTTPS": "on",
    "HTTP_HOST": "domains.rajesh1.com",
}.items())
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(5)
s.connect("/run/php/app-domains.rajesh.app.sock")
s.sendall(rec(1, 1, struct.pack("!HB5x", 1, 0)) + rec(4, 1, params) + rec(4, 1, b"") + rec(5, 1, b""))
out, buf = bytearray(), bytearray()
while True:
    c = s.recv(8192)
    if not c: break
    buf.extend(c)
    while len(buf) >= 8:
        _, rt, _, clen, plen = struct.unpack("!BBHHBx", buf[:8])
        need = 8 + clen + plen
        if len(buf) < need: break
        if rt == 6: out.extend(buf[8:8+clen])
        del buf[:need]
s.close()
text = out.decode("utf-8", "replace")
head, _, body = text.partition("\r\n\r\n")
m = re.search(r"(?is)<title>(.*?)</title>", body)
print("  FastCGI domains.rajesh1.com/login -> title:", (m.group(1).strip() if m else "NONE"), f"({len(body)}B)")
assert "Sign in" in body or "Sign" in (m.group(1) if m else ""), "Unexpected login body for domains.rajesh1.com"
PY

# Prepare clean credential file for download without printing raw values
cat <<EOF > "$OUTPUT_ENV"
# domains-rajesh-app credentials on Web-1 (3.6.143.66) — NEVER commit
APP_URL_SELF_SIGNED=https://domains.rajesh.in/
APP_URL_AUTO_SSL=https://domains.rajesh1.com/
DB_HOST=127.0.0.1
DB_PORT=5432
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASS=${DB_PASS}
ENCRYPTION_KEY=${ENC_KEY}
API_KEY=${API_KEY}
EOF
chmod 0600 "$OUTPUT_ENV"

systemctl is-active postgresql php8.4-fpm caddy domains-rajesh-check.timer domains-rajesh-digest.timer
