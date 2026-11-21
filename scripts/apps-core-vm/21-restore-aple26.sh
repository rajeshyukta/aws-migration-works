#!/usr/bin/env bash
# Runs on Apps-Core-VM as root. Prepares aple26 (AP 2026 Local Elections, repo projects/products/ap-2026-local-elections)
# with its OLD data before the app's own bootstrap + release scripts run (they never overwrite an existing .env or DB):
#   1. dumps of the other databases on this VM (nextidp, nextdp_core, r1sms) — nothing of theirs is touched, but they share it
#   2. user aple26 (as the app's bootstrap makes it), /srv/apps/aple26/{releases,shared}
#   3. the OLD shared/.env (APP_KEY decrypts the lead contacts; admin login, MCP tokens, AI / domain keys) root:aple26 0640
#   4. PG role aple26 with the .env's DB_PASSWORD, database aple26, pg_restore of the archived dump, row check
# MODE=check | apply. IN_DIR holds `.env` and `aple26.dump` (0600; deleted at the end). Prints no secret values.
set -Eeuo pipefail
exec 2>&1
MODE="${MODE:-check}"; IN_DIR="${IN_DIR:-}"
APP=aple26; BASE=/srv/apps/$APP; ENV_FILE=$BASE/shared/.env
[ "$(id -u)" = 0 ] || { echo "FATAL: run as root"; exit 1; }
[ -n "$IN_DIR" ] && trap 'rm -rf "$IN_DIR"' EXIT
q() { sudo -u postgres psql -At -v ON_ERROR_STOP=1 "$@"; }
echo "== state"
echo "  user: $(id -u $APP >/dev/null 2>&1 && echo exists || echo missing) | env: $(test -f $ENV_FILE && echo present || echo missing)"
echo "  role: $(q -c "select count(*) from pg_roles where rolname='$APP'") | db: $(q -c "select count(*) from pg_database where datname='$APP'") | port 8097 in use: $(ss -ltnH 'sport = :8097' | wc -l) | unit: $(systemctl is-active $APP 2>/dev/null || true)"
if [ -n "$IN_DIR" ]; then
  for f in .env aple26.dump; do test -s "$IN_DIR/$f" || { echo "FATAL: $IN_DIR/$f missing"; exit 1; }; done
  sed -i 's/\r$//' "$IN_DIR/.env"
  echo "  old .env keys: $(grep -cE '^[A-Z0-9_]+=' "$IN_DIR/.env") (APP_PORT=$(sed -n 's/^APP_PORT=//p' "$IN_DIR/.env"), DB_HOST=$(sed -n 's/^DB_HOST=//p' "$IN_DIR/.env"), DB_NAME=$(sed -n 's/^DB_NAME=//p' "$IN_DIR/.env"); APP_KEY set: $(grep -q '^APP_KEY=.\+' "$IN_DIR/.env" && echo yes || echo NO))"
  echo "  dump: $(du -h "$IN_DIR/aple26.dump" | cut -f1), $(/usr/lib/postgresql/16/bin/pg_restore -l "$IN_DIR/aple26.dump" | grep -c 'TABLE DATA') tables with data"
fi
[ "$MODE" = "apply" ] || { echo "CHECK DONE (nothing written)"; exit 0; }
[ -n "$IN_DIR" ] || { echo "FATAL: IN_DIR needed for apply"; exit 1; }
if [ "$(q -c "select count(*) from pg_database where datname='$APP'")" != 0 ] || test -f $ENV_FILE; then
  echo "FATAL: aple26 already has a database or .env here — refusing to overwrite (restore by hand from the backups)"; exit 1
fi

echo "== 1. backups of the other databases"
TS=$(date -u +%Y%m%dT%H%M%SZ); BK=/var/backups/pre-aple26-$TS; mkdir -p $BK; chmod 700 $BK
for db in nextidp nextdp_core r1sms; do
  if [ "$(q -c "select count(*) from pg_database where datname='$db'")" = 1 ]; then
    sudo -u postgres pg_dump -Fc -d $db > $BK/$db.dump; echo "  $db $(du -h $BK/$db.dump | cut -f1)"
  fi
done
echo "  -> $BK"

echo "== 2. user + dirs"
id "$APP" >/dev/null 2>&1 || useradd --system --home-dir "$BASE" --no-create-home --shell /usr/sbin/nologin "$APP"
mkdir -p "$BASE/releases" "$BASE/shared"
chown "$APP:$APP" "$BASE" "$BASE/shared"; chmod 0755 "$BASE" "$BASE/releases"; chmod 0750 "$BASE/shared"

echo "== 3. old .env"
install -o root -g "$APP" -m 0640 "$IN_DIR/.env" "$ENV_FILE"
echo "  $ENV_FILE ($(grep -cE '^[A-Z0-9_]+=' $ENV_FILE) keys)"

echo "== 4. database"
DBPW=$(sed -n 's/^DB_PASSWORD=//p' $ENV_FILE | tail -1)
[ -n "$DBPW" ] || { echo "FATAL: no DB_PASSWORD in the old .env"; exit 1; }
if [ "$(q -c "select count(*) from pg_roles where rolname='$APP'")" = 0 ]; then
  printf "create role %s login password '%s';\n" "$APP" "$DBPW" | sudo -u postgres psql -q -v ON_ERROR_STOP=1
else
  printf "alter role %s login password '%s';\n" "$APP" "$DBPW" | sudo -u postgres psql -q -v ON_ERROR_STOP=1
fi
unset DBPW
sudo -u postgres createdb -O $APP $APP
install -o postgres -g postgres -m 0600 "$IN_DIR/aple26.dump" /tmp/.aple26-restore.dump
set +e
sudo -u postgres pg_restore --no-owner --no-acl --role=$APP -d $APP /tmp/.aple26-restore.dump > /tmp/.aple26-restore.log 2>&1; rc=$?
set -e
rm -f /tmp/.aple26-restore.dump
echo "  pg_restore rc=$rc, error lines=$(grep -c 'error:' /tmp/.aple26-restore.log || true)"; grep 'error:' /tmp/.aple26-restore.log | head -5 || true; rm -f /tmp/.aple26-restore.log
[ "$rc" = 0 ] || { echo "FATAL: restore failed (database aple26 left for inspection; backups in $BK)"; exit 1; }
echo "  owner check: $(q -d $APP -c "select count(*) from pg_tables where schemaname='public' and tableowner <> '$APP'") tables not owned by $APP"
q -d $APP -F ' ' -c "select 'tables', count(*), 'rows~', coalesce(sum(n_live_tup),0) from pg_stat_user_tables" 
q -d $APP -F ' | ' -c "analyze" >/dev/null
q -d $APP -F ' | ' -c "select relname, n_live_tup from pg_stat_user_tables order by n_live_tup desc limit 8"
echo "PREPARE DONE — now the app's bootstrap + release (scripts/deploy.sh --bootstrap with DEPLOY_HOST)"
