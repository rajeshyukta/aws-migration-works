#!/usr/bin/env bash
# Inspect Cloudflare R2 bucket (nxtmngr-test) without echoing any credentials.
set -euo pipefail

ENV_FILE="${R2_ENV_FILE:-/tmp/.r2.env}"
cleanup() {
  rm -f "$ENV_FILE"
}
trap cleanup EXIT

if [ ! -f "$ENV_FILE" ]; then
  echo "FATAL: R2 env file missing: $ENV_FILE" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source <(tr -d '\r' < "$ENV_FILE")
set +a

[ -n "${R2_BUCKET_OVERRIDE:-}" ] && R2_BUCKET="$R2_BUCKET_OVERRIDE"
[ -n "${R2_ENDPOINT_OVERRIDE:-}" ] && R2_ENDPOINT="$R2_ENDPOINT_OVERRIDE"

if [ -z "${R2_ENDPOINT:-}" ] && [ -n "${R2_ACCOUNT_ID:-}" ]; then
  R2_ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
fi
R2_BUCKET="${R2_BUCKET:-nxtmngr-test}"
# Normalize pasted Cloudflare S3 URLs like https://<id>.r2.cloudflarestorage.com/<bucket>
R2_ENDPOINT="$(python3 -c 'import sys; from urllib.parse import urlparse; raw=sys.argv[1].strip(); u=urlparse(raw); print((u.scheme+"://"+u.netloc) if u.scheme and u.netloc else raw.rstrip("/"))' "${R2_ENDPOINT:-}")"

if [ -z "${R2_ENDPOINT:-}" ] || [ -z "${R2_ACCESS_KEY_ID:-}" ] || [ -z "${R2_SECRET_ACCESS_KEY:-}" ]; then
  echo "FATAL: R2_ENDPOINT/R2_ACCOUNT_ID, R2_ACCESS_KEY_ID, and R2_SECRET_ACCESS_KEY are required." >&2
  exit 1
fi

export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION="auto"
export R2_ENDPOINT R2_BUCKET

echo "=== [1/2] Inspect R2 bucket structure (boto3, read-only) ==="
PREFIXES=$(python3 - <<'PY'
import os, boto3

s3 = boto3.client(
    "s3",
    endpoint_url=os.environ["R2_ENDPOINT"],
    aws_access_key_id=os.environ["AWS_ACCESS_KEY_ID"],
    aws_secret_access_key=os.environ["AWS_SECRET_ACCESS_KEY"],
    region_name="auto",
)
bucket = os.environ["R2_BUCKET"]

resp = s3.list_objects_v2(Bucket=bucket, Delimiter="/")
prefixes = [p["Prefix"].rstrip("/") for p in resp.get("CommonPrefixes", [])]
root_objs = resp.get("Contents", [])

print(f"Bucket: {bucket}")
print(f"Top-level prefixes ({len(prefixes)}): {', '.join(prefixes) if prefixes else '(none)'}")
if root_objs:
    print(f"Root objects ({len(root_objs)}):")
    for o in root_objs[:20]:
        print(f"  {o['Key']}  ({o['Size']} bytes, {o['LastModified']})")

restic_prefixes = []
for pref in (prefixes or [""]):
    p_arg = f"{pref}/" if pref else ""
    paginator = s3.get_paginator("list_objects_v2")
    total = 0
    total_bytes = 0
    has_config = False
    snaps = []
    raw_candidates = []
    latest_mod = None
    for page in paginator.paginate(Bucket=bucket, Prefix=p_arg):
        for o in page.get("Contents", []):
            total += 1
            total_bytes += o["Size"]
            if latest_mod is None or o["LastModified"] > latest_mod:
                latest_mod = o["LastModified"]
            k = o["Key"]
            rel = k[len(p_arg):] if p_arg and k.startswith(p_arg) else k
            if rel == "config":
                has_config = True
            elif rel.startswith("snapshots/"):
                snaps.append((k, o["Size"], str(o["LastModified"])))
            elif any(rel.lower().endswith(ext) for ext in (".dump", ".sql", ".zip", ".tar.gz", ".gz")):
                raw_candidates.append((k, o["Size"], str(o["LastModified"])))

    label = pref if pref else "<root>"
    print(f"\nPrefix [{label}]: objects={total}, bytes={total_bytes}, latest={latest_mod}, restic_config={has_config}, snapshots_objects={len(snaps)}")
    if raw_candidates:
        print("  Unencrypted dump/archive candidates:")
        for k, sz, lm in sorted(raw_candidates, key=lambda x: x[2], reverse=True)[:30]:
            print(f"    {k}  ({sz} bytes, {lm})")
    if snaps:
        print("  Latest snapshot objects:")
        for k, sz, lm in sorted(snaps, key=lambda x: x[2], reverse=True)[:25]:
            print(f"    {k}  ({sz} bytes, {lm})")
    if has_config and pref:
        restic_prefixes.append(pref)

print("RESTIC_PREFIXES=" + ",".join(restic_prefixes))
PY
)
echo "$PREFIXES"

echo ""
echo "=== [2/2] Restic decryption check ==="
REPO_LIST="$(echo "$PREFIXES" | awk -F= '/^RESTIC_PREFIXES=/{print $2}')"
if [ -z "${RESTIC_PASSWORD:-}" ]; then
  echo "RESTIC_PASSWORD is empty in r2.env; skipping restic unlock. (Only encrypted restic objects exist unless listed above.)"
  exit 0
fi

export RESTIC_PASSWORD
HOST_ONLY="${R2_ENDPOINT#https://}"
HOST_ONLY="${HOST_ONLY#http://}"
HOST_ONLY="${HOST_ONLY%/}"

IFS=',' read -ra ARR <<< "$REPO_LIST"
for pref in "${ARR[@]}"; do
  [ -z "$pref" ] && continue
  export RESTIC_REPOSITORY="s3:${HOST_ONLY}/${R2_BUCKET}/${pref}"
  echo "--- restic snapshots for prefix '${pref}' ---"
  if restic snapshots --no-lock --compact 2>&1; then
    echo "UNLOCKED: ${pref}"
  else
    echo "FAILED to unlock restic prefix '${pref}' with provided RESTIC_PASSWORD."
  fi
done
