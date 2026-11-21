#!/usr/bin/env bash
# Runs on Recovery-VM. One Azure disk, step by step (docs/azure-disk-archive.md). DISK=<azure disk name>, MODE:
#   download : AzCopy the VHD from the read SAS in SAS_FILE (0600, deleted after) -> /work/disks/$DISK/disk.vhd (sparse)
#   inspect  : attach read-only, mount every partition read-only under /work/disks/$DISK/mnt/pN, report what is there
#              (PostgreSQL data dirs + versions, app / web / env locations, sizes) -> /work/out/$DISK/inspect.txt
#   export   : (02-disk-export.sh, separate)
#   umount   : unmount + detach (keeps the VHD)
#   cleanup  : umount + delete the VHD and everything under /work/disks/$DISK (the exports in /work/out stay)
# Never writes to the disk image: loop devices are read-only, ext4 is mounted ro,noload, NTFS ro.
set -Eeuo pipefail
exec 2>&1
DISK="${DISK:?}"; MODE="${MODE:?}"
[[ "$DISK" =~ ^[A-Za-z0-9_.-]+$ ]] || { echo "FATAL: bad disk name"; exit 1; }
D=/work/disks/$DISK; VHD=$D/disk.vhd; MNT=$D/mnt; OUT=/work/out/$DISK
sudo mkdir -p "$D" "$OUT"; sudo chmod 700 "$D" "$OUT"
loopdev() { sudo losetup -j "$VHD" 2>/dev/null | cut -d: -f1 | head -1; }

do_umount() {
  if [ -d "$MNT" ]; then
    for m in $(findmnt -rn -o TARGET | grep "^$MNT/" | sort -r); do sudo umount "$m" || sudo umount -l "$m"; done
  fi
  l=$(loopdev); [ -n "$l" ] && sudo losetup -d "$l" && echo "  detached $l" || true
}

case "$MODE" in
download)
  SAS_FILE="${SAS_FILE:?}"; EXPECTED_GB="${EXPECTED_GB:?}"
  trap 'sudo rm -f "$SAS_FILE"' EXIT
  sudo test -s "$SAS_FILE" || { echo "FATAL: no SAS file"; exit 1; }
  free_gb=$(df --output=avail -BG /work | tail -1 | tr -dc 0-9)
  echo "== download $DISK (${EXPECTED_GB} GB provisioned; /work has ${free_gb} GB free; only used blocks are written)"
  sudo env AZCOPY_LOG_LOCATION=$D/logs AZCOPY_JOB_PLAN_LOCATION=$D/plans AZCOPY_CONCURRENCY_VALUE=16 AZCOPY_BUFFER_GB=1 \
    bash -c 'azcopy copy "$(cat "'"$SAS_FILE"'")" "'"$VHD"'" --check-length=true --log-level=WARNING --output-level=essential' \
    | grep -E 'Final Job Status|Total Number|Elapsed|Failed|error' || true
  size=$(sudo stat -c%s "$VHD"); footer=$(sudo tail -c 512 "$VHD" | head -c 8 || true)
  echo "  size=$((size/1024/1024/1024)) GiB footer='$footer' allocated=$(sudo du -h "$VHD" | cut -f1)"
  [ "$size" -ge $((EXPECTED_GB*1024*1024*1024)) ] && [ "$footer" = "conectix" ] || { echo "FATAL: VHD size/footer check failed"; exit 1; }
  sudo rm -rf $D/plans
  echo "VHD_OK"
  ;;
inspect)
  sudo test -s "$VHD" || { echo "FATAL: no VHD (run download)"; exit 1; }
  l=$(loopdev); [ -n "$l" ] || l=$(sudo losetup -r -P -f --show "$VHD")
  sudo partprobe "$l" 2>/dev/null || true; sleep 1
  sudo mkdir -p "$MNT"
  {
  set +e  # a report: a missing folder is information, not an error
  echo "# inspect $DISK $(date -u +%FT%TZ) loop=$l"
  sudo lsblk -o NAME,SIZE,FSTYPE,LABEL "$l"
  for p in $(lsblk -lno NAME "$l" | tail -n +2); do
    fs=$(sudo blkid -o value -s TYPE /dev/$p || true); [ -n "$fs" ] || continue
    m=$MNT/$p; sudo mkdir -p "$m"
    if ! mountpoint -q "$m"; then
      case "$fs" in
        ext4|ext3|ext2) sudo mount -o ro,noload /dev/$p "$m" ;;
        ntfs) sudo mount -t ntfs-3g -o ro /dev/$p "$m" ;;
        vfat|xfs) sudo mount -o ro${fs:+,norecovery} /dev/$p "$m" 2>/dev/null || sudo mount -o ro /dev/$p "$m" ;;
        *) echo "  $p: $fs (not mounted)"; continue ;;
      esac
    fi
    echo "## $p ($fs) used: $(df -h --output=used "$m" | tail -1 | xargs)"
  done
  for m in "$MNT"/*; do
    [ -d "$m/etc" ] || [ -d "$m/Users" ] || [ -d "$m/workspace" ] || continue
    echo "## root candidate $m"
    [ -f "$m/etc/os-release" ] && echo "os: $(. $m/etc/os-release; echo $PRETTY_NAME)"
    [ -f "$m/etc/hostname" ] && echo "hostname: $(cat $m/etc/hostname)"
    echo "-- PostgreSQL data dirs (version, size)"
    sudo find "$m/var/lib/postgresql" "$m/srv" "$m/opt" "$m/data" -maxdepth 5 -name PG_VERSION -not -path '*/base/*' 2>/dev/null | while read -r f; do
      dd=$(dirname "$f"); echo "  ${dd#$m}  v$(sudo cat "$f")  $(sudo du -sh "$dd" | cut -f1)"; done
    echo "-- MySQL / MariaDB / SQLite / Redis / MinIO"
    for x in var/lib/mysql var/lib/redis var/lib/minio data/minio; do sudo test -d "$m/$x" && echo "  /$x $(sudo du -sh "$m/$x" | cut -f1)"; done
    sudo find "$m/srv" "$m/opt" "$m/var/www" "$m/var/lib" -maxdepth 6 -type f \( -name '*.sqlite' -o -name '*.sqlite3' -o -name '*.db' \) -size +16k 2>/dev/null | head -20 | sed "s|^$m|  |"
    echo "-- top-level sizes"
    for x in etc srv opt var/www var/lib home root usr/local var/backups var/log; do sudo test -d "$m/$x" && echo "  /$x $(sudo du -sh "$m/$x" 2>/dev/null | cut -f1)"; done
    echo "-- apps (/srv/apps, /opt, /var/www)"
    for x in srv/apps opt var/www; do sudo test -d "$m/$x" && sudo ls -1 "$m/$x" | sed "s|^|  /$x/|"; done
    echo "-- env / secret files (names only)"
    sudo find "$m/etc" "$m/srv" "$m/opt" "$m/var/www" "$m/root" "$m/home" -maxdepth 6 -type f \( -name '.env' -o -name '*.env' -o -name 'env' -o -name '*.pem' -o -name '*.key' -o -name 'credentials*' \) \
      -not -path '*/node_modules/*' -not -path '*/vendor/*' -not -path '*/ssl/certs/*' 2>/dev/null | sed "s|^$m|  |" | head -80
    echo "-- systemd services added"
    sudo ls -1 "$m/etc/systemd/system" 2>/dev/null | grep -E '\.service$|\.timer$' | grep -vE '^(dbus|sshd|syslog|getty|snap)' | sed 's/^/  /'
  done
  } | sudo tee "$OUT/inspect.txt"
  ;;
umount) do_umount ;;
cleanup) do_umount; sudo rm -rf "$D"; echo "  removed $D; exports kept in $OUT"; df -h /work | tail -1 ;;
*) echo "FATAL: unknown MODE"; exit 1 ;;
esac
