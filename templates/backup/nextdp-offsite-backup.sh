#!/usr/bin/env bash
# /usr/local/sbin/nextdp-offsite-backup  (installed by scripts/mail-vm/16-setup-offsite-backup.ps1,
#                                         also used on Web-1 via scripts/web-1-vm/07-setup-offsite-backup.ps1)
# Off-site backup of one VM to its own restic repo on Cloudflare R2, independent of NextManager Core.
#   backup : pg_dump every app DB on cluster 16/main + globals, consistent copies of SQLite files, then
#            restic backup of dumps + PATHS; apply retention.
#   verify : restic check (data subset) + real restore test of the latest RESTORE_TEST_DB dump into a temp DB.
#   status : latest snapshots and last success/verify markers.
#   alert <unit> : mail the failure (journal tail) to ALERT_TO via ALERT_SMTP_HOST:25.
# Config: /etc/nextdp-backup/restic.env (secrets, root 0600) and optional /etc/nextdp-backup/backup.conf
# (non-secret per-VM overrides of the defaults below; defaults = Mail VM). Never prints secret values.
set -Eeuo pipefail

MODE="${1:-backup}"
CONF="/etc/nextdp-backup/restic.env"
VM_CONF="/etc/nextdp-backup/backup.conf"
STATE="/var/lib/nextdp-backup"

# ---- defaults (Mail VM) ----
VM_LABEL="Mail VM"
STAGE="/var/backups/nextdp/nightly"
HOST_TAG="mail-vm"
BACKUP_TAG="nextdp-mail"
PATHS=(/var/backups/nextdp/nightly/db /opt/nextdp/storage /opt/nextdp/config /etc/caddy /etc/coredns
       /var/lib/dithim /opt/dithim /etc/nextdp-backup/README)
EXCLUDES=(--exclude /opt/nextdp/storage/cache --exclude /opt/nextdp/storage/logs)
SQLITE_FILES=()
RESTORE_TEST_DB="nextdp_mail"
RESTORE_TEST_TABLE="messages"
MIN_TABLES=10
KEEP=(--keep-daily 14 --keep-weekly 8 --keep-monthly 12)
SKIP_DBS_RE='^(postgres|template0|template1)$|_aug_old$|_r2(_|$)|_r2check$|_restoretest$|_failed'

[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
set -a; # shellcheck disable=SC1090
source "$CONF"; set +a
# shellcheck disable=SC1090
[ -f "$VM_CONF" ] && source "$VM_CONF"
export RESTIC_CACHE_DIR="${RESTIC_CACHE_DIR:-/var/cache/restic}"
install -d -m 0700 "$STATE" "$RESTIC_CACHE_DIR"
log() { echo "[$(date -u +%FT%TZ)] $*"; }
cd /tmp

case "$MODE" in
backup)
  install -d -m 0700 "$STAGE" "$STAGE/db.new"
  rm -rf "${STAGE:?}"/db.new/*
  dbs=$(runuser -u postgres -- psql -p 5432 -XAt -c "SELECT datname FROM pg_database WHERE datallowconn ORDER BY 1" | grep -Ev "$SKIP_DBS_RE" || true)
  [ -n "$dbs" ] || { echo "no databases found" >&2; exit 1; }
  for db in $dbs; do
    runuser -u postgres -- pg_dump -p 5432 -Fc -d "$db" > "$STAGE/db.new/$db.dump"
    toc=$(pg_restore --list "$STAGE/db.new/$db.dump" | grep -vc '^;' || true)
    [ "$toc" -gt 0 ] || { echo "empty dump for $db" >&2; exit 1; }
    log "dump $db: $(stat -c%s "$STAGE/db.new/$db.dump") bytes, $toc toc entries"
  done
  runuser -u postgres -- pg_dumpall -p 5432 --globals-only > "$STAGE/db.new/globals.sql"
  if [ "${#SQLITE_FILES[@]}" -gt 0 ]; then
    install -d -m 0700 "$STAGE/db.new/sqlite"
    for f in "${SQLITE_FILES[@]}"; do
      [ -f "$f" ] || { log "sqlite missing (skipped): $f"; continue; }
      out="$STAGE/db.new/sqlite/$(echo "${f#/}" | tr '/' '_')"
      sqlite3 "$f" ".timeout 10000" ".backup '$out'"
      chk=$(sqlite3 "$out" 'PRAGMA quick_check;')
      [ "$chk" = ok ] || { echo "sqlite copy failed check: $f" >&2; exit 1; }
      log "sqlite $f: $(stat -c%s "$out") bytes, quick_check ok"
    done
  fi
  (cd "$STAGE/db.new" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
  rm -rf "$STAGE/db"; mv "$STAGE/db.new" "$STAGE/db"
  existing=(); for p in "${PATHS[@]}"; do [ -e "$p" ] && existing+=("$p"); done
  restic backup --host "$HOST_TAG" --tag "$BACKUP_TAG" --tag nightly "${EXCLUDES[@]}" "${existing[@]}" --json \
    | python3 -c 'import json,sys
for l in sys.stdin:
    try: o=json.loads(l)
    except Exception: continue
    if o.get("message_type")=="summary":
        print("snapshot %s: files new=%s changed=%s unmodified=%s, added %.1f MiB, total %.1f MiB" % (o.get("snapshot_id","")[:8], o.get("files_new"), o.get("files_changed"), o.get("files_unmodified"), o.get("data_added",0)/1048576, o.get("total_bytes_processed",0)/1048576))'
  restic forget --host "$HOST_TAG" --tag "$BACKUP_TAG" "${KEEP[@]}" --prune --quiet
  date -u +%FT%TZ > "$STATE/last-backup-success"
  log "backup OK; snapshots now: $(restic snapshots --host "$HOST_TAG" --json | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
  ;;
verify)
  restic check --read-data-subset=25% --quiet
  log "restic check OK"
  TDB="${RESTORE_TEST_DB}_restoretest"
  tmp=$(mktemp /var/tmp/restore-test.XXXXXX.dump)
  trap 'rm -f "$tmp"; runuser -u postgres -- psql -p 5432 -Xq -c "DROP DATABASE IF EXISTS $TDB;" >/dev/null 2>&1 || true' EXIT
  restic dump --host "$HOST_TAG" --tag "$BACKUP_TAG" latest "$STAGE/db/${RESTORE_TEST_DB}.dump" > "$tmp"
  chown postgres "$tmp"; chmod 0600 "$tmp"
  runuser -u postgres -- psql -p 5432 -Xq -c "DROP DATABASE IF EXISTS $TDB;" 2>/dev/null
  runuser -u postgres -- psql -p 5432 -Xq -c "CREATE DATABASE $TDB;"
  runuser -u postgres -- pg_restore -p 5432 -d "$TDB" --no-owner --no-acl "$tmp"
  q() { runuser -u postgres -- psql -p 5432 -XAt -d "$1" -c "$2"; }
  t=$(q "$TDB" "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'")
  r=$(q "$TDB" "SELECT count(*) FROM ${RESTORE_TEST_TABLE}"); l=$(q "$RESTORE_TEST_DB" "SELECT count(*) FROM ${RESTORE_TEST_TABLE}")
  log "restore test ${RESTORE_TEST_DB}: tables=$t ${RESTORE_TEST_TABLE} restored=$r live=$l"
  [ "$t" -ge "$MIN_TABLES" ] && [ "$r" -gt 0 ] || { echo "restore test FAILED" >&2; exit 1; }
  date -u +%FT%TZ > "$STATE/last-verify-success"
  log "verify OK"
  ;;
status)
  echo "VM: $VM_LABEL  host tag: $HOST_TAG  tag: $BACKUP_TAG"
  echo "last backup success: $(cat "$STATE/last-backup-success" 2>/dev/null || echo never)"
  echo "last verify success: $(cat "$STATE/last-verify-success" 2>/dev/null || echo never)"
  restic snapshots --host "$HOST_TAG" --latest 5 --compact 2>/dev/null
  restic stats --mode raw-data --quiet 2>/dev/null | grep -E 'Total Size|Total Blob' || true
  systemctl list-timers 'nextdp-offsite-*' --no-pager | head -4
  ;;
alert)
  unit="${2:-unknown}"
  body="$(journalctl -u "$unit" -n 40 --no-pager -o short-iso 2>&1 | tail -40)"
  UNIT="$unit" BODY="$body" VM_LABEL="$VM_LABEL" python3 - <<'PY'
import os, smtplib, socket, email.utils
from email.message import EmailMessage
m = EmailMessage()
m["From"] = os.environ.get("ALERT_FROM", "backup-alert@mail.nextdp.com")
m["To"] = os.environ["ALERT_TO"]
m["Subject"] = f"[{os.environ['VM_LABEL']}] backup job FAILED: {os.environ['UNIT']}"
m["Date"] = email.utils.formatdate(); m["Message-ID"] = email.utils.make_msgid(domain="mail.nextdp.com")
m.set_content(f"VM: {os.environ['VM_LABEL']} ({socket.gethostname()})\nUnit: {os.environ['UNIT']}\n\nLast journal lines:\n\n{os.environ['BODY']}\n\n"
              "Check: sudo nextdp-offsite-backup status\n")
with smtplib.SMTP(os.environ.get("ALERT_SMTP_HOST", "127.0.0.1"), 25, timeout=30) as s:
    s.send_message(m)
print("alert sent")
PY
  ;;
*) echo "usage: $0 backup|verify|status|alert <unit>" >&2; exit 2 ;;
esac
