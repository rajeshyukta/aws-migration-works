#!/usr/bin/env bash
# Phase 2 (docs/mail-vm-db-upgrade-r2.md): switch NextDP Mail from the August DB to R2 + AWS delta.
#   MODE=rehearse : no downtime. Re-stage R2, apply the merge (COMMIT) into nextdp_mail_r2, extract the
#                   Azure storage tar to a temp dir and check every referenced file exists. Live untouched.
#   MODE=cutover  : stop services, final backup, re-stage + merge, move AWS attachments, add Azure files,
#                   swap DBs by rename, migrate, rotate JWT/SESSION secrets, start, verify.
#                   Any failure after the services stop rolls back automatically.
# Expects 11-stage-r2-mail-db.sh, 13-merge-aws-delta.sh and 13-merge-aws-delta.sql in $SCRIPT_DIR.
# Never prints secret values.
set -Eeuo pipefail
exec 2>&1

MODE="${MODE:?MODE=rehearse|cutover}"
SCRIPT_DIR="${SCRIPT_DIR:?}"
SNAPSHOT_ID="${SNAPSHOT_ID:-689c5e6a}"
STAGE_DB="nextdp_mail_r2"
OLD_DB="nextdp_mail_aug_old"
STORAGE="/opt/nextdp/storage"
UPLOADS="${STORAGE}/uploads"
AZ_TAR="/var/backups/nextdp/azure-mail1-storage.tar.gz"
ENV_FILE="/opt/nextdp/config/.env"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="/var/backups/nextdp/cutover-${TS}$([ "$MODE" = rehearse ] && echo -rehearse || true)"
AZ_TMP="/var/tmp/azure-storage-${TS}"
UNITS="nextdp nextdp-worker nextdp-scheduler"
PHASE="init"   # init -> stopped -> swapped -> started
MOVED_LIST="${OUT}/attachments-moved.tsv"
cd /tmp

S() { sudo -u postgres psql -p 5432 -X "$@"; }
log() { echo "[$(date -u +%H:%M:%S)] $*"; }
db_exists() { [ "$(S -At -c "SELECT count(*) FROM pg_database WHERE datname='$1'")" = 1 ]; }

rollback() {
  local rc=$?
  # set -E propagates the ERR trap into $(...) subshells; only the main shell may roll back.
  [ "$BASHPID" = "$$" ] || exit "$rc"
  trap - ERR EXIT
  rm -f "/tmp/.merge-$$.sql" "/tmp/.merge-log-$$" "/tmp/.refs-$$" 2>/dev/null || true
  [ "$MODE" = cutover ] || { sudo rm -rf "$AZ_TMP"; log "FAILED (rehearsal, rc=$rc). Live system untouched."; exit "$rc"; }
  log "!!! FAILURE in phase '$PHASE' (rc=$rc) - rolling back"
  if [ "$PHASE" = swapped ] || [ "$PHASE" = started ]; then
    sudo systemctl stop $UNITS || true
    S -q -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname IN ('nextdp_mail','$OLD_DB');" >/dev/null || true
    S -q -c "ALTER DATABASE nextdp_mail RENAME TO nextdp_mail_r2_failed_${TS,,};" || true
    S -q -c "ALTER DATABASE $OLD_DB RENAME TO nextdp_mail;" || true
    sudo test -f "$OUT/dot-env.root-only" && sudo install -m 0600 -o ubuntu -g ubuntu "$OUT/dot-env.root-only" "$ENV_FILE"
  fi
  if [ "$PHASE" != init ] && sudo test -s "$MOVED_LIST"; then
    while IFS=$'\t' read -r old new; do
      sudo mkdir -p "$(dirname "$UPLOADS/$old")"
      if sudo test -e "$UPLOADS/$new"; then sudo mv -f "$UPLOADS/$new" "$UPLOADS/$old"; fi
    done < <(sudo cat "$MOVED_LIST")
    log "  attachment moves reversed"
  fi
  if [ "$PHASE" != init ]; then
    sudo chown -R ubuntu:ubuntu "$STORAGE" || true
    sudo systemctl start $UNITS || true
    sleep 3
    log "services after rollback: $(systemctl is-active $UNITS | tr '\n' ' ')"
  fi
  sudo rm -rf "$AZ_TMP"
  log "ROLLED BACK. Live DB is the August DB again. Logs/backups: $OUT"
  exit "$rc"
}
trap rollback ERR

# ---------- preflight ----------
log "=== preflight (MODE=$MODE) ==="
sudo test -s "/var/backups/nextdp/r2-${SNAPSHOT_ID}/nextdp_mail.dump" || { echo "FATAL: R2 dump missing; run 11-stage first" >&2; exit 1; }
sudo test -s "$AZ_TAR" || { echo "FATAL: $AZ_TAR missing" >&2; exit 1; }
for f in 11-stage-r2-mail-db.sh 13-merge-aws-delta.sh 13-merge-aws-delta.sql; do [ -f "$SCRIPT_DIR/$f" ] || { echo "FATAL: $SCRIPT_DIR/$f missing" >&2; exit 1; }; done
if [ "$MODE" = cutover ]; then
  db_exists "$OLD_DB" && { echo "FATAL: $OLD_DB already exists (earlier cutover?)" >&2; exit 1; }
  systemctl is-active --quiet nextdp || { echo "FATAL: nextdp is not running; expected the live August setup" >&2; exit 1; }
fi
command -v rsync >/dev/null || { echo "FATAL: rsync missing" >&2; exit 1; }
[ "$(df --output=avail -B1G / | tail -1 | tr -d ' ')" -ge 5 ] || { echo "FATAL: <5 GB free" >&2; exit 1; }
sudo install -d -m 0750 -o root -g ubuntu "$OUT"

# ---------- stop + final backup ----------
if [ "$MODE" = cutover ]; then
  log "=== [1] stopping $UNITS (Caddy stays up) ==="
  PHASE="stopped"
  sudo systemctl stop nextdp-scheduler nextdp-worker nextdp
  log "  stopped: $(systemctl is-active $UNITS | tr '\n' ' ')"
  export REDISCLI_AUTH="$(sudo grep -E '^REDIS_PASSWORD=' "$ENV_FILE" | cut -d= -f2- | tr -d '"\r')"
  log "  redis keys while stopped (queued jobs/sessions): $(redis-cli DBSIZE | tr -d '\r')"
  unset REDISCLI_AUTH
  log "=== [2] final backup of the frozen August DB + storage ==="
  S -At -c "SELECT 1" >/dev/null
  sudo -u postgres pg_dump -p 5432 -Fc -d nextdp_mail | sudo tee "$OUT/nextdp_mail-final.dump" >/dev/null
  sudo tar -czf "$OUT/storage-final.tar.gz" -C /opt/nextdp storage
  sudo install -m 0600 -o root -g root "$ENV_FILE" "$OUT/dot-env.root-only"
  (cd "$OUT" && sudo sh -c 'sha256sum nextdp_mail-final.dump storage-final.tar.gz > SHA256SUMS')
  sudo chmod 0640 "$OUT"/*.dump "$OUT"/*.tar.gz "$OUT/SHA256SUMS"; sudo chown root:ubuntu "$OUT"/*.dump "$OUT"/*.tar.gz "$OUT/SHA256SUMS"
  log "  final dump $(sudo stat -c%s "$OUT/nextdp_mail-final.dump") B, storage tar $(sudo stat -c%s "$OUT/storage-final.tar.gz") B"
fi

# ---------- re-stage + merge ----------
log "=== [3] re-stage $STAGE_DB from R2 dump (clean base) ==="
SNAPSHOT_ID="$SNAPSHOT_ID" TARGET_DB="$STAGE_DB" REUSE_DUMP=1 bash "$SCRIPT_DIR/11-stage-r2-mail-db.sh" | grep -E 'pg_restore rc|Reusing|STAGED_DB|FATAL|error'
log "=== [4] merge AWS delta (COMMIT) ==="
cp "$SCRIPT_DIR/13-merge-aws-delta.sql" "/tmp/.merge-$$.sql"
if ! STAGE_DB="$STAGE_DB" SQL_FILE="/tmp/.merge-$$.sql" DRY_RUN=0 ALLOW_RUNNING="$([ "$MODE" = rehearse ] && echo 1 || echo 0)" \
  bash "$SCRIPT_DIR/13-merge-aws-delta.sh" > "/tmp/.merge-log-$$" 2>&1; then
  tail -30 "/tmp/.merge-log-$$"; false
fi
sed -n '/--- id mapping summary/,/MERGE_OUT=/p' "/tmp/.merge-log-$$"
MERGE_OUT="$(sed -n 's/^MERGE_OUT=//p' "/tmp/.merge-log-$$")"; rm -f "/tmp/.merge-log-$$"
grep -q . <<<"$MERGE_OUT" && sudo test -f "$MERGE_OUT/attachment-paths.csv" || { echo "FATAL: merge output missing" >&2; false; }
sudo cp "$MERGE_OUT"/* "$OUT/"
sudo chgrp ubuntu "$OUT"/*; sudo chmod 0640 "$OUT"/*.csv
S -d "$STAGE_DB" -q -c "DROP SCHEMA aws_src CASCADE;" >/dev/null 2>&1 || true

# ---------- file coverage check ----------
log "=== [5] extract Azure storage tar to $AZ_TMP ==="
sudo install -d -m 0750 -o root -g root "$AZ_TMP"
sudo tar -xzf "$AZ_TAR" -C "$AZ_TMP"
log "  azure files: $(sudo find "$AZ_TMP" -type f | wc -l)"

log "=== [6] attachment moves for the AWS delta ($(sudo cat "$OUT/attachment-paths.csv" | wc -l) files) ==="
: | sudo tee "$MOVED_LIST" >/dev/null
while IFS=, read -r old new; do
  old="${old//\"/}"; new="${new//\"/}"
  case "$old$new" in *..*) echo "FATAL: unsafe path" >&2; false ;; esac
  sudo test -f "$UPLOADS/$old" || { echo "FATAL: AWS attachment missing: $old" >&2; false; }
  if sudo test -e "$UPLOADS/$new"; then
    sudo cmp -s "$UPLOADS/$old" "$UPLOADS/$new" || { echo "FATAL: target exists with other content: $new" >&2; false; }
  fi
  if [ "$MODE" = cutover ]; then
    sudo mkdir -p "$(dirname "$UPLOADS/$new")"
    sudo mv -n "$UPLOADS/$old" "$UPLOADS/$new"
    printf '%s\t%s\n' "$old" "$new" | sudo tee -a "$MOVED_LIST" >/dev/null
  fi
done < <(sudo cat "$OUT/attachment-paths.csv")
[ "$MODE" = cutover ] && sudo find "$UPLOADS/attachments" -mindepth 1 -type d -empty -delete

log "=== [7] add Azure-period files (never overwrites existing files) ==="
RS_DRY=""; [ "$MODE" = rehearse ] && RS_DRY="--dry-run"
for sub in uploads bimi; do
  sudo test -d "$AZ_TMP/$sub" || continue
  n=$(sudo rsync -a --ignore-existing $RS_DRY --out-format='%n' "$AZ_TMP/$sub/" "$STORAGE/$sub/" | grep -vc '/$' || true)
  log "  $sub: $n new files $([ -n "$RS_DRY" ] && echo '(dry-run)' || true)"
done
[ "$MODE" = cutover ] && sudo chown -R ubuntu:ubuntu "$STORAGE"

log "=== [8] every file referenced by the merged DB must exist ==="
S -d "$STAGE_DB" -At -c "SELECT 'eml', eml_path FROM raw_emails WHERE coalesce(eml_path,'')<>''
                         UNION ALL SELECT 'att', storage_path FROM attachments WHERE coalesce(storage_path,'')<>''" > "/tmp/.refs-$$"
sudo REFS="/tmp/.refs-$$" UPLOADS="$UPLOADS" AZ_UP="$AZ_TMP/uploads" MODE="$MODE" MOVED="$OUT/attachment-paths.csv" python3 - <<'PY'
import csv, os
up, az, mode = os.environ["UPLOADS"], os.environ["AZ_UP"], os.environ["MODE"]
moved = {row[1] for row in csv.reader(open(os.environ["MOVED"])) if len(row) == 2} if mode == "rehearse" else set()
total, miss = 0, {"eml": [], "att": []}
for line in open(os.environ["REFS"], encoding="utf-8"):
    kind, _, p = line.rstrip("\n").partition("|")
    total += 1
    if os.path.isfile(os.path.join(up, p)) or os.path.isfile(os.path.join(az, p)) or p in moved:
        continue
    miss[kind].append(p)
print(f"  referenced={total} missing_eml={len(miss['eml'])} missing_att={len(miss['att'])}")
for k in miss:
    for p in miss[k][:10]:
        print(f"  missing {k}: {p}")
PY
rm -f "/tmp/.refs-$$"
sudo rm -rf "$AZ_TMP"

if [ "$MODE" = rehearse ]; then
  trap - ERR
  log "REHEARSAL_OK. $STAGE_DB now holds the merged data (re-staged again at cutover). Live untouched."
  exit 0
fi

# ---------- swap ----------
log "=== [9] swap databases ==="
S -q -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname IN ('nextdp_mail','$STAGE_DB') AND pid<>pg_backend_pid();" >/dev/null
S -q -c "ALTER DATABASE nextdp_mail RENAME TO $OLD_DB;"
PHASE="swapped"
S -q -c "ALTER DATABASE $STAGE_DB RENAME TO nextdp_mail;"
log "  databases: $(S -At -c "SELECT string_agg(datname, ' ' ORDER BY datname) FROM pg_database WHERE datname LIKE 'nextdp_mail%'")"

log "=== [10] nextdp migrate ==="
(cd /opt/nextdp/config && /opt/nextdp/bin/nextdp migrate) | tail -5

log "=== [11] rotate JWT_SECRET + SESSION_SECRET (user ids changed; old tokens must die) ==="
sudo python3 - "$ENV_FILE" <<'PY'
import os, secrets, sys
p = sys.argv[1]
lines = open(p, encoding="utf-8").read().splitlines()
out, seen = [], set()
for l in lines:
    k = l.split("=", 1)[0]
    if k in ("JWT_SECRET", "SESSION_SECRET"):
        out.append(f"{k}={secrets.token_hex(32)}"); seen.add(k)
    else:
        out.append(l)
for k in ("JWT_SECRET", "SESSION_SECRET"):
    if k not in seen:
        out.append(f"{k}={secrets.token_hex(32)}")
st = os.stat(p)
open(p, "w", encoding="utf-8").write("\n".join(out) + "\n")
os.chown(p, st.st_uid, st.st_gid); os.chmod(p, 0o600)
print("  rotated (values not shown)")
PY
export REDISCLI_AUTH="$(sudo grep -E '^REDIS_PASSWORD=' "$ENV_FILE" | cut -d= -f2- | tr -d '"\r')"
others=$(redis-cli CLIENT LIST 2>/dev/null | grep -vc 'cmd=client' || true)
if [ "${others:-0}" = 0 ]; then
  log "  redis: no other clients, keys before flush: $(redis-cli DBSIZE | tr -d '\r')"; redis-cli FLUSHDB >/dev/null
else
  log "  redis: $others other client(s) connected, NOT flushing (check manually)"
fi
unset REDISCLI_AUTH

# ---------- start + verify ----------
log "=== [12] start services ==="
sudo systemctl start nextdp
sleep 3
sudo systemctl start nextdp-worker nextdp-scheduler
PHASE="started"
ok=0
for i in $(seq 1 20); do
  if curl -fsS --max-time 3 http://127.0.0.1:8080/api/health/ready >/dev/null 2>&1; then ok=1; break; fi; sleep 2
done
[ "$ok" = 1 ] || { echo "FATAL: health check failed" >&2; false; }
log "  health: $(curl -sS --max-time 3 http://127.0.0.1:8080/api/health/ready)"
log "  units: $(systemctl is-active $UNITS | tr '\n' ' ')"
for port in 25 465 587 143 993 110 995; do ss -ltn "sport = :$port" | grep -q LISTEN || { echo "FATAL: port $port not listening" >&2; false; }; done
log "  mail ports 25/465/587/143/993/110/995 listening"
S -d nextdp_mail -At -c "SELECT 'orgs='||(SELECT count(*) FROM organizations)||' domains='||(SELECT count(*) FROM domains)||' users='||(SELECT count(*) FROM users)||' mailboxes='||(SELECT count(*) FROM mailboxes)||' messages='||(SELECT count(*) FROM messages)||' raw_emails='||(SELECT count(*) FROM raw_emails)||' attachments='||(SELECT count(*) FROM attachments)"
trap - ERR
log "CUTOVER_OK. Old DB kept as $OLD_DB. Backups + id maps: $OUT"
