#!/usr/bin/env bash
# Fresh install of CConsole Hub (reseller-mw) on Web-1 (3.6.143.66). Idempotent; re-run to redeploy code.
#   PHASE=app   : Redis (localhost, password) + php8.4-redis/bcmath, PG role+DB cconsole_hub, app code,
#                 .env with NEW secrets (first run only), composer, migrations, seeder, FPM pool, cron,
#                 FastCGI smoke test. No Caddy site yet (no public change).
#   PHASE=sites : after DNS for the 5 hub hosts points to this VM: install the Caddy site, reload,
#                 wait for Let's Encrypt certificates, check every host over HTTPS.
# Never prints secret values.
set -Eeuo pipefail
exec 2>&1
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1

PHASE="${PHASE:?PHASE=app|sites}"
STAGE_DIR="${STAGE_DIR:-}"
APP_DIR=/srv/phpapps/cconsole-hub
CI4_DIR=$APP_DIR/ci4-app
ENV_FILE=$CI4_DIR/.env
POOL=/etc/php/8.4/fpm/pool.d/app-cconsole-hub.conf
SOCK=/run/php/app-cconsole-hub.sock
SITE=/etc/caddy/sites-enabled/cconsole-hub.caddy
PUBLIC_IP="3.6.143.66"
HOSTS="api.hub.cconsole.com sandbox.hub.cconsole.com hub.cconsole.com admin.hub.cconsole.com docs.hub.cconsole.com"
cd /tmp

fcgi_get() {  # $1=host $2=uri -> prints "STATUS|bytes|stderr"
  sudo -u caddy SOCK="$SOCK" H="$1" U="$2" ROOT="$CI4_DIR/public" python3 - <<'PY'
import os, re, socket, struct
def rec(t, rid, p=b""):
    pad = (-len(p)) & 7
    return struct.pack("!BBHHBx", 1, t, rid, len(p), pad) + p + b"\0" * pad
def kv(k, v):
    o = bytearray()
    for b in (k.encode(), v.encode()):
        o += bytes([len(b)]) if len(b) < 128 else struct.pack("!I", len(b) | 0x80000000)
    return bytes(o) + k.encode() + v.encode()
h, u, root = os.environ["H"], os.environ["U"], os.environ["ROOT"]
p = b"".join(kv(k, v) for k, v in {"REQUEST_METHOD": "GET", "SCRIPT_FILENAME": root + "/index.php", "SCRIPT_NAME": "/index.php",
    "REQUEST_URI": u, "PATH_INFO": u, "DOCUMENT_ROOT": root, "SERVER_NAME": h, "SERVER_PORT": "443", "HTTPS": "on",
    "HTTP_HOST": h, "HTTP_ACCEPT": "application/json", "REMOTE_ADDR": "127.0.0.1", "SERVER_PROTOCOL": "HTTP/1.1"}.items())
s = socket.socket(socket.AF_UNIX); s.settimeout(15); s.connect(os.environ["SOCK"])
s.sendall(rec(1, 1, struct.pack("!HB5x", 1, 0)) + rec(4, 1, p) + rec(4, 1) + rec(5, 1))
out, err, buf = bytearray(), bytearray(), bytearray()
while True:
    c = s.recv(65536)
    if not c: break
    buf += c
    while len(buf) >= 8:
        _, t, _, cl, pl = struct.unpack("!BBHHBx", buf[:8])
        if len(buf) < 8 + cl + pl: break
        d = bytes(buf[8:8 + cl]); del buf[:8 + cl + pl]
        (out if t == 6 else err if t == 7 else bytearray()).extend(d)
head, _, body = out.decode("utf-8", "replace").partition("\r\n\r\n")
m = re.search(r"(?im)^Status:\s*(\d+)", head)
print(f"{m.group(1) if m else '200'}|{len(body)}|{err.decode('utf-8','replace').strip()[:120]}")
PY
}

case "$PHASE" in
app)
  [ -s "$STAGE_DIR/reseller-mw.tar.gz" ] || { echo "FATAL: staged tarball missing" >&2; exit 1; }

  echo "=== [1/8] packages: redis-server, php8.4-redis, php8.4-bcmath ==="
  need=""
  for p in redis-server php8.4-redis php8.4-bcmath; do dpkg -s "$p" >/dev/null 2>&1 || need="$need $p"; done
  if [ -n "$need" ]; then
    sudo apt-get update -qq
    sudo apt-get install -y -qq --no-install-recommends $need >/dev/null
    echo "  installed:$need"
  else
    echo "  already installed"
  fi
  REDIS_PASS_FILE=/root/.web1-redis-pass
  if ! sudo test -s "$REDIS_PASS_FILE"; then
    openssl rand -hex 24 | sudo tee "$REDIS_PASS_FILE" >/dev/null; sudo chmod 600 "$REDIS_PASS_FILE"
  fi
  sudo tee /etc/redis/web1-override.conf >/dev/null <<EOF
# Managed by aws-setup-and-migrations/scripts/web-1-vm/06-deploy-cconsole-hub.sh
bind 127.0.0.1 -::1
protected-mode yes
port 6379
requirepass $(sudo cat "$REDIS_PASS_FILE")
maxmemory 64mb
maxmemory-policy allkeys-lru
EOF
  sudo chown redis:redis /etc/redis/web1-override.conf; sudo chmod 640 /etc/redis/web1-override.conf
  sudo grep -q '^include /etc/redis/web1-override.conf' /etc/redis/redis.conf || echo 'include /etc/redis/web1-override.conf' | sudo tee -a /etc/redis/redis.conf >/dev/null
  sudo systemctl enable -q redis-server; sudo systemctl restart redis-server
  REDISCLI_AUTH="$(sudo cat "$REDIS_PASS_FILE")" redis-cli PING | grep -q PONG && echo "  redis: PONG (localhost only, password set)"

  echo "=== [2/8] PostgreSQL role + database cconsole_hub ==="
  DB_PASS_FILE=/root/.cconsole-hub-db-pass
  if ! sudo test -s "$DB_PASS_FILE"; then
    openssl rand -hex 24 | sudo tee "$DB_PASS_FILE" >/dev/null; sudo chmod 600 "$DB_PASS_FILE"
  fi
  DB_PASS="$(sudo cat "$DB_PASS_FILE")"
  if sudo -u postgres psql -XAtc "SELECT 1 FROM pg_roles WHERE rolname='cconsole_hub'" | grep -q 1; then
    sudo -u postgres psql -Xq -c "ALTER ROLE cconsole_hub LOGIN PASSWORD '${DB_PASS}';"
  else
    sudo -u postgres psql -Xq -c "CREATE ROLE cconsole_hub LOGIN PASSWORD '${DB_PASS}';"
  fi
  sudo -u postgres psql -XAtc "SELECT 1 FROM pg_database WHERE datname='cconsole_hub'" | grep -q 1 \
    || sudo -u postgres createdb -O cconsole_hub -E UTF8 cconsole_hub
  sudo -u postgres psql -Xq -d cconsole_hub -c "ALTER DATABASE cconsole_hub OWNER TO cconsole_hub; ALTER SCHEMA public OWNER TO cconsole_hub; GRANT ALL ON SCHEMA public TO cconsole_hub;"
  echo "  role + db ready"

  echo "=== [3/8] app code -> $APP_DIR ==="
  sudo mkdir -p "$APP_DIR"
  sudo rm -rf "$APP_DIR/frontend/admin/dist" "$APP_DIR/frontend/tenant/dist"
  sudo tar -xzf "$STAGE_DIR/reseller-mw.tar.gz" -C "$APP_DIR"
  sudo mkdir -p "$CI4_DIR/writable"/{cache,logs,session,uploads,keys,debugbar}
  sudo chown -R webapps:caddy "$APP_DIR"
  sudo chmod -R u=rwX,g=rX,o= "$APP_DIR"
  sudo test -f "$ENV_FILE" && { sudo chown webapps:webapps "$ENV_FILE"; sudo chmod 0600 "$ENV_FILE"; }
  sudo chmod -R ug+rwX "$CI4_DIR/writable"
  sudo chmod 0755 "$APP_DIR"
  echo "  $(sudo du -sh "$APP_DIR" | cut -f1)"

  echo "=== [4/8] .env ==="
  if sudo test -f "$ENV_FILE"; then
    echo "  exists, kept (secrets unchanged)"
  else
    JWT_SECRET=$(openssl rand -hex 32); ENC_KEY="hex2bin:$(openssl rand -hex 32)"; REDIS_PW="$(sudo cat "$REDIS_PASS_FILE")"
    sudo tee "$ENV_FILE" >/dev/null <<EOF
CI_ENVIRONMENT = production

app.baseURL = 'https://api.hub.cconsole.com/'
app.forceGlobalSecureRequests = true
encryption.key = '${ENC_KEY}'

database.default.hostname = 127.0.0.1
database.default.database = cconsole_hub
database.default.username = cconsole_hub
database.default.password = '${DB_PASS}'
database.default.DBDriver = Postgre
database.default.port = 5432
database.default.charset = utf8

REDIS_HOST = 127.0.0.1
REDIS_PORT = 6379
REDIS_PASSWORD = '${REDIS_PW}'
REDIS_DATABASE = 0
cache.prefix = 'cchub_'

CORS_ALLOWED_ORIGINS = 'https://hub.cconsole.com,https://admin.hub.cconsole.com'

JWT_SECRET = '${JWT_SECRET}'

ZEPTO_MAIL_API_KEY = __SET_ON_SERVER__
ZEPTO_MAIL_FROM_EMAIL = noreply@cconsole.com
ZEPTO_MAIL_FROM_NAME = 'CConsole Hub'

RESELLERCLUB_AUTH_USERID = __SET_ON_SERVER__
RESELLERCLUB_API_KEY = __SET_ON_SERVER__
RESELLERCLUB_CUSTOMER_ID = __SET_ON_SERVER__
RESELLERCLUB_SANDBOX = true
RESELLERCLUB_API_URL = https://httpapi.com/api/
RESELLERCLUB_SANDBOX_URL = https://test.httpapi.com/api/
RESELLERCLUB_DOMAINCHECK_URL = https://domaincheck.httpapi.com/api/

APP_URL = https://api.hub.cconsole.com
ADMIN_URL = https://admin.hub.cconsole.com
TENANT_URL = https://hub.cconsole.com
EOF
    unset JWT_SECRET ENC_KEY REDIS_PW
    echo "  created with new secrets (ZeptoMail/ResellerClub left as __SET_ON_SERVER__)"
  fi
  sudo chown webapps:webapps "$ENV_FILE"; sudo chmod 0600 "$ENV_FILE"
  unset DB_PASS

  echo "=== [5/8] composer install, migrations, seeder ==="
  sudo -u webapps bash -c "cd '$CI4_DIR' && COMPOSER_HOME=/tmp/.composer-webapps composer install --no-dev --optimize-autoloader --no-interaction --quiet"
  sudo -u webapps bash -c "cd '$CI4_DIR' && php spark migrate --all" | tail -3
  sudo -u webapps bash -c "cd '$CI4_DIR' && php spark db:seed PlatformSettingsSeeder" | tail -2
  sudo chown -R webapps:caddy "$CI4_DIR/vendor" "$CI4_DIR/writable"
  echo "  tables: $(sudo -u postgres psql -XAt -d cconsole_hub -c "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'")"

  echo "=== [6/8] PHP-FPM pool app-cconsole-hub ==="
  sudo tee "$POOL" >/dev/null <<'EOF'
; Managed by aws-setup-and-migrations/scripts/web-1-vm/06-deploy-cconsole-hub.sh
[app-cconsole-hub]
user = webapps
group = webapps
listen = /run/php/app-cconsole-hub.sock
listen.owner = webapps
listen.group = caddy
listen.mode = 0660

pm = ondemand
pm.max_children = 5
pm.process_idle_timeout = 10s
pm.max_requests = 500

env[CI_ENVIRONMENT] = production
php_admin_value[open_basedir] = /srv/phpapps/cconsole-hub:/tmp:/usr/share/php:/etc/ssl/certs:/usr/share/ca-certificates
php_admin_value[session.save_path] = /srv/phpapps/cconsole-hub/ci4-app/writable/session
php_admin_value[memory_limit] = 128M
php_admin_value[upload_max_filesize] = 10M
php_admin_value[post_max_size] = 12M
EOF
  sudo php-fpm8.4 -t 2>&1 | tail -1
  sudo systemctl reload php8.4-fpm
  for i in $(seq 1 10); do [ -S "$SOCK" ] && break; sleep 1; done
  [ -S "$SOCK" ] || { echo "FATAL: $SOCK not created" >&2; exit 1; }
  echo "  pool up ($SOCK)"

  echo "=== [7/8] cron (/etc/cron.d/cconsole-hub) ==="
  sudo tee /etc/cron.d/cconsole-hub >/dev/null <<'EOF'
# Managed by aws-setup-and-migrations/scripts/web-1-vm/06-deploy-cconsole-hub.sh (times UTC)
SHELL=/bin/bash
15 3 * * *   webapps cd /srv/phpapps/cconsole-hub/ci4-app && php spark api:logs-prune --days=90 >> writable/logs/prune.log 2>&1
0 */6 * * *  webapps cd /srv/phpapps/cconsole-hub/ci4-app && php spark domains:sync >> writable/logs/domains-sync.log 2>&1
0 4 * * *    webapps cd /srv/phpapps/cconsole-hub/ci4-app && php spark domains:renewals >> writable/logs/domains-renewals.log 2>&1
EOF
  sudo chmod 0644 /etc/cron.d/cconsole-hub
  echo "  installed"

  echo "=== [8/8] smoke test via FastCGI (no public change yet) ==="
  for h in api.hub.cconsole.com sandbox.hub.cconsole.com; do
    r=$(fcgi_get "$h" /); printf '  %-26s GET /  -> %s\n' "$h" "$r"
    case "${r%%|*}" in 2??|3??|401|404) ;; *) echo "FATAL: unexpected status from $h" >&2; exit 1 ;; esac
  done
  for d in tenant admin; do sudo test -s "$APP_DIR/frontend/$d/dist/index.html" && echo "  $d SPA: index.html present"; done
  sudo test -s "$CI4_DIR/public/docs/openapi.yaml" && echo "  docs: openapi.yaml present" || echo "  docs: openapi.yaml missing"
  systemctl is-active postgresql php8.4-fpm redis-server caddy | paste -sd' '
  free -m | awk 'NR==2{print "  RAM used "$3" / "$2" MiB"}'
  echo "APP_PHASE_OK - next: point DNS A records to ${PUBLIC_IP}, then run -Phase sites"
  ;;

sites)
  [ -s "$STAGE_DIR/cconsole-hub.caddy" ] || { echo "FATAL: staged Caddy site missing" >&2; exit 1; }
  [ -S "$SOCK" ] || { echo "FATAL: run PHASE=app first" >&2; exit 1; }
  echo "=== [1/3] DNS check (all must resolve to ${PUBLIC_IP} on ns1, ns2 and 1.1.1.1) ==="
  command -v dig >/dev/null || sudo apt-get install -y -qq bind9-dnsutils >/dev/null
  bad=0
  for h in $HOSTS; do
    a=$(dig +short A "$h" @52.66.165.1 | paste -sd,); b=$(dig +short A "$h" @52.66.25.51 | paste -sd,); c=$(dig +short A "$h" @1.1.1.1 | paste -sd,)
    printf '  %-26s ns1=%-15s ns2=%-15s 1.1.1.1=%s\n' "$h" "$a" "$b" "$c"
    [ "$a" = "$PUBLIC_IP" ] && [ "$b" = "$PUBLIC_IP" ] || bad=1
    [ "$c" = "$PUBLIC_IP" ] || echo "    note: 1.1.1.1 still cached (TTL 3600); Let's Encrypt asks the authoritative servers, so this is OK"
  done
  [ "$bad" = 0 ] || { echo "FATAL: ns1/ns2 do not point all hub hosts to ${PUBLIC_IP} yet" >&2; exit 1; }

  echo "=== [2/3] install Caddy site + reload ==="
  [ -f "$SITE" ] && sudo cp -p "$SITE" "$SITE.bak-$(date -u +%Y%m%dT%H%M%SZ)"
  sudo install -m 0644 -o root -g root "$STAGE_DIR/cconsole-hub.caddy" "$SITE"
  if ! sudo -u caddy caddy adapt --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null; then
    echo "FATAL: Caddy config invalid, removing site" >&2; sudo rm -f "$SITE"; exit 1
  fi
  sudo systemctl reload caddy
  echo "  reloaded"

  echo "=== [3/3] wait for certificates + HTTPS checks ==="
  for h in $HOSTS; do
    ok=0
    for i in $(seq 1 36); do
      if curl -sS -o /dev/null --max-time 8 --resolve "$h:443:127.0.0.1" "https://$h/" 2>/dev/null; then ok=1; break; fi
      sleep 5
    done
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 --resolve "$h:443:127.0.0.1" "https://$h/")
    issuer=$(echo | openssl s_client -connect 127.0.0.1:443 -servername "$h" 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null | sed 's/^issuer=//')
    printf '  %-26s tls=%-3s http=%s issuer=%s\n' "$h" "$([ $ok = 1 ] && echo ok || echo NO)" "$code" "${issuer:-none}"
  done
  echo "SITES_PHASE_DONE"
  ;;
*) echo "FATAL: unknown PHASE" >&2; exit 1 ;;
esac
