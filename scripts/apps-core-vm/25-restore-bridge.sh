#!/usr/bin/env bash
# Runs on Apps-Core-VM as root. Prepares BaluBot / Bridge (repo projects/products/custom-android-os, backend/) with its
# OLD data before the repo's own tools\bridge-test.ps1 -Deploy installs the binary:
#   1. dumps of the other databases on this VM first
#   2. the repo's backend/deploy/setup.sh (user, dirs, 3 units, ufw UDP 40000-40100, Caddy site balubot.rajesh1.com)
#   3. the OLD /etc/bridge/env (+ gcp-sa.json); changed only: DB / Redis on this VM, WA_PUBLIC_IP, the new domain
#   4. role + database `bridge` from the old env, pg_restore of the archived dump (final state of Azure nmc-db-1)
# IN_DIR holds env, gcp-sa.json, bridge.dump, setup.sh (0600; deleted at the end). MODE=check | apply.
set -Eeuo pipefail
exec 2>&1
MODE="${MODE:-check}"; IN_DIR="${IN_DIR:?}"
NEW_DOMAIN=balubot.rajesh1.com; OLD_DOMAIN=balubot.rajesh.in; PUBLIC_IP=43.204.42.99
[ "$(id -u)" = 0 ] || { echo "FATAL: run as root"; exit 1; }
trap 'rm -rf "$IN_DIR"' EXIT
q() { sudo -u postgres psql -At -v ON_ERROR_STOP=1 "$@"; }
val() { sed -n "s/^$1=//p" "$2" | tail -1 | sed -E 's/^"(.*)"$/\1/'; }
for f in env gcp-sa.json bridge.dump setup.sh; do test -s "$IN_DIR/$f" || { echo "FATAL: $IN_DIR/$f missing"; exit 1; }; done
sed -i 's/\r$//' "$IN_DIR/env" "$IN_DIR/setup.sh"
RPW=$(val REDIS_PASSWORD /root/.apps-core-secrets.env)
echo "== state"
echo "  old env: $(grep -cE '^[A-Z0-9_]+=' $IN_DIR/env) keys; APP_PORT=$(val APP_PORT $IN_DIR/env) DB_HOST=$(val DB_HOST $IN_DIR/env) DB_NAME=$(val DB_NAME $IN_DIR/env) REDIS_DB=$(val REDIS_DB $IN_DIR/env) APP_URL=$(val APP_URL $IN_DIR/env); old domain mentions: $(grep -c "$OLD_DOMAIN" $IN_DIR/env)"
echo "  dump: $(du -h $IN_DIR/bridge.dump | cut -f1), $(/usr/lib/postgresql/16/bin/pg_restore -l $IN_DIR/bridge.dump | grep -c 'TABLE DATA') tables with data"
echo "  here: user bridge $(id -u bridge >/dev/null 2>&1 && echo exists || echo missing) | /etc/bridge/env $(test -s /etc/bridge/env && echo present || echo missing) | db bridge $(q -c "select count(*) from pg_database where datname='bridge'") | port 8085 in use: $(ss -ltnH 'sport = :8085' | wc -l) | redis db 7 keys: $(redis-cli -a "$RPW" --no-auth-warning -n 7 dbsize 2>/dev/null || echo ?)"
[ "$MODE" = "apply" ] || { echo "CHECK DONE (nothing written)"; exit 0; }
[ "$(q -c "select count(*) from pg_database where datname='bridge'")" = 0 ] && ! test -s /etc/bridge/env || { echo "FATAL: bridge DB or env already here — refusing to overwrite"; exit 1; }

echo "== 1. backups of the other databases"
TS=$(date -u +%Y%m%dT%H%M%SZ); BK=/var/backups/pre-bridge-$TS; mkdir -p $BK; chmod 700 $BK
for db in $(q -c "select datname from pg_database where datallowconn and datname not in ('postgres','template0','template1') and datname not like '%\_r2' order by 1"); do
  sudo -u postgres pg_dump -Fc -d "$db" > "$BK/$db.dump"; echo "  $db $(du -h "$BK/$db.dump" | cut -f1)"
done
echo "  -> $BK"

echo "== 2. repo setup.sh"
DOMAIN=$NEW_DOMAIN APP_PORT=8085 bash "$IN_DIR/setup.sh"

echo "== 3. old env + GCP key"
python3 - "$IN_DIR/env" /etc/bridge/env.new "$RPW" "$NEW_DOMAIN" "$OLD_DOMAIN" "$PUBLIC_IP" <<'PY'
import sys
src, dst, rpw, new, old, ip = sys.argv[1:7]
set_ = {"DB_HOST": "127.0.0.1", "DB_PORT": "5432", "DB_SSL_MODE": "disable", "REDIS_HOST": "127.0.0.1", "REDIS_PORT": "6379",
        "REDIS_ADDR": "127.0.0.1:6379", "REDIS_PASSWORD": rpw, "WA_PUBLIC_IP": ip, "APP_URL": f"https://{new}"}
out, seen, dom = [], set(), 0
for l in open(src, encoding="utf-8").read().splitlines():
    k = l.split("=", 1)[0].strip() if "=" in l and not l.lstrip().startswith("#") else None
    if k in set_:
        out.append(f"{k}={set_[k]}"); seen.add(k); continue
    if old in l:
        l = l.replace(old, new); dom += 1
    out.append(l)
add = [k for k in set_ if k not in seen]
if add:
    out += ["", "# AWS Apps-Core-VM (aws-setup-and-migrations scripts/apps-core-vm/25-restore-bridge)"] + [f"{k}={set_[k]}" for k in add]
open(dst, "w", encoding="utf-8").write("\n".join(out) + "\n")
print(f"  env: {len(seen)} values changed, {len(add)} added ({', '.join(add) or '-'}), other old-domain lines {dom}")
PY
install -o bridge -g bridge -m 0600 /etc/bridge/env.new /etc/bridge/env; rm -f /etc/bridge/env.new
install -o root -g bridge -m 0640 "$IN_DIR/env" /etc/bridge/env.azure-original
install -o bridge -g bridge -m 0600 "$IN_DIR/gcp-sa.json" /etc/bridge/gcp-sa.json
chown root:bridge /etc/bridge; chmod 0750 /etc/bridge

echo "== 4. database bridge"
DBU=$(val DB_USER /etc/bridge/env); DBPW=$(val DB_PASSWORD /etc/bridge/env); DBN=$(val DB_NAME /etc/bridge/env)
[ -n "$DBU" ] && [ -n "$DBPW" ] && [ -n "$DBN" ] || { echo "FATAL: DB_USER / DB_PASSWORD / DB_NAME missing"; exit 1; }
if [ "$(q -c "select count(*) from pg_roles where rolname='$DBU'")" = 0 ]; then
  printf "create role \"%s\" login password '%s';\n" "$DBU" "$DBPW" | sudo -u postgres psql -q -v ON_ERROR_STOP=1
else
  printf "alter role \"%s\" login password '%s';\n" "$DBU" "$DBPW" | sudo -u postgres psql -q -v ON_ERROR_STOP=1
fi
unset DBPW
sudo -u postgres createdb -O "$DBU" "$DBN"
install -o postgres -g postgres -m 0600 "$IN_DIR/bridge.dump" /tmp/.bridge-restore.dump
set +e
sudo -u postgres pg_restore --no-owner --no-acl --role="$DBU" -d "$DBN" /tmp/.bridge-restore.dump > /tmp/.bridge-restore.log 2>&1; rc=$?
set -e
rm -f /tmp/.bridge-restore.dump
echo "  pg_restore rc=$rc, error lines=$(grep -c 'error:' /tmp/.bridge-restore.log || true)"; grep 'error:' /tmp/.bridge-restore.log | head -5 || true; rm -f /tmp/.bridge-restore.log
[ "$rc" = 0 ] || { echo "FATAL: restore failed (other DBs backed up in $BK)"; exit 1; }
q -d "$DBN" -c analyze >/dev/null
q -d "$DBN" -F ' ' -c "select 'tables', count(*), 'rows~', coalesce(sum(n_live_tup),0) from pg_stat_user_tables"
q -d "$DBN" -F ' | ' -c "select relname, n_live_tup from pg_stat_user_tables order by n_live_tup desc limit 6"
echo "  login check as $DBU over 127.0.0.1: $(sudo -u bridge env PGPASSWORD="$(val DB_PASSWORD /etc/bridge/env)" psql -h 127.0.0.1 -U "$DBU" -d "$DBN" -At -c 'select 1' 2>&1 | head -1)"
echo "PREPARE DONE — next: tools\\bridge-test.ps1 -Deploy (repo) installs /opt/bridge/bridge and starts the units"
