#!/usr/bin/env bash
# Runs on Recovery-VM as root. Exports one inspected (mounted read-only) Azure disk into /work/out/$DISK and the bucket
# (docs/azure-disk-archive.md §3). STEP = pg | env | code | files | upload | all (pg env code files upload, in order).
#   pg    : every PostgreSQL data dir on the disk -> copy to /work/pg/$DISK/<n> -> temporary cluster on a private
#           socket (never the disk) -> pg_dump -Fc per database + roles (no passwords) + meta (sizes, rows) -> stop, delete copy
#   env   : /etc, /root and every env / key / certificate file under /srv /opt /var/www /home -> env.tar.zst.gpg (AES256)
#   code  : /srv/<group>/<app>, /srv/<x>, /opt/<x>, /var/www/<x> -> code/<path>.tar.zst  (no node_modules; env / key
#           files left out: they are in env)
#   files : /var/lib (without postgresql) incl. mysql raw files, /var/backups, /home, /usr/local -> files/*.tar.zst
#           + loose *.dump / *.sql files in /var/lib/postgresql -> files/var-lib-postgresql-dumps.tar.zst
#   upload: MANIFEST.sha256 + inspect.txt, rclone copy to archive:$R2_BUCKET/$DISK/, rclone check --download (byte compare)
#   data  : for a disk WITHOUT an OS (NTFS workstation drive, MinIO data disk): every mounted partition, per top-level
#           folder -> data/<path>.tar.zst; a folder bigger than DATA_LIMIT_MB (2048) is split per subfolder (down to
#           DATA_MAXDEPTH 4 levels), its loose files -> data/<path>/_files.tar.zst. Secret files (.env*, *.pem, *.key,
#           keystores, ssh keys, credentials*, service-account JSONs) and folders private-data/ _secrets/ go only into
#           env.tar.zst.gpg (names in env-filelist.txt). Unreadable files are listed in data-warnings.txt.
#           STEP=all on a disk without /etc/os-release runs data + upload.
set -Eeuo pipefail
exec 2>&1
DISK="${DISK:?}"; STEP="${STEP:-all}"
[ "$(id -u)" = 0 ] || { echo "FATAL: run as root"; exit 1; }
[[ "$DISK" =~ ^[A-Za-z0-9_.-]+$ ]] || { echo "FATAL: bad disk name"; exit 1; }
set -a; . /root/.r2-azure-archive.env; set +a
OUT=/work/out/$DISK; mkdir -p "$OUT"; chmod 700 "$OUT"
ROOT=""
for m in /work/disks/$DISK/mnt/*; do [ -f "$m/etc/os-release" ] && ROOT=$m; done
if [ -z "$ROOT" ]; then
  [ "$STEP" = all ] && STEP=data+upload
  [[ "$STEP" =~ ^(data|data\+upload|upload)$ ]] || { echo "FATAL: no mounted root filesystem for $DISK (run 02-disk -Mode inspect; a data disk uses STEP=data)"; exit 1; }
fi
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
  # loose manual dumps next to the clusters (e.g. /var/lib/postgresql/<db>-pre-<x>.dump): var-lib above skips that folder
  local pgx; pgx=$(cd "$ROOT" && find var/lib/postgresql -maxdepth 2 -type f \( -name '*.dump' -o -name '*.sql' -o -name '*.sql.gz' -o -name '*.backup' \) 2>/dev/null || true)
  if [ -n "$pgx" ]; then
    tar -C "$ROOT" -cf - $pgx | $ZST > "$OUT/files/var-lib-postgresql-dumps.tar.zst"
    log "  files/var-lib-postgresql-dumps.tar.zst $(du -h "$OUT/files/var-lib-postgresql-dumps.tar.zst" | cut -f1) ($(echo "$pgx" | wc -l) files)"
  fi
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

step_data() {
  local limit_mb=${DATA_LIMIT_MB:-2048} max_depth=${DATA_MAXDEPTH:-3}
  local warn="$OUT/data-warnings.txt"; : > "$warn"
  local -a d_sec=("${SECRET_EXCL[@]}" --exclude='.env.*' --exclude='private-data' --exclude='_secrets' --exclude='*.jks' --exclude='*.keystore' --exclude='credentials*' --exclude='*service-account*' --exclude='*firebase*')
  local -a d_junk=("${JUNK_EXCL[@]}" --exclude='$RECYCLE.BIN' --exclude='System Volume Information' --exclude='.pnpm-store')
  local -a parts=()
  for m in /work/disks/$DISK/mnt/*; do mountpoint -q "$m" && parts+=("$m"); done
  [ "${#parts[@]}" -gt 0 ] || { echo "FATAL: no mounted partitions for $DISK (run 02-disk -Mode inspect)"; exit 1; }

  # 1. Secrets across all mounted partitions -> env.tar.zst.gpg
  log "data/env: collecting secrets"
  local list="/work/tmp/$DISK-env.list"; mkdir -p /work/tmp; : > "$list"
  for m in "${parts[@]}"; do
    local pfx=""; [ "${#parts[@]}" -gt 1 ] && pfx="$(basename "$m")/"
    ( cd "$m" && find . \( -path './$RECYCLE.BIN' -o -path './System Volume Information' -o -name node_modules -o -name .pnpm-store \) -prune -o \
        \( -type d \( -iname 'private-data' -o -iname '_secrets' \) -prune -print \) -o \
        \( -type f \( -iname '.env' -o -iname '*.env' -o -iname '.env.*' -o -iname 'env' -o -iname '*.pem' -o -iname '*.key' \
           -o -iname 'privkey*' -o -iname '*.p12' -o -iname '*.pfx' -o -iname '*.jks' -o -iname '*.keystore' \
           -o -iname 'id_rsa*' -o -iname 'id_ed25519*' -o -iname 'credentials*' -o -iname '*service-account*' -o -iname '*firebase*' \) -print \) \
        2>/dev/null || true ) | sed "s|^\./|$pfx|" >> "$list"
  done
  log "data/env: $(wc -l < "$list") entries"
  if [ "${#parts[@]}" -eq 1 ]; then
    tar -C "${parts[0]}" -cf - --ignore-failed-read -T "$list" 2>>"$warn" | $ZST | \
      gpg --batch --yes --quiet --pinentry-mode loopback --passphrase-fd 3 --symmetric --cipher-algo AES256 --compress-algo none \
        -o "$OUT/env.tar.zst.gpg" 3< <(printf '%s' "$ARCHIVE_PASSPHRASE")
  else
    tar -C "/work/disks/$DISK/mnt" -cf - --ignore-failed-read -T "$list" 2>>"$warn" | $ZST | \
      gpg --batch --yes --quiet --pinentry-mode loopback --passphrase-fd 3 --symmetric --cipher-algo AES256 --compress-algo none \
        -o "$OUT/env.tar.zst.gpg" 3< <(printf '%s' "$ARCHIVE_PASSPHRASE")
  fi
  cp "$list" "$OUT/env-filelist.txt"; rm -f "$list"
  log "data/env: $(du -h "$OUT/env.tar.zst.gpg" | cut -f1) (encrypted)"

  # Helper: pack one dir, splitting if > limit_mb and depth < max_depth
  pack_data_dir() {
    local base=$1 rel=$2 out_rel=$3 depth=$4
    local sz_mb; sz_mb=$(du -sm "$base/$rel" 2>/dev/null | cut -f1 || echo 0)
    if [ "$depth" -ge "$max_depth" ] || [ "${sz_mb:-0}" -le "$limit_mb" ]; then
      mkdir -p "$(dirname "$OUT/data/$out_rel")"
      tar -C "$base" -cf - --ignore-failed-read "${d_junk[@]}" "${d_sec[@]}" "$rel" 2>>"$warn" | $ZST > "$OUT/data/$out_rel.tar.zst"
      log "  data/$out_rel.tar.zst $(du -h "$OUT/data/$out_rel.tar.zst" | cut -f1) (from ${sz_mb}M)"
      return
    fi
    # Split: loose files at this level + recurse per subdir
    local -a topfiles=()
    while IFS= read -r -d '' f; do
      local bn; bn=$(basename "$f")
      case "$bn" in .env|*.env|.env.*|env|*.pem|*.key|privkey*|*.p12|*.pfx|*.jks|*.keystore|id_rsa*|id_ed25519*|credentials*|*service-account*|*firebase*) continue ;; esac
      topfiles+=("$rel/$bn")
    done < <(find "$base/$rel" -maxdepth 1 \( -type f -o -type l \) -print0 2>/dev/null)
    if [ "${#topfiles[@]}" -gt 0 ]; then
      mkdir -p "$OUT/data/$out_rel"
      tar -C "$base" -cf - --ignore-failed-read "${topfiles[@]}" 2>>"$warn" | $ZST > "$OUT/data/$out_rel/_files.tar.zst"
      log "  data/$out_rel/_files.tar.zst $(du -h "$OUT/data/$out_rel/_files.tar.zst" | cut -f1)"
    fi
    while IFS= read -r -d '' sub; do
      local bn; bn=$(basename "$sub")
      case "$bn" in '$RECYCLE.BIN'|'System Volume Information'|node_modules|.pnpm-store|private-data|_secrets) continue ;; esac
      pack_data_dir "$base" "$rel/$bn" "$out_rel/$bn" $((depth+1))
    done < <(find "$base/$rel" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null | sort -z)
  }

  # 2. Walk each mounted partition
  for m in "${parts[@]}"; do
    local pfx=""; [ "${#parts[@]}" -gt 1 ] && pfx="$(basename "$m")/"
    log "data: packing $m"
    local -a rootfiles=()
    while IFS= read -r -d '' entry; do
      local bn; bn=$(basename "$entry")
      case "$bn" in '$RECYCLE.BIN'|'System Volume Information'|node_modules|.pnpm-store|private-data|_secrets) continue ;; esac
      if [ -d "$entry" ]; then
        pack_data_dir "$m" "$bn" "${pfx}${bn}" 1
      elif [ -f "$entry" ]; then
        case "$bn" in
          *.zip|*.7z|*.rar|*.tar|*.tar.gz|*.tgz|*.tar.zst)
            mkdir -p "$OUT/data/$(dirname "${pfx}${bn}")"
            gpg --batch --yes --quiet --pinentry-mode loopback --passphrase-fd 3 --symmetric --cipher-algo AES256 --compress-algo none \
              -o "$OUT/data/${pfx}${bn}.gpg" "$entry" 3< <(printf '%s' "$ARCHIVE_PASSPHRASE")
            log "  data/${pfx}${bn}.gpg $(du -h "$OUT/data/${pfx}${bn}.gpg" | cut -f1) (encrypted archive)"
            ;;
          .env|*.env|.env.*|env|*.pem|*.key|privkey*|*.p12|*.pfx|*.jks|*.keystore|id_rsa*|id_ed25519*|credentials*|*service-account*|*firebase*) ;;
          *) rootfiles+=("$bn") ;;
        esac
      fi
    done < <(find "$m" -mindepth 1 -maxdepth 1 -print0 2>/dev/null | sort -z)
    if [ "${#rootfiles[@]}" -gt 0 ]; then
      mkdir -p "$OUT/data/${pfx%/}"
      tar -C "$m" -cf - --ignore-failed-read "${rootfiles[@]}" 2>>"$warn" | $ZST > "$OUT/data/${pfx}_root_files.tar.zst"
      log "  data/${pfx}_root_files.tar.zst $(du -h "$OUT/data/${pfx}_root_files.tar.zst" | cut -f1)"
    fi
  done
  [ -s "$warn" ] || rm -f "$warn"
}

case "$STEP" in
  pg) step_pg ;; env) step_env ;; code) step_code ;; files) step_files ;; data) step_data ;; upload) step_upload ;;
  "data+upload") step_data; step_upload ;;
  all) step_pg; step_env; step_code; step_files; step_upload ;;
  *) echo "FATAL: unknown STEP"; exit 1 ;;
esac
log "EXPORT $STEP DONE"
