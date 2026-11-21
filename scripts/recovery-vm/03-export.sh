#!/usr/bin/env bash
# Runs on Recovery-VM as root. Exports one inspected (mounted read-only) Azure disk into /work/out/$DISK and the bucket
# (docs/azure-disk-archive.md §3). STEP = pg | env | code | files | upload | all (pg env code files upload, in order).
#   pg    : every PostgreSQL data dir on the disk -> copy to /work/pg/$DISK/<n> -> temporary cluster on a private
#           socket (never the disk) -> pg_dump -Fc per database + roles (no passwords) + meta (sizes, rows) -> stop, delete copy
#   env   : /etc, /root and every env / key / certificate file under /srv /opt /var/www /home -> env.tar.zst.gpg (AES256)
#   code  : /srv/<group>/<app>, /srv/<x>, /opt/<x>, /var/www/<x> -> code/<path>.tar.zst  (no node_modules; env / key
#           files left out: they are in env)
#   files : /var/lib (without postgresql) incl. mysql raw files, /var/backups, /home, /usr/local -> files/*.tar.zst
#   upload: MANIFEST.sha256 + inspect.txt, rclone copy to archive:$R2_BUCKET/$DISK/, rclone check --download (byte compare)
set -Eeuo pipefail
exec 2>&1
DISK="${DISK:?}"; STEP="${STEP:-all}"
[ "$(id -u)" = 0 ] || { echo "FATAL: run as root"; exit 1; }
[[ "$DISK" =~ ^[A-Za-z0-9_.-]+$ ]] || { echo "FATAL: bad disk name"; exit 1; }
set -a; . /root/.r2-azure-archive.env; set +a
OUT=/work/out/$DISK; mkdir -p "$OUT"; chmod 700 "$OUT"
ROOT=""
for m in /work/disks/$DISK/mnt/*; do [ -f "$m/etc/os-release" ] && ROOT=$m; done
[ -n "$ROOT" ] || { echo "FATAL: no mounted root filesystem for $DISK (run 02-disk -Mode inspect)"; exit 1; }
PGBIN=/usr/lib/postgresql/16/bin
ZST="zstd -T0 -10 -q"
SECRET_EXCL=(--exclude='.env' --exclude='*.env' --exclude='env' --exclude='*.pem' --exclude='*.key' --exclude='privkey*' --exclude='*.p12' --exclude='*.pfx' --exclude='id_rsa*' --exclude='id_ed25519*')
JUNK_EXCL=(--exclude='node_modules' --exclude='.cache' --exclude='*.sock')
log() { echo "[$(date -u +%H:%M:%S)] $*"; }

step_pg() {
  local n=0
  while read -r verfile; do
    local src; src=$(dirname "$verfile"); local ver; ver=$(cat "$verfile")
    n=$((n+1)); local name; name=$(echo "${src#$ROOT/}" | tr '/' '_')
    log "pg: $name (v$ver, $(du -sh "$src" | cut -f1))"
    [ "$ver" = 16 ] || { log "  SKIP: only PostgreSQL 16 binaries here (install postgresql-$ver to dump it)"; continue; }
    local work=/work/pg/$DISK/$name sock=/work/pg/$DISK/sock-$n port=$((55430+n))
    mkdir -p /work/pg; chmod 755 /work/pg; rm -rf "$work"; mkdir -p "$work" "$sock"
    cp -a "$src/." "$work/"
    rm -f "$work/postmaster.pid" "$work/postmaster.opts"
    : > "$work/postgresql.conf"; printf 'local all all trust\n' > "$work/pg_hba.conf"; : > "$work/pg_ident.conf"
    chown -R postgres:postgres /work/pg/$DISK; chmod 700 "$work"
    sudo -u postgres $PGBIN/pg_ctl -D "$work" -w -t 300 -l "/work/pg/$DISK/$name.log" \
      -o "-p $port -k $sock -c listen_addresses='' -c config_file=$work/postgresql.conf -c hba_file=$work/pg_hba.conf -c ident_file=$work/pg_ident.conf -c data_directory=$work" start >/dev/null \
      || { tail -20 "/work/pg/$DISK/$name.log"; echo "FATAL: temporary cluster did not start"; exit 1; }
    local q="sudo -u postgres $PGBIN/psql -h $sock -p $port -d postgres -At -v ON_ERROR_STOP=1"
    local dst=$OUT/db/$name; mkdir -p "$dst"
    { echo "source: ${src#$ROOT} on $DISK"; echo "version: $($q -c 'select version()')"; echo "dumped: $(date -u +%FT%TZ)"; } > "$dst/meta.txt"
    sudo -u postgres $PGBIN/pg_dumpall -h $sock -p $port --globals-only --no-role-passwords > "$dst/globals-roles.sql"
    for db in $($q -c "select datname from pg_database where datallowconn and datname not in ('template0','template1') order by 1"); do
      sudo -u postgres $PGBIN/pg_dump -h $sock -p $port -Fc -Z 6 -d "$db" -f "/work/pg/$DISK/$db.dump"
      mv "/work/pg/$DISK/$db.dump" "$dst/$db.dump"
      local sz rows tables
      sz=$($q -c "select pg_size_pretty(pg_database_size('$db'))")
      read -r tables rows < <(sudo -u postgres $PGBIN/psql -h $sock -p $port -d "$db" -At -F ' ' -c "select count(*), coalesce(sum(n_live_tup),0) from pg_stat_user_tables")
      echo "db: $db size=$sz tables=$tables rows~$rows dump=$(du -h "$dst/$db.dump" | cut -f1)" | tee -a "$dst/meta.txt"
    done
    sudo -u postgres $PGBIN/pg_ctl -D "$work" -m fast stop >/dev/null
    rm -rf "$work" "$sock"
  done < <(find "$ROOT/var/lib/postgresql" "$ROOT/srv" "$ROOT/opt" -maxdepth 5 -name PG_VERSION -not -path '*/base/*' 2>/dev/null)
  rm -rf /work/pg/$DISK
  log "pg: $n cluster(s)"
}

step_env() {
  log "env: collecting"
  local list=/work/tmp/$DISK-env.list; : > "$list"
  ( cd "$ROOT" && for d in etc root; do [ -d "$d" ] && echo "$d"; done ) >> "$list"
  ( cd "$ROOT" && find srv opt var/www home var/lib/caddy -type f \( -name '.env' -o -name '*.env' -o -name 'env' -o -name '*.pem' -o -name '*.key' \
      -o -name 'privkey*' -o -name '*.p12' -o -name '*.pfx' -o -name 'id_rsa*' -o -name 'id_ed25519*' -o -name 'credentials*' \) \
      -not -path '*/node_modules/*' 2>/dev/null || true ) >> "$list"   # a folder this disk does not have is fine
  log "env: $(wc -l < "$list") entries (etc, root + files)"
  tar -C "$ROOT" -cf - --ignore-failed-read -T "$list" | $ZST | \
    gpg --batch --yes --quiet --pinentry-mode loopback --passphrase-fd 3 --symmetric --cipher-algo AES256 --compress-algo none \
      -o "$OUT/env.tar.zst.gpg" 3< <(printf '%s' "$ARCHIVE_PASSPHRASE")
  cp "$list" "$OUT/env-filelist.txt"; rm -f "$list"
  log "env: $(du -h "$OUT/env.tar.zst.gpg" | cut -f1) (encrypted)"
}

pack() { # <relative path> <archive name> [extra tar args...]
  local rel=$1 name=$2; shift 2
  mkdir -p "$(dirname "$OUT/$name")"
  tar -C "$ROOT" -cf - --ignore-failed-read "${JUNK_EXCL[@]}" "$@" "$rel" | $ZST > "$OUT/$name"
  log "  $name $(du -h "$OUT/$name" | cut -f1) (from $(du -sh "$ROOT/$rel" 2>/dev/null | cut -f1))"
}

step_code() {
  log "code"
  [ -d "$ROOT/srv" ] && for x in "$ROOT"/srv/*; do
    [ -e "$x" ] || continue; local b; b=$(basename "$x")
    if [ -d "$x" ] && [[ "$b" =~ ^(apps|phpapps|goapps|static|sites|www)$ ]]; then
      for y in "$x"/*; do [ -e "$y" ] && pack "srv/$b/$(basename "$y")" "code/srv/$b/$(basename "$y").tar.zst" "${SECRET_EXCL[@]}"; done
    else
      pack "srv/$b" "code/srv/$b.tar.zst" "${SECRET_EXCL[@]}"
    fi
  done
  for top in opt var/www; do
    [ -d "$ROOT/$top" ] || continue
    for y in "$ROOT/$top"/*; do [ -e "$y" ] && pack "$top/$(basename "$y")" "code/$(echo "$top" | tr '/' '_')/$(basename "$y").tar.zst" "${SECRET_EXCL[@]}"; done
  done
}

step_files() {
  log "files"
  [ -d "$ROOT/var/lib" ] && pack var/lib files/var-lib.tar.zst --exclude='var/lib/postgresql' --exclude='var/lib/snapd' --exclude='var/lib/apt' --exclude='var/lib/dpkg' "${SECRET_EXCL[@]}"
  for x in var/backups home usr/local; do [ -d "$ROOT/$x" ] && pack "$x" "files/$(echo "$x" | tr '/' '-').tar.zst" "${SECRET_EXCL[@]}"; done
}

step_upload() {
  log "upload"
  cp "/work/out/$DISK/inspect.txt" "$OUT/inspect.txt" 2>/dev/null || true
  ( cd "$OUT" && find . -type f ! -name MANIFEST.sha256 -print0 | sort -z | xargs -0 sha256sum > MANIFEST.sha256 )
  log "  $(wc -l < "$OUT/MANIFEST.sha256") files, $(du -sh "$OUT" | cut -f1)"
  rclone copy "$OUT" "archive:$R2_BUCKET/$DISK" --transfers 8 --checkers 16 --s3-upload-concurrency 8 --stats 0
  rclone check "$OUT" "archive:$R2_BUCKET/$DISK" --download --one-way 2>&1 | tail -3
  log "  bucket now: $(rclone size --json "archive:$R2_BUCKET/$DISK" | jq -r '"\(.count) objects, \(.bytes/1048576|floor) MiB"')"
}

case "$STEP" in
  pg) step_pg ;; env) step_env ;; code) step_code ;; files) step_files ;; upload) step_upload ;;
  all) step_pg; step_env; step_code; step_files; step_upload ;;
  *) echo "FATAL: unknown STEP"; exit 1 ;;
esac
log "EXPORT $STEP DONE"
