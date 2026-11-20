#!/usr/bin/env bash
# Task 0.2 (docs/mail-vm-db-upgrade-r2.md): recover the NextDP Mail storage tree from the
# Azure disk nmc-mail-1-osdisk on the Mail VM. MODE = download | inspect | extract | cleanup.
# The SAS link is read from a 0600 file and never printed (AzCopy output is also scrubbed).
set -Eeuo pipefail

MODE="${MODE:?MODE required}"
SAS_FILE="${SAS_FILE:-/tmp/.mail1.sas}"
WORK="/var/tmp/azure-mail1"
VHD="${WORK}/nmc-mail-1.vhd"
MNT="/mnt/mail1"
DISK_GB="${DISK_GB:-30}"
EXPECTED=$(( DISK_GB * 1024 * 1024 * 1024 + 512 ))
OUT_DIR="/var/backups/nextdp"
scrub() { sed -E 's/(sig|se|st|sp|sv|sr|skoid|sktid|skt|ske|sks|skv)=[^& "]*/\1=REDACTED/g'; }

loopdev() { losetup -j "$VHD" 2>/dev/null | cut -d: -f1 | head -1; }

case "$MODE" in
download)
  trap 'rm -f "$SAS_FILE"' EXIT
  [ -s "$SAS_FILE" ] || { echo "FATAL: SAS file missing: $SAS_FILE" >&2; exit 1; }
  sudo install -d -m 0750 -o ubuntu -g ubuntu "$WORK" "$WORK/logs" "$WORK/plans"
  if ! command -v azcopy >/dev/null 2>&1; then
    echo "=== Installing AzCopy v10 (Microsoft) ==="
    tmp="$(mktemp -d)"
    curl -fsSL https://aka.ms/downloadazcopy-v10-linux -o "$tmp/azcopy.tgz"
    tar -xzf "$tmp/azcopy.tgz" -C "$tmp" --strip-components=1
    sudo install -m 0755 "$tmp/azcopy" /usr/local/bin/azcopy
    rm -rf "$tmp"
  fi
  azcopy --version
  df -h / | tail -1
  echo "=== Downloading nmc-mail-1-osdisk -> $VHD ==="
  export AZCOPY_LOG_LOCATION="$WORK/logs" AZCOPY_JOB_PLAN_LOCATION="$WORK/plans"
  # Keep memory low: the Mail VM has 2 GB RAM and runs production services.
  export AZCOPY_BUFFER_GB=0.25 AZCOPY_CONCURRENCY_VALUE=16
  start=$(date +%s)
  azcopy copy "$(cat "$SAS_FILE")" "$VHD" --check-length=true --log-level=WARNING 2>&1 \
    | tr '\r' '\n' | scrub | grep -vE '^\s*$' | awk 'NR%20==1 || /Final|Elapsed|Number of|Total|Failed|Skipped|Error|error/' || true
  rm -f "$SAS_FILE"
  echo "  elapsed: $(( $(date +%s) - start ))s"
  ;&
verify)
  [ -f "$VHD" ] || { echo "FATAL: $VHD missing" >&2; exit 1; }
  size=$(stat -c%s "$VHD")
  footer=$(tail -c 512 "$VHD" | head -c 8 || true)
  echo "  size=${size} expected=${EXPECTED} footer='${footer}'"
  # Azure images can be the nominal size plus 1 MiB alignment; require >= nominal, MiB-aligned, valid footer.
  raw=$(( size - 512 ))
  [ "$footer" = "conectix" ] && [ "$size" -ge "$EXPECTED" ] && [ $(( raw % 1048576 )) -eq 0 ] \
    || { echo "FATAL: VHD size/footer check failed" >&2; exit 1; }
  echo "  allocated on disk: $(du -h "$VHD" | cut -f1)"
  echo "VHD_OK"
  ;;
inspect)
  dev="$(loopdev)"
  if [ -z "$dev" ]; then
    dev=$(sudo losetup -r -P --sizelimit $(( $(stat -c%s "$VHD") - 512 )) -f --show "$VHD")
  fi
  echo "loop device: $dev"
  sleep 1
  lsblk -o NAME,SIZE,FSTYPE,LABEL "$dev"
  if ! mountpoint -q "$MNT"; then
    part=$(lsblk -lnpo NAME,FSTYPE,SIZE -b "$dev" | awk '$2=="ext4"{print $3, $1}' | sort -n | tail -1 | cut -d' ' -f2)
    [ -n "$part" ] || { echo "FATAL: no ext4 partition found" >&2; exit 1; }
    sudo mkdir -p "$MNT"
    sudo mount -o ro,noload "$part" "$MNT"
    echo "mounted $part at $MNT (read-only)"
  fi
  echo "=== OS / services ==="
  grep -E '^(PRETTY_NAME)=' "$MNT/etc/os-release" || true
  ls "$MNT/etc/systemd/system" | grep -iE 'nextdp|mail' || true
  echo "=== candidate app dirs ==="
  sudo ls -la "$MNT/opt" "$MNT/srv" "$MNT/srv/apps" 2>/dev/null || true
  echo "=== STORAGE settings in app .env files (non-secret keys only) ==="
  sudo find "$MNT/opt" "$MNT/srv" "$MNT/etc" -maxdepth 5 \( -name '.env' -o -name '*.env' \) 2>/dev/null | while read -r f; do
    echo "--- ${f#$MNT}"
    sudo grep -E '^(STORAGE_DRIVER|STORAGE_PATH|STORAGE_LOCAL_PATH|STORAGE_S3_ENDPOINT|STORAGE_S3_BUCKET|STORAGE_BUCKET|DB_HOST|DB_NAME|APP_URL)=' "$f" || true
  done
  echo "=== where .eml files live ==="
  sudo find "$MNT" -xdev -name '*.eml' -printf '%h\n' 2>/dev/null | sed -E 's#(/emails)/.*#\1#' | sort | uniq -c
  sudo find "$MNT" -xdev -name '*.eml' -printf '%TY-%Tm\n' 2>/dev/null | sort | uniq -c
  echo "=== storage dirs size ==="
  sudo find "$MNT" -xdev -type d \( -name uploads -o -name storage \) -path '*nextdp*' -prune -print 2>/dev/null | while read -r d; do sudo du -sh "$d"; done
  echo "=== local postgres? ==="
  sudo ls "$MNT/var/lib/postgresql" 2>/dev/null || echo "none"
  ;;
extract)
  SRC="${SRC_DIR:?SRC_DIR (storage dir inside the mount) required}"
  mountpoint -q "$MNT" || { echo "FATAL: $MNT not mounted (run inspect first)" >&2; exit 1; }
  [ -d "$MNT$SRC" ] || { echo "FATAL: $MNT$SRC not found" >&2; exit 1; }
  OUT="${OUT_DIR}/azure-mail1-storage.tar.gz"
  echo "=== tar $SRC (emails, attachments, bimi, uploads) -> $OUT ==="
  members=()
  for sub in emails attachments bimi uploads; do
    [ -e "$MNT$SRC/$sub" ] && members+=("$sub")
  done
  [ "${#members[@]}" -gt 0 ] || { echo "FATAL: no storage subdirs in $SRC" >&2; exit 1; }
  sudo tar -czf "$OUT" -C "$MNT$SRC" "${members[@]}"
  sudo chown root:ubuntu "$OUT"; sudo chmod 0640 "$OUT"
  (cd "$OUT_DIR" && sha256sum "$(basename "$OUT")" | sudo tee "${OUT}.sha256" >/dev/null)
  sudo chown root:ubuntu "${OUT}.sha256"; sudo chmod 0640 "${OUT}.sha256"
  echo "  members: ${members[*]}"
  echo "  size: $(stat -c%s "$OUT") bytes"
  echo "  files: $(tar -tzf "$OUT" | grep -vc '/$')  eml: $(tar -tzf "$OUT" | grep -c '\.eml$' || true)"
  cat "${OUT}.sha256"
  ;;
cleanup)
  mountpoint -q "$MNT" && sudo umount "$MNT"
  dev="$(loopdev)"; [ -n "$dev" ] && sudo losetup -d "$dev"
  sudo rm -rf "$WORK"
  rm -f "$SAS_FILE"
  echo "cleaned: unmounted, loop detached, $WORK removed"
  df -h / | tail -1
  ;;
*) echo "FATAL: unknown MODE $MODE" >&2; exit 1 ;;
esac
