#!/usr/bin/env bash
# Runs on Recovery-VM (16.4.71.66). One-time, repeatable setup for the Azure disk archive (docs/azure-disk-archive.md):
#   1. the 250 GB work volume (the empty NVMe disk that is not the root disk) -> ext4, label "work", /work (fstab nofail)
#   2. tools: PostgreSQL 16 server binaries (no cluster is created or started), AzCopy v10, rclone, gnupg, zstd, ntfs-3g
#   3. rclone remote "archive" for the R2 bucket from /root/.r2-azure-archive.env (installed by 01-setup.ps1)
#   4. bucket test: write, read back, compare, delete one small object
# Prints no secret values.
set -Eeuo pipefail
exec 2>&1
ENV=/root/.r2-azure-archive.env
sudo test -s $ENV || { echo "FATAL: $ENV missing"; exit 1; }

echo "== 1. work volume"
if ! mountpoint -q /work; then
  ROOTDISK=$(lsblk -no PKNAME "$(findmnt -no SOURCE /)")
  DEV=""
  for d in $(lsblk -dno NAME,TYPE | awk '$2=="disk"{print $1}'); do
    [ "$d" = "$ROOTDISK" ] && continue
    if [ -z "$(lsblk -no FSTYPE /dev/$d | tr -d '[:space:]')" ] && [ "$(lsblk -no NAME /dev/$d | wc -l)" = "1" ]; then DEV=/dev/$d; fi
  done
  if [ -z "$DEV" ]; then
    DEV=$(blkid -L work || true)
    [ -n "$DEV" ] || { echo "FATAL: no empty data disk and no filesystem labelled 'work'"; lsblk; exit 1; }
  else
    echo "  formatting $DEV ($(lsblk -dno SIZE $DEV)) as ext4 'work'"
    sudo mkfs.ext4 -q -L work -m 0 "$DEV"
  fi
  sudo mkdir -p /work
  grep -q 'LABEL=work' /etc/fstab || echo 'LABEL=work /work ext4 defaults,noatime,nofail 0 2' | sudo tee -a /etc/fstab >/dev/null
  sudo systemctl daemon-reload
  sudo mount /work
fi
sudo mkdir -p /work/disks /work/out /work/tmp
sudo chmod 700 /work/disks /work/out /work/tmp
echo "  $(df -h /work | tail -1)"

echo "== 2. tools"
export DEBIAN_FRONTEND=noninteractive
need=()
for p in postgresql-16 postgresql-client-16 gnupg zstd ntfs-3g pv jq unzip; do dpkg -s $p >/dev/null 2>&1 || need+=($p); done
if [ ${#need[@]} -gt 0 ]; then
  sudo apt-get update -qq
  sudo apt-get install -y -qq --no-install-recommends "${need[@]}" >/dev/null
fi
# The package creates and starts a default cluster; this VM never serves one.
if systemctl list-unit-files postgresql.service >/dev/null 2>&1; then sudo systemctl disable --now -q postgresql 2>/dev/null || true; fi
if pg_lsclusters -h 2>/dev/null | grep -q '^16 *main'; then
  sudo pg_ctlcluster 16 main stop 2>/dev/null || true
  sudo pg_dropcluster 16 main
fi
if ! command -v azcopy >/dev/null; then
  t=$(mktemp -d); curl -fsSL https://aka.ms/downloadazcopy-v10-linux -o $t/a.tgz
  tar -xzf $t/a.tgz -C $t --strip-components=1; sudo install -m 0755 $t/azcopy /usr/local/bin/azcopy; rm -rf $t
fi
if ! command -v rclone >/dev/null; then
  t=$(mktemp -d); curl -fsSL https://downloads.rclone.org/rclone-current-linux-amd64.zip -o $t/r.zip
  unzip -q $t/r.zip -d $t; sudo install -m 0755 $t/rclone-*-linux-amd64/rclone /usr/local/bin/rclone; rm -rf $t
fi
echo "  postgres $(/usr/lib/postgresql/16/bin/postgres --version | awk '{print $3}') | $(azcopy --version | head -1) | $(rclone version | head -1) | $(gpg --version | head -1)"

echo "== 3. rclone remote 'archive' (R2, root-only config)"
sudo bash -c '
set -a; . '"$ENV"'; set +a
umask 077; mkdir -p /root/.config/rclone
cat > /root/.config/rclone/rclone.conf <<EOF
[archive]
type = s3
provider = Cloudflare
access_key_id = ${R2_ACCESS_KEY_ID}
secret_access_key = ${R2_SECRET_ACCESS_KEY}
endpoint = ${R2_ENDPOINT}
acl = private
no_check_bucket = true
EOF
echo "  bucket: ${R2_BUCKET}"'

echo "== 4. bucket test (write / read / compare / delete)"
sudo bash -c '
set -euo pipefail
set -a; . '"$ENV"'; set +a
f=$(mktemp); head -c 1048576 /dev/urandom > $f; sum=$(sha256sum $f | cut -d" " -f1)
obj="archive:${R2_BUCKET}/_setup-test/$(hostname)-$(date -u +%Y%m%dT%H%M%SZ).bin"
rclone copyto $f "$obj"
got=$(rclone cat "$obj" | sha256sum | cut -d" " -f1)
rclone deletefile "$obj"
rm -f $f
[ "$sum" = "$got" ] && echo "  write/read OK (1 MiB, sha256 match), test object deleted" || { echo "FATAL: read-back mismatch"; exit 1; }
echo "  objects in bucket: $(rclone size --json "archive:${R2_BUCKET}" | jq -r .count)"'
echo "SETUP DONE"
