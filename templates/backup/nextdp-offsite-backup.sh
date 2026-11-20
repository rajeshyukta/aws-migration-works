#!/usr/bin/env bash
# /usr/local/sbin/nextdp-offsite-backup  (installed by scripts/mail-vm/16-setup-offsite-backup.ps1)
# Off-site backup of the Mail VM to its own restic repo on Cloudflare R2, independent of NextManager Core.
#   backup : pg_dump every app DB on cluster 16/main + globals, then restic backup of dumps, mail storage
#            and configs; apply retention.
#   verify : restic check (data subset) + real restore test of the latest nextdp_mail dump into a temp DB.
#   status : latest snapshots and last success/verify markers.
#   alert <unit> : mail the failure (journal tail) to ALERT_TO via the local SMTP listener.
# Config: /etc/nextdp-backup/restic.env (root 0600). Never prints secret values.
set -Eeuo pipefail

MODE="${1:-backup}"
CONF="/etc/nextdp-backup/restic.env"
STATE="/var/lib/nextdp-backup"
STAGE="/var/backups/nextdp/nightly"
HOST_TAG="mail-vm"
PATHS=(/var/backups/nextdp/nightly/db /opt/nextdp/storage /opt/nextdp/config /etc/caddy /etc/coredns
       /var/lib/dithim /opt/dithim /etc/nextdp-backup/README)
EXCLUDES=(--exclude /opt/nextdp/storage/cache --exclude /opt/nextdp/storage/logs)
KEEP=(--keep-daily 14 --keep-weekly 8 --keep-monthly 12)
SKIP_DBS_RE='^(postgres|template0|template1)$|_aug_old$|_r2(_|$)|_restoretest$|_failed'

[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
set -a; # shellcheck disable=SC1090
source "$CONF"; set +a
export RESTIC_CACHE_DIR="${RESTIC_CACHE_DIR:-/var/cache/restic}"
install -d -m 0700 "$STATE" "$RESTIC_CACHE_DIR"
log() { echo "[$(date -u +%FT%TZ)] $*"; }
cd /tmp

case "$MODE" in
backup)
  install -d -m 0700 "$STAGE" "$STAGE/db.new"
  rm -f "$STAGE"/db.new/*
  dbs=$(runuser -u postgres -- psql -p 5432 -XAt -c "SELECT datname FROM pg_database WHERE datallowconn ORDER BY 1" | grep -Ev "$SKIP_DBS_RE" || true)
  [ -n "$dbs" ] || { echo "no databases found" >&2; exit 1; }
  for db in $dbs; do
    runuser -u postgres -- pg_dump -p 5432 -Fc -d "$db" > "$STAGE/db.new/$db.dump"
    toc=$(pg_restore --list "$STAGE/db.new/$db.dump" | grep -vc '^;')
    [ "$toc" -gt 0 ] || { echo "empty dump for $db" >&2; exit 1; }
    log "dump $db: $(stat -c%s "$STAGE/db.new/$db.dump") bytes, $toc toc entries"
  done
  runuser -u postgres -- pg_dumpall -p 5432 --globals-only > "$STAGE/db.new/globals.sql"
  (cd "$STAGE/db.new" && sha256sum ./* > SHA256SUMS)
  rm -rf "$STAGE/db"; mv "$STAGE/db.new" "$STAGE/db"
  existing=(); for p in "${PATHS[@]}"; do [ -e "$p" ] && existing+=("$p"); done
  restic backup --host "$HOST_TAG" --tag nextdp-mail --tag nightly "${EXCLUDES[@]}" "${existing[@]}" --json \
    | python3 -c 'import json,sys
for l in sys.stdin:
    o=json.loads(l)
    if o.get("message_type")=="summary":
        print("snapshot %s: files new=%s changed=%s unmodified=%s, added %.1f MiB, total %.1f MiB" % (o.get("snapshot_id","")[:8], o.get("files_new"), o.get("files_changed"), o.get("files_unmodified"), o.get("data_added",0)/1048576, o.get("total_bytes_processed",0)/1048576))'
  restic forget --host "$HOST_TAG" --tag nextdp-mail "${KEEP[@]}" --prune --quiet
  date -u +%FT%TZ > "$STATE/last-backup-success"
  log "backup OK; snapshots now: $(restic snapshots --host "$HOST_TAG" --json | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
  ;;
verify)
  restic check --read-data-subset=25% --quiet
  log "restic check OK"
  tmp=$(mktemp /var/tmp/restore-test.XXXXXX.dump); trap 'rm -f "$tmp"; runuser -u postgres -- psql -p 5432 -Xq -c "DROP DATABASE IF EXISTS nextdp_mail_restoretest;" >/dev/null 2>&1 || true' EXIT
  restic dump --host "$HOST_TAG" --tag nextdp-mail latest "$STAGE/db/nextdp_mail.dump" > "$tmp"
  chown postgres "$tmp"; chmod 0600 "$tmp"
  runuser -u postgres -- psql -p 5432 -Xq -c "DROP DATABASE IF EXISTS nextdp_mail_restoretest;" 2>/dev/null
  runuser -u postgres -- psql -p 5432 -Xq -c "CREATE DATABASE nextdp_mail_restoretest;"
  runuser -u postgres -- pg_restore -p 5432 -d nextdp_mail_restoretest --no-owner --no-acl "$tmp"
  q() { runuser -u postgres -- psql -p 5432 -XAt -d "$1" -c "$2"; }
  t=$(q nextdp_mail_restoretest "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'")
  r=$(q nextdp_mail_restoretest "SELECT count(*) FROM messages"); l=$(q nextdp_mail "SELECT count(*) FROM messages")
  log "restore test: tables=$t messages restored=$r live=$l"
  [ "$t" -ge 10 ] && [ "$r" -gt 0 ] || { echo "restore test FAILED" >&2; exit 1; }
  date -u +%FT%TZ > "$STATE/last-verify-success"
  log "verify OK"
  ;;
status)
  echo "last backup success: $(cat "$STATE/last-backup-success" 2>/dev/null || echo never)"
  echo "last verify success: $(cat "$STATE/last-verify-success" 2>/dev/null || echo never)"
  restic snapshots --host "$HOST_TAG" --latest 5 --compact 2>/dev/null | tail -n +1
  restic stats --mode raw-data --quiet 2>/dev/null | grep -E 'Total Size|Total Blob' || true
  systemctl list-timers 'nextdp-offsite-*' --no-pager | head -4
  ;;
alert)
  unit="${2:-unknown}"
  body="$(journalctl -u "$unit" -n 40 --no-pager -o short-iso 2>&1 | tail -40)"
  UNIT="$unit" BODY="$body" python3 - <<'PY'
import os, smtplib, socket, email.utils
from email.message import EmailMessage
m = EmailMessage()
m["From"] = os.environ.get("ALERT_FROM", "backup-alert@mail.nextdp.com")
m["To"] = os.environ["ALERT_TO"]
m["Subject"] = f"[Mail VM] backup job FAILED: {os.environ['UNIT']}"
m["Date"] = email.utils.formatdate(); m["Message-ID"] = email.utils.make_msgid(domain="mail.nextdp.com")
m.set_content(f"Host: {socket.gethostname()}\nUnit: {os.environ['UNIT']}\n\nLast journal lines:\n\n{os.environ['BODY']}\n\n"
              "Check: sudo nextdp-offsite-backup status\n")
with smtplib.SMTP(os.environ.get("ALERT_SMTP_HOST", "127.0.0.1"), 25, timeout=30) as s:
    s.send_message(m)
print("alert sent")
PY
  ;;
*) echo "usage: $0 backup|verify|status|alert <unit>" >&2; exit 2 ;;
esac
