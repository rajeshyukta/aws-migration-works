#!/usr/bin/env bash
# Verify backup_targets in PostgreSQL cluster nmcmain (-p 5433) using JWT_SECRET,
# test restic R2 access + repository integrity + snapshot listing + pg_restore --list usability.
# NEVER prints secrets, passwords, or raw access keys.
set -Eeuo pipefail

ENV_FILE="${NMC_ENV_FILE:-/tmp/.nmc-main-env}"
cleanup() {
  rm -f "$ENV_FILE"
}
trap cleanup EXIT

if [ ! -f "$ENV_FILE" ]; then
  echo "FATAL: nmc-main env file missing: $ENV_FILE" >&2
  exit 1
fi

echo "=== [1/4] backup_plans, latest backup_runs, nodes & databases in nmcmain (-p 5433) ==="
(cd /tmp && sudo -u postgres psql -p 5433 -d nextmanager_core -c "
SELECT p.name AS plan, p.kind, p.frequency, p.enabled, n.name AS node, t.name AS target,
       p.keep_keep_last AS k_last, p.keep_keep_daily AS k_daily, p.next_run_at
FROM backup_plans p
LEFT JOIN nodes n ON n.id = p.node_id
LEFT JOIN backup_targets t ON t.id = p.target_id
ORDER BY p.created_at;
" -c "
SELECT r.started_at, p.name AS plan, r.kind, r.status, r.snapshot_id, r.bytes_total, r.duration_s, left(coalesce(r.error,''), 80) AS err
FROM backup_runs r
LEFT JOIN backup_plans p ON p.id = r.plan_id
ORDER BY r.started_at DESC
LIMIT 20;
" -c "
SELECT d.name AS db_name, d.engine, d.role_name, n.name AS node, d.status
FROM databases d
LEFT JOIN nodes n ON n.id = d.node_id
ORDER BY n.name, d.name;
")

echo "=== [2/4] Unseal backup_targets in memory & query restic R2 snapshots ==="
TMP_HEX_JSON=$(mktemp /tmp/nmc-targets-hex.XXXXXX.json)
trap 'rm -f "$ENV_FILE" "$TMP_HEX_JSON"' EXIT

(cd /tmp && sudo -u postgres psql -p 5433 -d nextmanager_core -At -c "
SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json)::text
FROM (
  SELECT id, name, driver, endpoint, region, bucket, prefix, status, repo_id,
         encode(credentials_enc, 'hex') AS creds_hex,
         encode(repo_password_enc, 'hex') AS pw_hex
  FROM backup_targets
  ORDER BY created_at
) t;
") > "$TMP_HEX_JSON"
chmod 600 "$TMP_HEX_JSON"

NMC_ENV_FILE="$ENV_FILE" NMC_TARGETS_JSON="$TMP_HEX_JSON" python3 - <<'PY'
import json
import os
import subprocess
import tempfile
from datetime import datetime, timedelta, timezone
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

def load_jwt_secret(path: str) -> str:
    with open(path, "rt", encoding="utf-8-sig", errors="replace") as fh:
        for raw in fh:
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            if k.strip() == "JWT_SECRET":
                val = v.strip().strip('"').strip("'")
                if val:
                    return val
    raise SystemExit("FATAL: JWT_SECRET not found in nmc-main-env.txt")

def unseal(key: bytes, hex_blob: str) -> str:
    blob = bytes.fromhex(hex_blob)
    if len(blob) < 1 + 12 + 16 or blob[0] != 1:
        raise ValueError("invalid SecretBox blob version/length")
    return AESGCM(key).decrypt(blob[1:13], blob[13:], b"\x01").decode("utf-8")

def fmt_ist(iso_s: str) -> str:
    if not iso_s:
        return "-"
    dt = datetime.fromisoformat(iso_s.replace("Z", "+00:00"))
    ist = dt.astimezone(timezone(timedelta(hours=5, minutes=30), "IST"))
    return ist.strftime("%Y-%m-%d %H:%M:%S IST")

jwt_secret = load_jwt_secret(os.environ["NMC_ENV_FILE"])
if len(jwt_secret) < 32:
    raise SystemExit(f"FATAL: JWT_SECRET length {len(jwt_secret)} < 32")

box_key = HKDF(
    algorithm=hashes.SHA256(),
    length=32,
    salt=None,
    info=b"nextmanager-core/app-env/v1",
).derive(jwt_secret.encode("utf-8"))

with open(os.environ["NMC_TARGETS_JSON"], "rt", encoding="utf-8") as fh:
    targets = json.load(fh)

if not targets:
    print("No rows in backup_targets.")
    raise SystemExit(0)

RESTIC = "/usr/local/bin/restic"
cache_dir = tempfile.mkdtemp(prefix="nmc-restic-cache-")

try:
    for tgt in targets:
        print(f"\n--- Target: {tgt['name']} (driver={tgt['driver']}, bucket={tgt['bucket']}, prefix={tgt['prefix']}) ---")
        try:
            repo_pw = unseal(box_key, tgt["pw_hex"])
            creds = json.loads(unseal(box_key, tgt["creds_hex"]))
            print(f"  SecretBox decryption OK (repo_pw len={len(repo_pw)}, creds keys={sorted(creds.keys())})")
        except Exception as exc:
            print(f"  FATAL: SecretBox decryption FAILED: {exc}")
            continue

        endpoint = (tgt.get("endpoint") or "").rstrip("/")
        bucket = tgt["bucket"]
        prefix = (tgt.get("prefix") or "").strip("/")
        repo_url = f"s3:{endpoint}/{bucket}" + (f"/{prefix}" if prefix else "")
        print(f"  Repo URL: {repo_url}")

        env = os.environ.copy()
        env["RESTIC_REPOSITORY"] = repo_url
        env["RESTIC_PASSWORD"] = repo_pw
        env["RESTIC_CACHE_DIR"] = cache_dir
        if tgt["driver"] == "s3":
            env["AWS_ACCESS_KEY_ID"] = creds.get("access_key_id", "")
            env["AWS_SECRET_ACCESS_KEY"] = creds.get("secret_access_key", "")
            if tgt.get("region"):
                env["AWS_DEFAULT_REGION"] = tgt["region"]

        # 1. Optional restic check (RUN_CHECK=1; verified 698/698 clean on 2026-11-19)
        if os.environ.get("RUN_CHECK") == "1":
            print("  Running `restic check --no-lock`...")
            chk = subprocess.run([RESTIC, "check", "--no-lock"], env=env, capture_output=True, text=True, timeout=180)
            print(f"  `restic check` exit={chk.returncode}")
            for line in (chk.stdout or "").splitlines()[-6:]:
                print("   ", line)
            if chk.returncode != 0:
                for line in (chk.stderr or "").splitlines()[-8:]:
                    print("    ERR:", line)

        # 2. restic snapshots
        sn = subprocess.run([RESTIC, "snapshots", "--no-lock", "--json"], env=env, capture_output=True, text=True, timeout=60)
        if sn.returncode != 0:
            print(f"  FATAL: `restic snapshots` failed (exit={sn.returncode}): {sn.stderr.strip()}")
            continue
        snaps = json.loads(sn.stdout or "[]")
        snaps.sort(key=lambda s: s.get("time", ""), reverse=True)
        print(f"  Total snapshots in repository: {len(snaps)}")
        for s in snaps[:30]:
            sid = s.get("short_id") or s.get("id", "")[:8]
            tags = ",".join(s.get("tags") or [])
            paths = ",".join(s.get("paths") or [])
            print(f"    {sid} | {fmt_ist(s.get('time',''))} | host={s.get('hostname','')} | tags=[{tags}] | paths={paths}")

        # 3. Inspect latest snapshot per plan/database directory and test DB dump usability
        seen_groups = []
        seen_keys = set()
        for s in snaps:
            tags = s.get("tags") or []
            plan_tag = next((t for t in tags if t.startswith("plan:")), "")
            dirs = tuple(sorted(os.path.dirname(p) for p in (s.get("paths") or [])))
            key = (plan_tag, dirs) if plan_tag else (s.get("hostname", ""), dirs)
            if key not in seen_keys:
                seen_keys.add(key)
                seen_groups.append(s)

        print(f"\n=== [3/4] Latest snapshot per plan ({len(seen_groups)} distinct plans/sources) ===")
        dump_probes = []
        for s in seen_groups:
            sid = s.get("short_id") or s["id"][:8]
            tags = ",".join(s.get("tags") or [])
            print(f"\n  Snapshot {sid} ({fmt_ist(s.get('time',''))}, host={s.get('hostname','')}, tags=[{tags}]):")
            ls_p = subprocess.run([RESTIC, "ls", "--no-lock", "--long", s["id"]], env=env, capture_output=True, text=True, timeout=60)
            if ls_p.returncode != 0:
                print(f"    ls failed: {ls_p.stderr.strip()}")
                continue
            for row in ls_p.stdout.splitlines():
                if row.startswith("snapshot ") or not row.strip():
                    continue
                if row.strip().startswith("d"):
                    continue
                print("   ", row)
                parts = row.split()
                fpath = parts[-1] if parts else ""
                if fpath.endswith(".dump") or fpath.endswith(".sql") or fpath.endswith(".sql.gz") or fpath.endswith(".tar.gz"):
                    dump_probes.append((sid, s.get("hostname", ""), fmt_ist(s.get("time", "")), fpath))

        print(f"\n=== [4/4] Usability test on latest dumps ({len(dump_probes)} candidates) ===")
        for sid, host, ts_str, fpath in dump_probes[:35]:
            if fpath.endswith(".dump"):
                p1 = subprocess.Popen([RESTIC, "dump", "--no-lock", sid, fpath], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                p2 = subprocess.Popen(["pg_restore", "--list"], stdin=p1.stdout, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                p1.stdout.close()
                out2, err2 = p2.communicate(timeout=180)
                _, err1 = p1.communicate(timeout=30)
                toc_lines = [l for l in out2.decode("utf-8", "replace").splitlines() if l and not l.startswith(";")]
                ok = (p1.returncode == 0 and p2.returncode == 0 and len(toc_lines) > 0)
                print(f"  [PGDUMP] {sid} | {ts_str} | {host:<15} | {os.path.basename(os.path.dirname(fpath)) + '/' + os.path.basename(fpath):<38} -> usable={ok}, toc_entries={len(toc_lines)}")
                if not ok:
                    print(f"    restic_rc={p1.returncode} pg_restore_rc={p2.returncode} err1={err1.decode(errors='replace').strip()} err2={err2.decode(errors='replace').strip()}")
            elif fpath.endswith(".tar.gz") or fpath.endswith(".sql.gz"):
                p1 = subprocess.Popen([RESTIC, "dump", "--no-lock", sid, fpath], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                p2 = subprocess.Popen(["gzip", "-t"], stdin=p1.stdout, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                p1.stdout.close()
                _, err2 = p2.communicate(timeout=180)
                _, err1 = p1.communicate(timeout=30)
                ok = (p1.returncode == 0 and p2.returncode == 0)
                print(f"  [GZIP]   {sid} | {ts_str} | {host:<15} | {fpath} -> gzip_integrity_ok={ok}")
finally:
    import shutil
    shutil.rmtree(cache_dir, ignore_errors=True)
PY
