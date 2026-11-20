#!/usr/bin/env bash
# Task 1.2 (docs/mail-vm-db-upgrade-r2.md): restore the R2 nextdp_mail snapshot into a SIDE-BY-SIDE
# database (default nextdp_mail_r2). Never touches the live nextdp_mail DB or the services.
# Restic password + R2 keys are unsealed in memory from nextmanager_core.backup_targets (port 5433)
# with JWT_SECRET from the nmc-main env file. Nothing secret is printed.
set -Eeuo pipefail
exec 2>&1  # PowerShell 5.1 treats remote stderr (psql NOTICEs) as terminating errors

ENV_FILE="${NMC_ENV_FILE:-/tmp/.nmc-main-env}"
SNAPSHOT_ID="${SNAPSHOT_ID:-689c5e6a}"
TARGET_DB="${TARGET_DB:-nextdp_mail_r2}"
REUSE_DUMP="${REUSE_DUMP:-1}"
KEEP_DIR="/var/backups/nextdp/r2-${SNAPSHOT_ID}"
DUMP="${KEEP_DIR}/nextdp_mail.dump"
TMP_JSON="$(mktemp /tmp/nmc-targets.XXXXXX.json)"
PG_TMP="/tmp/.r2-mail-restore-$$.dump"
cleanup() { rm -f "$ENV_FILE" "$TMP_JSON"; sudo rm -f "$PG_TMP"; }
trap cleanup EXIT

case "$TARGET_DB" in
  nextdp_mail) echo "FATAL: refusing to restore over the live nextdp_mail" >&2; exit 1 ;;
  nextdp_mail_*) ;;
  *) echo "FATAL: TARGET_DB must start with nextdp_mail_" >&2; exit 1 ;;
esac
cd /tmp

if [ "$REUSE_DUMP" = "1" ] && sudo test -s "$DUMP"; then
  echo "=== [1/3] Reusing existing dump $DUMP ==="
else
  [ -f "$ENV_FILE" ] || { echo "FATAL: nmc-main env file missing: $ENV_FILE" >&2; exit 1; }
  pg_lsclusters | awk '$2=="nmcmain"{print $4}' | grep -q online || { echo "FATAL: cluster 16/nmcmain is not online" >&2; exit 1; }
  sudo install -d -m 0750 -o root -g ubuntu /var/backups/nextdp "$KEEP_DIR"
  sudo -u postgres psql -p 5433 -d nextmanager_core -XAt -c "
    SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json)::text FROM (
      SELECT name, driver, endpoint, region, bucket, prefix,
             encode(credentials_enc,'hex') AS creds_hex, encode(repo_password_enc,'hex') AS pw_hex
      FROM backup_targets ORDER BY created_at) t;" > "$TMP_JSON"
  chmod 600 "$TMP_JSON"

  echo "=== [1/3] restic dump of snapshot ${SNAPSHOT_ID} ==="
  WORK_DUMP="$(mktemp /var/tmp/r2-mail.XXXXXX.dump)"
  NMC_ENV_FILE="$ENV_FILE" NMC_TARGETS_JSON="$TMP_JSON" SNAPSHOT_ID="$SNAPSHOT_ID" OUT_DUMP="$WORK_DUMP" python3 - <<'PY'
import json, os, subprocess, tempfile, shutil
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

def jwt_secret(path):
    with open(path, encoding="utf-8-sig", errors="replace") as fh:
        for raw in fh:
            line = raw.strip()
            if line.startswith("JWT_SECRET=") :
                return line.split("=", 1)[1].strip().strip('"').strip("'")
    raise SystemExit("FATAL: JWT_SECRET not found")

key = HKDF(algorithm=hashes.SHA256(), length=32, salt=None,
           info=b"nextmanager-core/app-env/v1").derive(jwt_secret(os.environ["NMC_ENV_FILE"]).encode())
def unseal(h):
    b = bytes.fromhex(h)
    return AESGCM(key).decrypt(b[1:13], b[13:], b"\x01").decode()

snap = os.environ["SNAPSHOT_ID"]
cache = tempfile.mkdtemp(prefix="restic-cache-")
try:
    for t in json.load(open(os.environ["NMC_TARGETS_JSON"])):
        env = os.environ.copy()
        for k in ("NMC_ENV_FILE", "NMC_TARGETS_JSON"):
            env.pop(k, None)
        creds = json.loads(unseal(t["creds_hex"]))
        prefix = (t.get("prefix") or "").strip("/")
        env.update({
            "RESTIC_REPOSITORY": f"s3:{(t.get('endpoint') or '').rstrip('/')}/{t['bucket']}" + (f"/{prefix}" if prefix else ""),
            "RESTIC_PASSWORD": unseal(t["pw_hex"]),
            "RESTIC_CACHE_DIR": cache,
            "AWS_ACCESS_KEY_ID": creds.get("access_key_id", ""),
            "AWS_SECRET_ACCESS_KEY": creds.get("secret_access_key", ""),
        })
        if t.get("region"):
            env["AWS_DEFAULT_REGION"] = t["region"]
        ls = subprocess.run(["restic", "ls", "--no-lock", "--json", snap], env=env, capture_output=True, text=True, timeout=120)
        if ls.returncode != 0:
            print(f"  target {t['name']}: snapshot not found here")
            continue
        snap_meta, paths = None, []
        for line in ls.stdout.splitlines():
            o = json.loads(line)
            if o.get("struct_type") == "snapshot" or o.get("message_type") == "snapshot":
                snap_meta = o
            elif o.get("type") == "file" and o.get("path", "").endswith(".dump"):
                paths.append((o["path"], o.get("size", 0)))
        if snap_meta:
            print(f"  target={t['name']} snapshot={snap} time={snap_meta.get('time')} host={snap_meta.get('hostname')} tags={snap_meta.get('tags')}")
        if len(paths) != 1:
            raise SystemExit(f"FATAL: expected exactly 1 .dump in snapshot, found {paths}")
        path, size = paths[0]
        print(f"  dump file: {path} ({size} bytes)")
        with open(os.environ["OUT_DUMP"], "wb") as out:
            r = subprocess.run(["restic", "dump", "--no-lock", snap, path], env=env, stdout=out, stderr=subprocess.PIPE, timeout=900)
        if r.returncode != 0:
            raise SystemExit(f"FATAL: restic dump failed rc={r.returncode}")
        got = os.path.getsize(os.environ["OUT_DUMP"])
        if size and got != size:
            raise SystemExit(f"FATAL: size mismatch {got} != {size}")
        print(f"  restic dump OK ({got} bytes)")
        break
    else:
        raise SystemExit("FATAL: snapshot not found in any backup target")
finally:
    shutil.rmtree(cache, ignore_errors=True)
PY
  sudo install -o root -g ubuntu -m 0640 "$WORK_DUMP" "$DUMP"
  rm -f "$WORK_DUMP"
  (cd "$KEEP_DIR" && sudo sh -c 'sha256sum nextdp_mail.dump > SHA256SUMS')
  sudo chown root:ubuntu "$KEEP_DIR/SHA256SUMS"; sudo chmod 0640 "$KEEP_DIR/SHA256SUMS"
fi
sudo cat "$KEEP_DIR/SHA256SUMS" 2>/dev/null || true
echo "  toc entries: $(sudo pg_restore --list "$DUMP" | grep -vc '^;')"

echo "=== [2/3] (Re)create ${TARGET_DB} and pg_restore (live nextdp_mail untouched) ==="
sudo -u postgres psql -p 5432 -Xq -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${TARGET_DB}';" >/dev/null
sudo -u postgres psql -p 5432 -Xq -c "DROP DATABASE IF EXISTS ${TARGET_DB};"
sudo -u postgres psql -p 5432 -Xq -c "CREATE DATABASE ${TARGET_DB} OWNER nextdp_mail;"
sudo install -o postgres -g postgres -m 0600 "$DUMP" "$PG_TMP"
set +e
sudo -u postgres pg_restore -p 5432 -d "$TARGET_DB" --no-owner --no-acl --role=nextdp_mail "$PG_TMP" 2>/tmp/.r2-restore-err.$$
rc=$?
set -e
sudo rm -f "$PG_TMP"
echo "  pg_restore rc=${rc}, error lines=$(grep -c 'error' /tmp/.r2-restore-err.$$ || true)"
grep -i 'error' /tmp/.r2-restore-err.$$ | head -10 || true
rm -f /tmp/.r2-restore-err.$$
sudo -u postgres psql -p 5432 -d "$TARGET_DB" -Xq -c "GRANT ALL ON SCHEMA public TO nextdp_mail;"

echo "=== [3/3] ${TARGET_DB}: rows / max(id) / max(created_at) per table ==="
Q() { sudo -u postgres psql -p 5432 -d "$TARGET_DB" -XAt "$@"; }
for t in $(Q -c "SELECT table_name FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE' ORDER BY 1"); do
  hid=$(Q -c "SELECT count(*) FROM information_schema.columns WHERE table_schema='public' AND table_name='$t' AND column_name='id'")
  hca=$(Q -c "SELECT count(*) FROM information_schema.columns WHERE table_schema='public' AND table_name='$t' AND column_name='created_at'")
  idx=NULL; [ "$hid" = 1 ] && idx="max(id)::text"
  cax=NULL; [ "$hca" = 1 ] && cax="max(created_at)::text"
  Q -c "SELECT '$t', count(*), $idx, $cax FROM \"$t\""
done | column -t -s'|'
echo "STAGED_DB=${TARGET_DB}"
