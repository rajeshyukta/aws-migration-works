#!/usr/bin/env bash
# Runs on a helper VM with PostgreSQL 16 and enough free disk (the VHD is the full disk size).
# Gets pg_dump files out of an old Azure OS disk without touching the VM's own PostgreSQL:
#   download : AzCopy the VHD (SAS read from a 0600 file, never printed)
#   dump     : loop-mount read-only, copy the cluster's data dir, start it as a temporary
#              cluster on a private socket (no TCP), list DBs, pg_dump the DBS asked for
#   cleanup  : stop the temp cluster, unmount, detach, delete everything under WORK
# Env: MODE, DISK_NAME, DISK_GB, SAS_FILE (download), PG_CLUSTER (default 16/main), DBS (space list)
set -Eeuo pipefail
exec 2>&1

MODE="${MODE:?MODE required}"
DISK_NAME="${DISK_NAME:?DISK_NAME required}"
[[ "$DISK_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "FATAL: invalid DISK_NAME"; exit 1; }
DISK_GB="${DISK_GB:-30}"
SAS_FILE="${SAS_FILE:-}"
PG_CLUSTER="${PG_CLUSTER:-16/main}"
DBS="${DBS:-}"
WORK="/var/tmp/azure-disk-${DISK_NAME}"
VHD="${WORK}/disk.vhd"
MNT="/mnt/azure-${DISK_NAME}"
# Temp cluster lives in its own postgres-only dir (postgres cannot enter WORK, which holds the VHD).
PGROOT="/var/tmp/azure-pg-${DISK_NAME}"
PGTMP="${PGROOT}/data"
SOCK="${PGROOT}/sock"
OUT="${WORK}/out"
PORT=5439
EXPECTED=$(( DISK_GB * 1024 * 1024 * 1024 + 512 ))
scrub() { sed -E 's/(sig|se|st|sp|sv|sr|skoid|sktid|skt|ske|sks|skv)=[^& "]*/\1=REDACTED/g'; }
loopdev() { losetup -j "$VHD" 2>/dev/null | cut -d: -f1 | head -1; }
PGBIN="/usr/lib/postgresql/${PG_CLUSTER%%/*}/bin"
pg_temp_stop() { sudo test -f "$PGTMP/postmaster.pid" && sudo -u postgres "$PGBIN/pg_ctl" -D "$PGTMP" -m fast -w stop >/dev/null 2>&1 || true; }

case "$MODE" in
download)
  trap '[ -n "$SAS_FILE" ] && rm -f "$SAS_FILE"' EXIT
  [ -s "$SAS_FILE" ] || { echo "FATAL: SAS file missing"; exit 1; }
  free_kb=$(df --output=avail -k /var/tmp | tail -1)
  need_kb=$(( (DISK_GB + 3) * 1024 * 1024 ))
  [ "$free_kb" -gt "$need_kb" ] || { echo "FATAL: not enough free disk ($((free_kb/1024/1024)) GB free, need $((need_kb/1024/1024)) GB)"; exit 1; }
  sudo install -d -m 0750 -o ubuntu -g ubuntu "$WORK" "$WORK/logs" "$WORK/plans"
  if ! command -v azcopy >/dev/null 2>&1; then
    echo "=== Installing AzCopy v10 (Microsoft) ==="
    tmp="$(mktemp -d)"
    curl -fsSL https://aka.ms/downloadazcopy-v10-linux -o "$tmp/azcopy.tgz"
    tar -xzf "$tmp/azcopy.tgz" -C "$tmp" --strip-components=1
    sudo install -m 0755 "$tmp/azcopy" /usr/local/bin/azcopy
    rm -rf "$tmp"
  fi
  echo "=== Downloading ${DISK_NAME} (${DISK_GB} GB) -> $VHD ==="
  export AZCOPY_LOG_LOCATION="$WORK/logs" AZCOPY_JOB_PLAN_LOCATION="$WORK/plans" AZCOPY_BUFFER_GB=0.5 AZCOPY_CONCURRENCY_VALUE=16
  start=$(date +%s)
  azcopy copy "$(cat "$SAS_FILE")" "$VHD" --check-length=true --log-level=WARNING 2>&1 \
    | tr '\r' '\n' | scrub | grep -vE '^\s*$' | awk 'NR%20==1 || /Final|Elapsed|Number of|Total|Failed|Error|error/' || true
  rm -f "$SAS_FILE"
  echo "  elapsed: $(( $(date +%s) - start ))s"
  size=$(stat -c%s "$VHD"); footer=$(tail -c 512 "$VHD" | head -c 8 || true)
  echo "  size=${size} expected>=${EXPECTED} footer='${footer}' allocated=$(du -h "$VHD" | cut -f1)"
  [ "$footer" = "conectix" ] && [ "$size" -ge "$EXPECTED" ] && [ $(( (size - 512) % 1048576 )) -eq 0 ] \
    || { echo "FATAL: VHD size/footer check failed"; exit 1; }
  echo "VHD_OK"
  ;;
dump)
  [ -f "$VHD" ] || { echo "FATAL: $VHD missing (run download)"; exit 1; }
  dev="$(loopdev)"
  [ -n "$dev" ] || dev=$(sudo losetup -r -P --sizelimit $(( $(stat -c%s "$VHD") - 512 )) -f --show "$VHD")
  sleep 1
  if ! mountpoint -q "$MNT"; then
    part=$(lsblk -lnpo NAME,FSTYPE,SIZE -b "$dev" | awk '$2=="ext4"{print $3, $1}' | sort -n | tail -1 | cut -d' ' -f2)
    [ -n "$part" ] || { echo "FATAL: no ext4 partition"; exit 1; }
    sudo mkdir -p "$MNT"
    sudo mount -o ro,noload "$part" "$MNT"
  fi
  echo "mounted $(findmnt -no SOURCE "$MNT") at $MNT (read-only); $(grep PRETTY_NAME "$MNT/etc/os-release" | cut -d= -f2)"
  SRC="$MNT/var/lib/postgresql/$PG_CLUSTER"
  sudo test -f "$SRC/PG_VERSION" || { echo "FATAL: no cluster at /var/lib/postgresql/$PG_CLUSTER on the disk"; sudo ls "$MNT/var/lib/postgresql" 2>/dev/null; exit 1; }
  ver="$(sudo cat "$SRC/PG_VERSION")"
  [ -x "$PGBIN/postgres" ] && [ "$ver" = "${PG_CLUSTER%%/*}" ] || { echo "FATAL: disk cluster is PG $ver, local binaries $PGBIN"; exit 1; }
  pg_temp_stop
  sudo rm -rf "$PGROOT" "$WORK/pgdata" "$WORK/sock"
  sudo install -d -m 0700 -o postgres -g postgres "$PGROOT" "$PGTMP" "$SOCK"
  echo "=== copy data dir ($(sudo du -sh "$SRC" | cut -f1)) ==="
  sudo cp -a "$SRC/." "$PGTMP/"
  sudo rm -f "$PGTMP/postmaster.pid" "$PGTMP/postmaster.opts"
  sudo chown -R postgres:postgres "$PGTMP"
  # Own minimal config: unix socket in WORK only, no TCP, trust only on that socket.
  sudo -u postgres tee "$SOCK/temp.conf" >/dev/null <<EOF
port = $PORT
listen_addresses = ''
unix_socket_directories = '$SOCK'
hba_file = '$SOCK/temp_hba.conf'
ident_file = '$SOCK/temp_ident.conf'
shared_buffers = 64MB
max_connections = 10
archive_mode = off
EOF
  echo "local all all trust" | sudo -u postgres tee "$SOCK/temp_hba.conf" >/dev/null
  sudo -u postgres touch "$SOCK/temp_ident.conf"
  sudo -u postgres "$PGBIN/pg_ctl" -D "$PGTMP" -l "$PGROOT/pg.log" -o "-c config_file=$SOCK/temp.conf" -w -t 120 start >/dev/null \
    || { echo "FATAL: temp cluster did not start"; sudo tail -20 "$PGROOT/pg.log"; exit 1; }
  checkpoint="$(sudo -u postgres "$PGBIN/pg_controldata" "$PGTMP" | sed -n 's/^Time of latest checkpoint: *//p')"
  echo "temp cluster up (PG $ver), last checkpoint on the Azure disk: $checkpoint"
  P() { sudo -u postgres psql -h "$SOCK" -p "$PORT" -XAt "$@"; }
  echo "=== databases on the disk ==="
  P -d postgres -F' ' -c "SELECT datname, pg_size_pretty(pg_database_size(datname)) FROM pg_database WHERE NOT datistemplate ORDER BY 1"
  sudo install -d -m 0750 -o ubuntu -g ubuntu "$OUT"
  for db in $DBS; do
    [[ "$db" =~ ^[a-z][a-z0-9_]*$ ]] || { echo "FATAL: invalid db $db"; exit 1; }
    d="$OUT/$db"; install -d -m 0700 "$d"
    sudo -u postgres pg_dump -h "$SOCK" -p "$PORT" -Fc "$db" | cat > "$d/$db.dump"
    sum=$(sha256sum "$d/$db.dump" | cut -d' ' -f1)
    echo "$sum  $db.dump" > "$d/SHA256SUMS"
    printf '%s\n' "DB_NAME=$db" "SNAPSHOT_ID=azure-$(date -u -d "$checkpoint" +%Y%m%d 2>/dev/null || echo disk)" \
      "SNAPSHOT_TIME_UTC=$(date -u -d "$checkpoint" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)" \
      "SNAPSHOT_TIME_IST=$(TZ=Asia/Kolkata date -d "$checkpoint" '+%Y-%m-%d %H:%M IST' 2>/dev/null || echo unknown)" \
      "SOURCE_HOST=$DISK_NAME" "PLAN=azure-disk-pgdump" "REPO_PATH=/var/lib/postgresql/$PG_CLUSTER" \
      "DUMP_BYTES=$(stat -c%s "$d/$db.dump")" "SHA256=$sum" > "$d/meta.txt"
    echo "  dumped $db: $(stat -c%s "$d/$db.dump") bytes, toc $(pg_restore --list "$d/$db.dump" | grep -vc '^;')"
  done
  pg_temp_stop
  sudo rm -rf "$PGROOT"
  echo "DUMPS_IN=$OUT"
  ;;
cleanup)
  pg_temp_stop
  mountpoint -q "$MNT" && sudo umount "$MNT"
  dev="$(loopdev)"; [ -n "$dev" ] && sudo losetup -d "$dev"
  sudo rmdir "$MNT" 2>/dev/null || true
  sudo rm -rf "$WORK" "$PGROOT"
  [ -n "$SAS_FILE" ] && rm -f "$SAS_FILE"
  echo "cleaned: temp cluster stopped, unmounted, loop detached, $WORK removed; $(df -h / | tail -1 | awk '{print $4" free"}')"
  ;;
*) echo "FATAL: unknown MODE $MODE"; exit 1 ;;
esac
