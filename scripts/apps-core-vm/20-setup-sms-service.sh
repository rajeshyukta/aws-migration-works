#!/usr/bin/env bash
# Runs on Apps-Core-VM. Sets up the SMS service (r1sms, repo projects/platform/sms-service) the way it ran
# on Azure nmc-apps-1 (sms-service scripts/provision-vm.sh + deploy-backend.ps1 + deploy-console.ps1),
# adapted to this VM: local PostgreSQL 16 (no TLS on loopback), shared Caddy via sites-enabled, port 8084.
#   1. user r1sms, /opt/r1sms/{releases,bin,storage,console}
#   2. PostgreSQL role + database r1sms; restore the R2 dump ONCE (an existing non-empty DB is kept)
#   3. /etc/r1sms/backend.env (created once; NEW APP_KEY / JWT_SECRET; mail = Next iDP's ZeptoMail key)
#   4. three systemd units (serve, schedule:run, work)
#   5. backend release: migrate, seed (idempotent), restart, health on :8084, roll back the symlink on failure
#   6. console release (SPA) + symlink
#   7. Caddy site /etc/caddy/sites-enabled/r1sms.caddy (validated; removed again if Caddy refuses it)
# MODE=check | apply. STAGE holds r1sms.dump, r1sms-backend, console.tgz, RELEASE (apply only).
set -Eeuo pipefail
exec 2>&1
MODE="${MODE:-check}"; STAGE="${STAGE:-}"
APP=r1sms; BIN=r1sms-backend; PORT=8084; DOMAIN=smsservice.rajesh1.com
ENV_FILE=/etc/$APP/backend.env; SITE=/etc/caddy/sites-enabled/$APP.caddy
[[ "$MODE" =~ ^(check|apply)$ ]] || { echo "FATAL: MODE must be check or apply"; exit 1; }
trap '[ -n "$STAGE" ] && sudo rm -rf "$STAGE"' EXIT

db_tables() { sudo -u postgres psql -d "$APP" -At -c "select count(*) from information_schema.tables where table_schema='public'" 2>/dev/null || echo 0; }
echo "== state"
echo "  port $PORT: $(ss -ltn "( sport = :$PORT )" | tail -n +2 | grep -q . && echo in-use || echo free)"
echo "  user $APP: $(id -u $APP >/dev/null 2>&1 && echo exists || echo missing)"
echo "  role/db: role=$(sudo -u postgres psql -At -c "select 1 from pg_roles where rolname='$APP'" | grep -q 1 && echo yes || echo no) db=$(sudo -u postgres psql -At -c "select 1 from pg_database where datname='$APP'" | grep -q 1 && echo yes || echo no) tables=$(db_tables)"
echo "  env file: $(sudo test -f $ENV_FILE && echo present || echo missing)"
echo "  units: $(systemctl list-unit-files "$BIN*.service" --no-legend 2>/dev/null | awk '{print $1}' | paste -sd' ')"
echo "  caddy site: $(sudo test -f $SITE && echo present || echo missing)"
echo "  release: $(readlink -f /opt/$APP/bin/$BIN 2>/dev/null || echo none)"
echo "  dns $DOMAIN: $(getent ahostsv4 $DOMAIN | awk '{print $1}' | sort -u | paste -sd' ')"
[ "$MODE" = "apply" ] || { echo "CHECK DONE (nothing written)"; exit 0; }

for f in r1sms.dump r1sms-backend console.tgz RELEASE; do sudo test -s "$STAGE/$f" || { echo "FATAL: $STAGE/$f missing"; exit 1; }; done
REL=$(sudo cat "$STAGE/RELEASE")
[[ "$REL" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "FATAL: bad release name"; exit 1; }

echo "== 1. user + layout"
id -u $APP >/dev/null 2>&1 || sudo useradd --system --home /opt/$APP --shell /usr/sbin/nologin $APP
sudo mkdir -p /opt/$APP/releases /opt/$APP/bin /opt/$APP/storage/logs /opt/$APP/storage/uploads /opt/$APP/console/releases /etc/$APP
sudo chown -R $APP:$APP /opt/$APP

echo "== 2. database"
NEW_DB_PASS=""
if ! sudo -u postgres psql -At -c "select 1 from pg_roles where rolname='$APP'" | grep -q 1; then
  NEW_DB_PASS=$(openssl rand -hex 24)
  printf "create role %s login password '%s';\n" "$APP" "$NEW_DB_PASS" | sudo -u postgres psql -q
  echo "  role $APP created"
fi
if ! sudo -u postgres psql -At -c "select 1 from pg_database where datname='$APP'" | grep -q 1; then
  sudo -u postgres createdb -O $APP $APP
  echo "  database $APP created"
fi
if [ "$(db_tables)" = "0" ]; then
  sudo install -o postgres -g postgres -m 0600 "$STAGE/r1sms.dump" /tmp/.r1sms-restore.dump
  set +e
  sudo -u postgres pg_restore --no-owner --no-acl --role=$APP -d $APP /tmp/.r1sms-restore.dump > /tmp/.r1sms-restore.log 2>&1
  rc=$?
  set -e
  sudo rm -f /tmp/.r1sms-restore.dump
  echo "  pg_restore rc=$rc, error lines=$(grep -c 'error:' /tmp/.r1sms-restore.log || true)"
  grep 'error:' /tmp/.r1sms-restore.log | head -5 || true
  rm -f /tmp/.r1sms-restore.log
  [ "$rc" = "0" ] || { echo "FATAL: restore failed"; exit 1; }
else
  echo "  database already has tables: kept (no restore)"
fi
sudo -u postgres psql -d $APP -At -F ' ' -c "select 'rows:', (select count(*) from devices) devices, (select count(*) from idps) idps, (select count(*) from users) users, (select count(*) from sms_messages) sms"

echo "== 3. env file"
if ! sudo test -f $ENV_FILE; then
  [ -n "$NEW_DB_PASS" ] || { echo "FATAL: role $APP exists but $ENV_FILE is missing (password unknown)"; exit 1; }
  ZKEY=$(sudo sed -n 's/^MAIL_API_KEY=//p' /etc/nextidp/env | tail -1)
  ZURL=$(sudo sed -n 's/^MAIL_API_BASE_URL=//p' /etc/nextidp/env | tail -1)
  [ -n "$ZKEY" ] || { echo "FATAL: no MAIL_API_KEY in /etc/nextidp/env"; exit 1; }
  sudo install -o root -g $APP -m 0640 /dev/null $ENV_FILE
  sudo tee $ENV_FILE >/dev/null <<EOF
APP_NAME=R1SMS
APP_ENV=production
APP_DEBUG=false
APP_PORT=$PORT
APP_URL=https://$DOMAIN
APP_KEY=base64:$(openssl rand -base64 32)
RAPIDGO_MODE=api,ws
TRUSTED_PROXIES=127.0.0.1
DB_DRIVER=postgres
DB_HOST=127.0.0.1
DB_PORT=5432
DB_NAME=$APP
DB_USER=$APP
DB_PASSWORD=$NEW_DB_PASS
DB_SSL_MODE=disable
SESSION_DRIVER=cookie
CACHE_DRIVER=memory
QUEUE_DRIVER=database
JWT_SECRET=$(openssl rand -hex 32)
JWT_EXPIRY=3600
LOG_LEVEL=info
LOG_FORMAT=json
LOG_OUTPUT=stdout
MAIL_API_PROVIDER=zeptomail
ZEPTOMAIL_API_KEY=$ZKEY
ZEPTOMAIL_BASE_URL=$ZURL
MAIL_FROM_ADDRESS=noreply@nextidp.com
MAIL_FROM_NAME=R1 SMS
EOF
  echo "  $ENV_FILE created (new APP_KEY, JWT_SECRET, DB password; ZeptoMail from Next iDP)"
else
  echo "  $ENV_FILE kept"
fi

echo "== 4. systemd units"
unit() { # name description command
  sudo tee /etc/systemd/system/$1.service >/dev/null <<EOF
[Unit]
Description=$2
After=network-online.target postgresql.service
Wants=network-online.target

[Service]
User=$APP
Group=$APP
WorkingDirectory=/opt/$APP
EnvironmentFile=$ENV_FILE
ExecStart=/opt/$APP/bin/$BIN $3
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=/opt/$APP/storage
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF
}
unit $BIN "R1 SMS backend (RapidGo)" "serve"
unit $BIN-scheduler "R1 SMS scheduler (RapidGo cron)" "schedule:run"
unit $BIN-worker "R1 SMS queue worker (RapidGo)" "work --queues=webhooks,inbound,default --workers=2"
sudo systemctl daemon-reload

echo "== 5. backend release $REL"
PREV=$(readlink -f /opt/$APP/bin/$BIN 2>/dev/null || true)
sudo install -o $APP -g $APP -m 0755 "$STAGE/r1sms-backend" /opt/$APP/releases/$REL
sudo ln -sfn /opt/$APP/releases/$REL /opt/$APP/bin/$BIN
sudo chown -h $APP:$APP /opt/$APP/bin/$BIN
sudo -u $APP bash -c "set -a; . $ENV_FILE; set +a; cd /opt/$APP && /opt/$APP/bin/$BIN migrate" 2>&1 | tail -2
sudo -u $APP bash -c "set -a; . $ENV_FILE; set +a; cd /opt/$APP && /opt/$APP/bin/$BIN db:seed" 2>&1 | grep -E 'Seeder|seeded|skipped' | tail -5 || true
sudo systemctl enable -q $BIN $BIN-scheduler $BIN-worker
sudo systemctl restart $BIN $BIN-scheduler $BIN-worker
ok=""
for i in $(seq 1 30); do curl -fsS -m 3 http://127.0.0.1:$PORT/health >/dev/null 2>&1 && { ok=1; break; }; sleep 1; done
if [ -z "$ok" ]; then
  echo "!! health failed"; sudo journalctl -u $BIN -n 30 --no-pager || true
  if [ -n "$PREV" ] && [ -f "$PREV" ]; then sudo ln -sfn "$PREV" /opt/$APP/bin/$BIN; sudo systemctl restart $BIN $BIN-scheduler $BIN-worker; echo "rolled back to $PREV"; fi
  exit 1
fi
echo "  healthy: $(curl -fsS -m 3 http://127.0.0.1:$PORT/health | head -c 200); units: $(systemctl is-active $BIN $BIN-scheduler $BIN-worker | paste -sd' ')"
cd /opt/$APP/releases && ls -t | tail -n +6 | xargs -r sudo rm -f --

echo "== 6. console release"
CREL=/opt/$APP/console/releases/console-$REL
sudo mkdir -p "$CREL"
sudo tar -xzf "$STAGE/console.tgz" -C "$CREL"
sudo chown -R $APP:$APP "$CREL"; sudo chmod -R o+rX "$CREL"
sudo ln -sfn "$CREL" /opt/$APP/console/current
sudo chown -h $APP:$APP /opt/$APP/console/current
sudo chmod o+x /opt /opt/$APP /opt/$APP/console
echo "  console: $CREL"

echo "== 7. caddy site"
if ! sudo test -f $SITE; then
  sudo tee $SITE >/dev/null <<EOF
# SMS service (r1sms), added by aws-setup-and-migrations scripts/apps-core-vm/20-setup-sms-service
$DOMAIN {
	encode gzip

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "DENY"
		Referrer-Policy "no-referrer"
		Content-Security-Policy "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'self'; frame-ancestors 'none'; form-action 'self'"
	}

	@backend path /api/* /ws/* /health /openapi.json /docs /docs/*
	handle @backend {
		reverse_proxy 127.0.0.1:$PORT
	}

	handle {
		root * /opt/$APP/console/current
		try_files {path} /index.html
		file_server
	}
}
EOF
  if sudo caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/tmp/.caddy-validate.log 2>&1 && sudo systemctl reload caddy; then
    echo "  site added, caddy reloaded ($(systemctl is-active caddy))"
  else
    tail -5 /tmp/.caddy-validate.log; sudo rm -f $SITE; sudo systemctl reload caddy || true
    echo "FATAL: caddy refused the site (removed again)"; exit 1
  fi
  rm -f /tmp/.caddy-validate.log
else
  echo "  site kept"
fi
echo "== checks through Caddy (Host header, plain http -> expect redirect or 200)"
echo "  /health via 8084: $(curl -s -o /dev/null -w '%{http_code}' -m 5 http://127.0.0.1:$PORT/health)"
echo "  console index: $(sudo test -f /opt/$APP/console/current/index.html && echo present || echo MISSING)"
echo "APPLY DONE"
