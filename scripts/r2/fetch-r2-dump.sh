#!/usr/bin/env bash
# Runs on the Mail VM (the only VM with the recovered NMC DB, cluster 16/nmcmain on port 5433).
# Unseals the old NMC restic repo (R2 nxtmngr-test/prod-main) in memory and either lists the
# latest snapshot per backup plan (MODE=list) or extracts one database dump (MODE=dump) into
# OUT_DIR as <db>.dump + SHA256SUMS + meta.txt. Read-only on R2 (--no-lock). Never prints secrets.
#
# Env: NMC_ENV_FILE (0600 copy of private-data/nmc-main-env.txt, deleted on exit)
#      MODE=list|dump, DB_NAME (dump), SNAPSHOT_ID (optional, default = latest of the DB's plan),
#      OUT_DIR (dump), STOP_NMC_AFTER=1 (stop cluster nmcmain at the end; doc rule)
set -Eeuo pipefail
exec 2>&1

ENV_FILE="${NMC_ENV_FILE:?NMC_ENV_FILE must be set}"
MODE="${MODE:-dump}"
DB_NAME="${DB_NAME:-}"
SNAPSHOT_ID="${SNAPSHOT_ID:-}"
OUT_DIR="${OUT_DIR:-}"
STOP_NMC_AFTER="${STOP_NMC_AFTER:-1}"
TMP_JSON="$(mktemp /tmp/nmc-targets.XXXXXX.json)"

nmc_online() { pg_lsclusters | awk '$2=="nmcmain"{print $4}' | grep -q online; }
cleanup() {
  rm -f "$ENV_FILE" "$TMP_JSON"
  if [ "$STOP_NMC_AFTER" = "1" ] && nmc_online; then
    sudo pg_ctlcluster 16 nmcmain stop && echo "  cluster 16/nmcmain stopped"
  fi
}
trap cleanup EXIT

case "$MODE" in
  list) ;;
  dump)
    [[ "$DB_NAME" =~ ^[a-z][a-z0-9_]{1,62}$ ]] || { echo "FATAL: invalid DB_NAME '$DB_NAME'"; exit 1; }
    [[ -z "$SNAPSHOT_ID" || "$SNAPSHOT_ID" =~ ^[0-9a-f]{8,64}$ ]] || { echo "FATAL: invalid SNAPSHOT_ID"; exit 1; }
    [[ "$OUT_DIR" == /var/tmp/r2-fetch-* ]] || { echo "FATAL: OUT_DIR must be /var/tmp/r2-fetch-*"; exit 1; }
    ;;
  *) echo "FATAL: MODE must be list or dump"; exit 1 ;;
esac
[ -s "$ENV_FILE" ] || { echo "FATAL: nmc-main env file missing: $ENV_FILE"; exit 1; }
command -v restic >/dev/null || { echo "FATAL: restic not installed"; exit 1; }
cd /tmp

if ! nmc_online; then
  echo "  starting cluster 16/nmcmain (port 5433) for the unseal step"
  sudo pg_ctlcluster 16 nmcmain start
fi
sudo -u postgres psql -p 5433 -d nextmanager_core -XAt -c "
  SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json)::text FROM (
    SELECT name, driver, endpoint, region, bucket, prefix,
           encode(credentials_enc,'hex') AS creds_hex, encode(repo_password_enc,'hex') AS pw_hex
    FROM backup_targets ORDER BY created_at) t;" > "$TMP_JSON"
chmod 600 "$TMP_JSON"
# Map plan id (restic tag plan:<id>) -> plan name + database name (selector holds the database id).
PLANS_TSV="$(sudo -u postgres psql -p 5433 -d nextmanager_core -XAt -F$'\t' -c "
  SELECT p.id, p.name, COALESCE(d.name, '') FROM backup_plans p
  LEFT JOIN databases d ON p.kind = 'db' AND d.id::text = p.selector->>'database_id'
  ORDER BY p.name;")"
# The unseal needs only the targets; stop the cluster now to free RAM.
if [ "$STOP_NMC_AFTER" = "1" ]; then sudo pg_ctlcluster 16 nmcmain stop && echo "  cluster 16/nmcmain stopped (unseal data read)"; fi

if [ "$MODE" = "dump" ]; then
  install -d -m 0700 "$OUT_DIR"
fi

NMC_ENV_FILE="$ENV_FILE" NMC_TARGETS_JSON="$TMP_JSON" PLANS_TSV="$PLANS_TSV" MODE="$MODE" \
DB_NAME="$DB_NAME" SNAPSHOT_ID="$SNAPSHOT_ID" OUT_DIR="$OUT_DIR" python3 - <<'PY'
import hashlib, json, os, re, shutil, subprocess, tempfile
from datetime import datetime, timedelta, timezone
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

RESTIC = shutil.which("restic")
MODE, DB, SNAP, OUT = (os.environ[k] for k in ("MODE", "DB_NAME", "SNAPSHOT_ID", "OUT_DIR"))
IST = timezone(timedelta(hours=5, minutes=30))

def jwt_secret(path):
    with open(path, encoding="utf-8-sig", errors="replace") as fh:
        for raw in fh:
            line = raw.strip()
            if line.startswith("JWT_SECRET="):
                return line.split("=", 1)[1].strip().strip('"').strip("'")
    raise SystemExit("FATAL: JWT_SECRET not found in the nmc-main env file")

key = HKDF(algorithm=hashes.SHA256(), length=32, salt=None,
           info=b"nextmanager-core/app-env/v1").derive(jwt_secret(os.environ["NMC_ENV_FILE"]).encode())

def unseal(h):
    b = bytes.fromhex(h)
    return AESGCM(key).decrypt(b[1:13], b[13:], b"\x01").decode()

def ist(ts):
    if not ts:
        return "-"
    return datetime.fromisoformat(ts.replace("Z", "+00:00")).astimezone(IST).strftime("%Y-%m-%d %H:%M IST")

plans = {}  # plan id -> (plan name, database name)
for row in os.environ["PLANS_TSV"].splitlines():
    parts = row.split("\t")
    if len(parts) == 3:
        plans[parts[0]] = (parts[1], parts[2])

def plan_name(pid):
    return plans.get(pid, (f"(deleted plan {pid[:8]})", ""))[0]

def db_of(pid):
    name, db = plans.get(pid, ("", ""))
    if db:
        return db
    m = re.match(r"^[a-z0-9]+-db-(.+)-daily$", name)  # fallback: <prefix>-db-<db-name>-daily
    return m.group(1).replace("-", "_") if m else ""

cache = tempfile.mkdtemp(prefix="restic-cache-")
try:
    found = False
    for t in json.load(open(os.environ["NMC_TARGETS_JSON"])):
        creds = json.loads(unseal(t["creds_hex"]))
        prefix = (t.get("prefix") or "").strip("/")
        env = {k: v for k, v in os.environ.items() if k not in ("NMC_ENV_FILE", "NMC_TARGETS_JSON", "PLANS_TSV")}
        env.update({
            "RESTIC_REPOSITORY": f"s3:{(t.get('endpoint') or '').rstrip('/')}/{t['bucket']}" + (f"/{prefix}" if prefix else ""),
            "RESTIC_PASSWORD": unseal(t["pw_hex"]),
            "RESTIC_CACHE_DIR": cache,
            "AWS_ACCESS_KEY_ID": creds.get("access_key_id", ""),
            "AWS_SECRET_ACCESS_KEY": creds.get("secret_access_key", ""),
        })
        if t.get("region"):
            env["AWS_DEFAULT_REGION"] = t["region"]
        sn = subprocess.run([RESTIC, "snapshots", "--no-lock", "--json"], env=env, capture_output=True, text=True, timeout=180)
        if sn.returncode != 0:
            print(f"  target {t['name']}: restic snapshots failed rc={sn.returncode}")
            continue
        snaps = sorted(json.loads(sn.stdout or "[]"), key=lambda s: s.get("time", ""), reverse=True)
        latest = {}
        for s in snaps:
            plan = next((x[5:] for x in (s.get("tags") or []) if x.startswith("plan:")), "")
            if plan and plan not in latest:
                latest[plan] = s
        print(f"  target={t['name']} bucket={t['bucket']} prefix={prefix} snapshots={len(snaps)} plans={len(latest)}")

        if MODE == "list":
            print(f"  {'database':<20} {'snapshot':<9} {'time':<21} {'host':<16} plan")
            for plan, s in sorted(latest.items(), key=lambda kv: db_of(kv[0])):
                print(f"  {db_of(plan) or '-':<20} {s['short_id']:<9} {ist(s.get('time','')):<21} {s.get('hostname',''):<16} {plan_name(plan)}")
            found = True
            continue

        if SNAP:
            snap = next((s for s in snaps if s["id"].startswith(SNAP)), None)
            if not snap:
                print(f"  target {t['name']}: snapshot {SNAP} not here")
                continue
        else:
            cands = [p for p in latest if db_of(p) == DB]
            if len(cands) != 1:
                raise SystemExit(f"FATAL: expected 1 backup plan for database {DB}, found {[plan_name(p) for p in cands]}")
            snap = latest[cands[0]]
        plan = next((x[5:] for x in (snap.get("tags") or []) if x.startswith("plan:")), "")
        if db_of(plan) and db_of(plan) != DB:
            raise SystemExit(f"FATAL: snapshot {snap['short_id']} belongs to plan {plan_name(plan)} (database {db_of(plan)}), not {DB}")
        ls = subprocess.run([RESTIC, "ls", "--no-lock", "--json", snap["id"]], env=env, capture_output=True, text=True, timeout=180)
        if ls.returncode != 0:
            raise SystemExit(f"FATAL: restic ls failed rc={ls.returncode}")
        files = [(o["path"], o.get("size", 0)) for o in map(json.loads, ls.stdout.splitlines())
                 if o.get("type") == "file" and o.get("path", "").endswith(".dump")]
        if len(files) != 1:
            raise SystemExit(f"FATAL: expected exactly 1 .dump in snapshot {snap['short_id']}, found {files}")
        path, size = files[0]
        out_dump = os.path.join(OUT, f"{DB}.dump")
        print(f"  snapshot={snap['short_id']} time={ist(snap.get('time',''))} host={snap.get('hostname')} plan={plan_name(plan)}")
        print(f"  restic dump {path} ({size} bytes) ...")
        with open(out_dump, "wb") as fh:
            r = subprocess.run([RESTIC, "dump", "--no-lock", snap["id"], path], env=env, stdout=fh, stderr=subprocess.PIPE, timeout=1800)
        if r.returncode != 0:
            raise SystemExit(f"FATAL: restic dump failed rc={r.returncode}")
        got = os.path.getsize(out_dump)
        if size and got != size:
            raise SystemExit(f"FATAL: size mismatch {got} != {size}")
        h = hashlib.sha256()
        with open(out_dump, "rb") as fh:
            for chunk in iter(lambda: fh.read(1 << 20), b""):
                h.update(chunk)
        with open(os.path.join(OUT, "SHA256SUMS"), "w") as fh:
            fh.write(f"{h.hexdigest()}  {DB}.dump\n")
        with open(os.path.join(OUT, "meta.txt"), "w") as fh:
            fh.write("\n".join([
                f"DB_NAME={DB}", f"SNAPSHOT_ID={snap['short_id']}", f"SNAPSHOT_FULL_ID={snap['id']}",
                f"SNAPSHOT_TIME_UTC={snap.get('time','')}", f"SNAPSHOT_TIME_IST={ist(snap.get('time',''))}",
                f"SOURCE_HOST={snap.get('hostname','')}", f"PLAN={plan_name(plan)}", f"REPO_PATH={path}",
                f"DUMP_BYTES={got}", f"SHA256={h.hexdigest()}", ""]))
        print(f"  dump OK: {got} bytes, sha256 {h.hexdigest()[:16]}...")
        found = True
        break
    if not found:
        raise SystemExit("FATAL: nothing found in any backup target")
finally:
    shutil.rmtree(cache, ignore_errors=True)
PY

if [ "$MODE" = "dump" ]; then
  echo "  toc entries: $(pg_restore --list "$OUT_DIR/$DB_NAME.dump" | grep -vc '^;')"
fi
