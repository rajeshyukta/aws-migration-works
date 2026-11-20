#!/usr/bin/env bash
# Runs on the target VM. Restores an R2 dump into a SIDE-BY-SIDE database whose name ends in _r2
# (e.g. nextdp_core_r2), or drops such a database. Never touches a live database or a service.
#
# Env: MODE=restore|drop, TARGET_DB (must match ^[a-z][a-z0-9_]*_r2$),
#      DUMP_FILE (restore; uploaded temp file, deleted on exit), DB_OWNER (default postgres),
#      DB_COMMENT (restore; stored as COMMENT ON DATABASE, e.g. the snapshot id and time)
set -Eeuo pipefail
exec 2>&1

MODE="${MODE:-restore}"
TARGET_DB="${TARGET_DB:-}"
DUMP_FILE="${DUMP_FILE:-}"
DB_OWNER="${DB_OWNER:-postgres}"
DB_COMMENT="${DB_COMMENT:-}"
PG_TMP="/tmp/.r2-stage-$$.dump"
ERR_LOG="/tmp/.r2-stage-$$.err"
cleanup() { [ -n "$DUMP_FILE" ] && rm -f "$DUMP_FILE"; sudo rm -f "$PG_TMP"; rm -f "$ERR_LOG"; }
trap cleanup EXIT
cd /tmp

[[ "$TARGET_DB" =~ ^[a-z][a-z0-9_]*_r2$ ]] || { echo "FATAL: TARGET_DB must end in _r2 (got '$TARGET_DB')"; exit 1; }
[[ "$DB_OWNER" =~ ^[a-z_][a-z0-9_]*$ ]] || { echo "FATAL: invalid DB_OWNER"; exit 1; }
P() { sudo -u postgres psql -p 5432 -Xq -v ON_ERROR_STOP=1 "$@"; }

if [ "$MODE" = "drop" ]; then
  P -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${TARGET_DB}';" >/dev/null
  P -c "DROP DATABASE IF EXISTS ${TARGET_DB};"
  echo "DROPPED=${TARGET_DB}"
  exit 0
fi
[ "$MODE" = "restore" ] || { echo "FATAL: MODE must be restore or drop"; exit 1; }
[ -s "$DUMP_FILE" ] || { echo "FATAL: dump file missing: $DUMP_FILE"; exit 1; }
[ "$(sudo -u postgres psql -p 5432 -XAt -c "SELECT count(*) FROM pg_roles WHERE rolname='${DB_OWNER}'")" = 1 ] \
  || { echo "FATAL: role ${DB_OWNER} does not exist"; exit 1; }

echo "=== [1/3] (Re)create ${TARGET_DB} (owner ${DB_OWNER}) ==="
P -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${TARGET_DB}';" >/dev/null
P -c "DROP DATABASE IF EXISTS ${TARGET_DB};"
P -c "CREATE DATABASE ${TARGET_DB} OWNER ${DB_OWNER};"

echo "=== [2/3] pg_restore ==="
sudo install -o postgres -g postgres -m 0600 "$DUMP_FILE" "$PG_TMP"
set +e
if [ "$DB_OWNER" = "postgres" ]; then
  sudo -u postgres pg_restore -p 5432 -d "$TARGET_DB" --no-owner --no-acl "$PG_TMP" 2>"$ERR_LOG"
else
  sudo -u postgres pg_restore -p 5432 -d "$TARGET_DB" --no-owner --no-acl --role="$DB_OWNER" "$PG_TMP" 2>"$ERR_LOG"
fi
rc=$?
set -e
echo "  pg_restore rc=${rc}, error lines=$(grep -c 'error' "$ERR_LOG" || true)"
grep -i 'error' "$ERR_LOG" | head -10 || true
if [ -n "$DB_COMMENT" ]; then
  P -c "COMMENT ON DATABASE ${TARGET_DB} IS '$(printf '%s' "$DB_COMMENT" | sed "s/'/''/g")';"
fi

echo "=== [3/3] ${TARGET_DB}: rows per table ==="
for t in $(sudo -u postgres psql -p 5432 -d "$TARGET_DB" -XAt -c "SELECT quote_ident(table_name) FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE' ORDER BY 1"); do
  printf '  %-40s %s\n' "$t" "$(sudo -u postgres psql -p 5432 -d "$TARGET_DB" -XAt -c "SELECT count(*) FROM public.$t")"
done
echo "STAGED_DB=${TARGET_DB} size=$(sudo -u postgres psql -p 5432 -XAt -c "SELECT pg_size_pretty(pg_database_size('${TARGET_DB}'))")"
exit "$rc"
