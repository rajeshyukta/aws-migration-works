#!/usr/bin/env bash
# Runs on LocalCen-1-VM. Loads LocalCen's official place packs (#21, LGD) the way LocalCen's deploy/geo-import.sh does:
# packs -> /srv/apps/localcen/shared/geo-packs/<name>, `localcen geo import` (sha256 checked, upsert, never deletes),
# `localcen geo status`. localcen_db is dumped first. PACKS_DIR holds one folder per pack (manifest.json, *.csv.gz).
set -Eeuo pipefail
exec 2>&1
PACKS_DIR="${PACKS_DIR:?}"; MODE="${MODE:-check}"
APP=/srv/apps/localcen; ENV_FILE=$APP/shared/.env
trap 'sudo rm -rf "$PACKS_DIR"' EXIT
run() { (cd $APP/current && sudo -u webapps bash -c "set -a; . '$ENV_FILE'; set +a; ./localcen $*") 2>&1 | grep -vE 'no .env file|DB_SSL_MODE|"level":"INFO"'; }
echo "== packs"
for d in "$PACKS_DIR"/*/; do
  n=$(basename "$d"); sudo test -f "$d/manifest.json" || { echo "FATAL: $n has no manifest.json"; exit 1; }
  echo "  $n: $(sudo python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); print(m.get("state_name",""), m.get("snapshot",""), m.get("counts",""))' "$d/manifest.json" | cut -c1-200)"
done
echo "== now"; run geo status
[ "$MODE" = "apply" ] || { echo "CHECK DONE (nothing written)"; exit 0; }
TS=$(date -u +%Y%m%dT%H%M%SZ); BK=/var/backups/localcen/pre-geo-import-$TS
sudo mkdir -p $BK && sudo chmod 700 $BK
sudo -u postgres pg_dump -Fc -d localcen_db | sudo tee $BK/localcen_db.dump >/dev/null
echo "backup: $BK/localcen_db.dump ($(sudo du -h $BK/localcen_db.dump | cut -f1))"
sudo install -d -m 755 -o webapps -g webapps $APP/shared/geo-packs
dirs=()
for d in "$PACKS_DIR"/*/; do
  n=$(basename "$d"); sudo rm -rf "$APP/shared/geo-packs/$n"; sudo cp -r "$d" "$APP/shared/geo-packs/$n"
  sudo chown -R webapps:webapps "$APP/shared/geo-packs/$n"; dirs+=("$APP/shared/geo-packs/$n")
done
echo "== import"; run geo import "${dirs[@]}"
echo "== after"; run geo status
echo "APPLY DONE"
