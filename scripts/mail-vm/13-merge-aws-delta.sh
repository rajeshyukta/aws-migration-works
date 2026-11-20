#!/usr/bin/env bash
# Task 1.6 / 2.3 (docs/mail-vm-db-upgrade-r2.md): copy the live AWS nextdp_mail into
# ${STAGE_DB}.aws_src and run 13-merge-aws-delta.sql against ${STAGE_DB}. DRY_RUN=1 (default) rolls back.
# Writes only to the staging DB. Saves id-map + attachment path map under /var/backups/nextdp/merge-<ts>/.
set -Eeuo pipefail
exec 2>&1

LIVE_DB="${LIVE_DB:-nextdp_mail}"
STAGE_DB="${STAGE_DB:-nextdp_mail_r2}"
SQL_FILE="${SQL_FILE:?SQL_FILE required}"
DRY_RUN="${DRY_RUN:-1}"
# August baseline: highest ids that came from the 2026-08-26 backup (docs section 2.2).
AUG_RAW="${AUG_RAW:-3634}" AUG_MSG="${AUG_MSG:-1420}" AUG_ATT="${AUG_ATT:-137}" AUG_DOM="${AUG_DOM:-24}"
AUG_USER="${AUG_USER:-28}" AUG_MB="${AUG_MB:-28}" AUG_FOLDER="${AUG_FOLDER:-145}" AUG_AUDIT="${AUG_AUDIT:-91}"
T0="${T0:-2026-11-18 09:27:00+00}"
UIDV="${UIDV:-$(date +%s)}"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="/var/backups/nextdp/merge-${TS}$([ "$DRY_RUN" = 1 ] && echo -dryrun || true)"
case "$STAGE_DB" in nextdp_mail_*) ;; *) echo "FATAL: STAGE_DB must be nextdp_mail_<suffix>" >&2; exit 1 ;; esac
trap 'rm -f "$SQL_FILE" 2>/dev/null || true; sudo rm -f /tmp/.merge-idmap.csv /tmp/.merge-attmap.csv 2>/dev/null || true' EXIT
cd /tmp
L() { sudo -u postgres psql -p 5432 -d "$LIVE_DB" -X "$@"; }
S() { sudo -u postgres psql -p 5432 -d "$STAGE_DB" -X "$@"; }

if [ "$DRY_RUN" != 1 ] && [ "${ALLOW_RUNNING:-0}" != 1 ]; then
  for u in nextdp nextdp-worker nextdp-scheduler; do
    systemctl is-active --quiet "$u" && { echo "FATAL: $u is running; stop services before a real merge" >&2; exit 1; }
  done
fi

echo "=== [1/2] Copy live ${LIVE_DB} -> ${STAGE_DB}.aws_src ==="
S -q -v ON_ERROR_STOP=1 -c "DROP SCHEMA IF EXISTS aws_src CASCADE; CREATE SCHEMA aws_src;" 2>&1 | grep -v NOTICE || true
for t in $(L -At -c "SELECT table_name FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE' ORDER BY 1"); do
  cols=$(S -At -c "SELECT string_agg(quote_ident(column_name), ',' ORDER BY ordinal_position) FROM information_schema.columns
                   WHERE table_schema='public' AND table_name='$t' AND is_generated='NEVER'")
  S -q -v ON_ERROR_STOP=1 -c "CREATE TABLE aws_src.\"$t\" (LIKE public.\"$t\" INCLUDING DEFAULTS);"
  L -q -v ON_ERROR_STOP=1 -c "\\copy (SELECT $cols FROM public.\"$t\") TO STDOUT" | S -q -v ON_ERROR_STOP=1 -c "\\copy aws_src.\"$t\" ($cols) FROM STDIN"
  lc=$(L -At -c "SELECT count(*) FROM public.\"$t\""); sc=$(S -At -c "SELECT count(*) FROM aws_src.\"$t\"")
  [ "$lc" = "$sc" ] || { echo "FATAL: copy mismatch for $t ($lc vs $sc)" >&2; exit 1; }
done
echo "  copied $(S -At -c "SELECT count(*) FROM information_schema.tables WHERE table_schema='aws_src'") tables"

echo "=== [2/2] Merge (DRY_RUN=${DRY_RUN}, uid_validity=${UIDV}) ==="
dr=false; [ "$DRY_RUN" = 1 ] && dr=true
sudo chmod 0644 "$SQL_FILE"
S -v aug_raw="$AUG_RAW" -v aug_msg="$AUG_MSG" -v aug_att="$AUG_ATT" -v aug_dom="$AUG_DOM" -v aug_user="$AUG_USER" \
  -v aug_mb="$AUG_MB" -v aug_folder="$AUG_FOLDER" -v aug_audit="$AUG_AUDIT" -v t0="$T0" -v uidv="$UIDV" -v dry_run="$dr" \
  -f "$SQL_FILE" | tee /tmp/.merge-out.$$
grep -q '^MERGE_RESULT=' /tmp/.merge-out.$$ || { echo "FATAL: merge did not finish" >&2; rm -f /tmp/.merge-out.$$; exit 1; }
rm -f /tmp/.merge-out.$$

sudo install -d -m 0750 -o root -g ubuntu "$OUT"
sudo install -m 0640 -o root -g ubuntu /tmp/.merge-idmap.csv "$OUT/id-map.csv"
sudo install -m 0640 -o root -g ubuntu /tmp/.merge-attmap.csv "$OUT/attachment-paths.csv"
echo "${UIDV}" | sudo tee "$OUT/uid_validity.txt" >/dev/null
echo "MERGE_OUT=${OUT}"
