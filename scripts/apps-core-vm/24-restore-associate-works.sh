#!/usr/bin/env bash
# Runs on Apps-Core-VM as root. Prepares Associate Works (repo projects/products/associate-works) with its OLD data:
#   1. dumps of the other databases on this VM first (nextidp, nextdp_core, r1sms, aple26)
#   2. user `aw`, /opt/aw/{releases,bin,web}, the OLD /etc/aw (backend.env: APP_KEY / Vault keys, JWT, mail, Next Pay,
#      passkeys … + GeoIP) — only what must differ here is changed (port, DB / Redis on this VM, the new S3 bucket)
#   3. PG role + database from the old .env, pg_restore of the archived dump (final state of the Azure nmc-db-1)
# IN_DIR holds backend.env, associate_works.dump, geoip/*.mmdb, s3.env (all 0600; deleted at the end). MODE=check|apply.
set -Eeuo pipefail
exec 2>&1
MODE="${MODE:-check}"; IN_DIR="${IN_DIR:?}"; PORT="${PORT:-8093}"; REDIS_DB_NO="${REDIS_DB_NO:-2}"
APP=aw; ENVF=/etc/aw/backend.env
[ "$(id -u)" = 0 ] || { echo "FATAL: run as root"; exit 1; }
trap 'rm -rf "$IN_DIR"' EXIT
q() { sudo -u postgres psql -At -v ON_ERROR_STOP=1 "$@"; }
val() { sed -n "s/^$1=//p" "$2" | tail -1 | sed -E 's/^"(.*)"$/\1/'; }
for f in backend.env associate_works.dump s3.env; do test -s "$IN_DIR/$f" || { echo "FATAL: $IN_DIR/$f missing"; exit 1; }; done
sed -i 's/\r$//' "$IN_DIR/backend.env" "$IN_DIR/s3.env"
OLD_DB=$(val DB_NAME "$IN_DIR/backend.env"); OLD_USER=$(val DB_USER "$IN_DIR/backend.env")
DB_NAME=$(/usr/lib/postgresql/16/bin/pg_restore -l "$IN_DIR/associate_works.dump" | sed -n 's/^;[[:space:]]*dbname: //p' | head -1)
echo "== state"
echo "  old .env: $(grep -cE '^[A-Z0-9_]+=' $IN_DIR/backend.env) keys; DB_NAME=$OLD_DB DB_USER=$OLD_USER DB_HOST=$(val DB_HOST $IN_DIR/backend.env) APP_PORT=$(val APP_PORT $IN_DIR/backend.env) APP_KEY set: $(grep -q '^APP_KEY=.\+' $IN_DIR/backend.env && echo yes || echo NO)"
echo "  dump: $(du -h $IN_DIR/associate_works.dump | cut -f1), database in dump: $DB_NAME, $(/usr/lib/postgresql/16/bin/pg_restore -l $IN_DIR/associate_works.dump | grep -c 'TABLE DATA') tables with data; extensions: $(/usr/lib/postgresql/16/bin/pg_restore -l $IN_DIR/associate_works.dump | awk '/ EXTENSION /{print $6}' | paste -sd, -)"
echo "  geoip: $(ls $IN_DIR/geoip 2>/dev/null | paste -sd' ')"
echo "  here: user aw $(id -u aw >/dev/null 2>&1 && echo exists || echo missing) | /etc/aw $(test -e /etc/aw && echo exists || echo missing) | db $DB_NAME $(q -c "select count(*) from pg_database where datname='$DB_NAME'") | port $PORT in use: $(ss -ltnH "sport = :$PORT" | wc -l) | redis db $REDIS_DB_NO keys: $(redis-cli -a "$(val REDIS_PASSWORD /root/.apps-core-secrets.env)" --no-auth-warning -n $REDIS_DB_NO dbsize 2>/dev/null || echo ?)"
[ "$MODE" = "apply" ] || { echo "CHECK DONE (nothing written)"; exit 0; }
[ "$(q -c "select count(*) from pg_database where datname='$DB_NAME'")" = 0 ] && ! test -e $ENVF || { echo "FATAL: $DB_NAME or $ENVF already here — refusing to overwrite"; exit 1; }
[ "$(ss -ltnH "sport = :$PORT" | wc -l)" = 0 ] || { echo "FATAL: port $PORT in use"; exit 1; }

echo "== 1. backups of the other databases"
TS=$(date -u +%Y%m%dT%H%M%SZ); BK=/var/backups/pre-associate-works-$TS; mkdir -p $BK; chmod 700 $BK
for db in nextidp nextdp_core r1sms aple26; do
  [ "$(q -c "select count(*) from pg_database where datname='$db'")" = 1 ] && { sudo -u postgres pg_dump -Fc -d $db > $BK/$db.dump; echo "  $db $(du -h $BK/$db.dump | cut -f1)"; }
done
echo "  -> $BK"

echo "== 2. user, dirs, /etc/aw"
id -u $APP >/dev/null 2>&1 || useradd --system --home-dir /opt/$APP --no-create-home --shell /usr/sbin/nologin $APP
mkdir -p /opt/$APP/releases /opt/$APP/bin /opt/$APP/web /etc/aw/geoip
chown -R $APP:$APP /opt/$APP; chmod 755 /opt/$APP
for m in "$IN_DIR"/geoip/*.mmdb; do [ -f "$m" ] && install -o root -g $APP -m 0640 "$m" /etc/aw/geoip/; done
python3 - "$IN_DIR/backend.env" "$IN_DIR/s3.env" "$ENVF.new" "$PORT" "$REDIS_DB_NO" "$DB_NAME" <<'PY'
import sys
src, s3f, dst, port, rdb, dbname = sys.argv[1:7]
def kv(p):
    d = {}
    for l in open(p, encoding="utf-8"):
        s = l.strip()
        if s and not s.startswith("#") and "=" in s:
            k, v = s.split("=", 1); d[k.strip()] = v.strip()
    return d
s3 = kv(s3f)
core = kv("/root/.apps-core-secrets.env")
set_ = {"APP_PORT": port, "DB_HOST": "127.0.0.1", "DB_PORT": "5432", "DB_SSL_MODE": "disable", "DB_NAME": dbname,
        "REDIS_HOST": "127.0.0.1", "REDIS_PORT": "6379", "REDIS_PASSWORD": core.get("REDIS_PASSWORD", ""), "REDIS_DB": rdb,
        "STORAGE_DRIVER": "s3", "S3_ENDPOINT": "", "S3_BUCKET": s3["S3_BUCKET"], "S3_REGION": s3["S3_REGION"],
        "S3_KEY": s3["S3_KEY"], "S3_SECRET": s3["S3_SECRET"], "S3_SSE": s3.get("S3_SSE", "AES256")}
out, seen = [], set()
for l in open(src, encoding="utf-8").read().splitlines():
    k = l.split("=", 1)[0].strip() if "=" in l and not l.lstrip().startswith("#") else None
    if k in set_:
        out.append(f"{k}={set_[k]}"); seen.add(k)
    else:
        out.append(l)
add = [k for k in set_ if k not in seen]
if add:
    out += ["", "# AWS Apps-Core-VM (aws-setup-and-migrations scripts/apps-core-vm/24-restore-associate-works)"] + [f"{k}={set_[k]}" for k in add]
open(dst, "w", encoding="utf-8").write("\n".join(out) + "\n")
print(f"  .env: {len(seen)} values changed for this VM, {len(add)} added (port, DB, Redis db {rdb}, S3 bucket {s3['S3_BUCKET']})")
PY
install -o root -g $APP -m 0640 "$ENVF.new" $ENVF; rm -f "$ENVF.new"
install -o root -g $APP -m 0640 "$IN_DIR/backend.env" /etc/aw/backend.env.azure-original
chown root:$APP /etc/aw /etc/aw/geoip; chmod 0750 /etc/aw /etc/aw/geoip

echo "== 3. database $DB_NAME"
DBU=$(val DB_USER $ENVF); DBPW=$(val DB_PASSWORD $ENVF)
[ -n "$DBU" ] && [ -n "$DBPW" ] || { echo "FATAL: DB_USER / DB_PASSWORD missing in the old .env"; exit 1; }
if [ "$(q -c "select count(*) from pg_roles where rolname='$DBU'")" = 0 ]; then
  printf "create role \"%s\" login password '%s';\n" "$DBU" "$DBPW" | sudo -u postgres psql -q -v ON_ERROR_STOP=1
else
  printf "alter role \"%s\" login password '%s';\n" "$DBU" "$DBPW" | sudo -u postgres psql -q -v ON_ERROR_STOP=1
fi
unset DBPW
sudo -u postgres createdb -O "$DBU" "$DB_NAME"
for ext in $(/usr/lib/postgresql/16/bin/pg_restore -l "$IN_DIR/associate_works.dump" | awk '/ EXTENSION /{print $6}'); do
  [ "$ext" = plpgsql ] && continue
  q -d "$DB_NAME" -c "create extension if not exists \"$ext\"" >/dev/null && echo "  extension $ext"
done
install -o postgres -g postgres -m 0600 "$IN_DIR/associate_works.dump" /tmp/.aw-restore.dump
set +e
sudo -u postgres pg_restore --no-owner --no-acl --role="$DBU" -d "$DB_NAME" /tmp/.aw-restore.dump > /tmp/.aw-restore.log 2>&1; rc=$?
set -e
rm -f /tmp/.aw-restore.dump
echo "  pg_restore rc=$rc, error lines=$(grep -c 'error:' /tmp/.aw-restore.log || true)"; grep 'error:' /tmp/.aw-restore.log | head -8 || true; rm -f /tmp/.aw-restore.log
[ "$rc" = 0 ] || { echo "FATAL: restore failed (database $DB_NAME left for inspection; other DBs backed up in $BK)"; exit 1; }
q -d "$DB_NAME" -c "analyze" >/dev/null
q -d "$DB_NAME" -F ' ' -c "select 'tables', count(*), 'rows~', coalesce(sum(n_live_tup),0), 'not owned by $DBU:', count(*) filter (where relowner <> (select oid from pg_roles where rolname='$DBU')) from pg_stat_user_tables join pg_class on pg_class.oid = relid"
q -d "$DB_NAME" -F ' | ' -c "select relname, n_live_tup from pg_stat_user_tables order by n_live_tup desc limit 6"
echo "PREPARE DONE"
