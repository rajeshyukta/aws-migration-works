#!/usr/bin/env bash
# Full backup of the live NextDP Mail state on the Mail VM (no downtime):
#   - pg_dump -Fc of nextdp_mail and cconsole_hub (cluster 16/main, port 5432)
#   - tar.gz of /opt/nextdp/storage
#   - root-only copy of /opt/nextdp/config/.env (stays on the VM, never downloaded)
# Output: /var/backups/nextdp/<BACKUP_TS>/ + SHA256SUMS (secrets never printed).
set -Eeuo pipefail

TS="${BACKUP_TS:-$(date -u +%Y%m%dT%H%M%SZ)}"
ROOT="/var/backups/nextdp"
DIR="${ROOT}/${TS}"
DBS="${BACKUP_DBS:-nextdp_mail cconsole_hub}"

sudo install -d -m 0750 -o root -g ubuntu "$ROOT"
sudo install -d -m 0750 -o root -g ubuntu "$DIR"
cd /tmp

echo "=== [1/4] pg_dump (custom format) -> ${DIR} ==="
for db in $DBS; do
  if ! sudo -u postgres psql -p 5432 -XAtc "SELECT 1 FROM pg_database WHERE datname='${db}'" | grep -q 1; then
    echo "  skip ${db}: database not found"
    continue
  fi
  sudo -u postgres pg_dump -p 5432 -Fc -d "$db" | sudo tee "${DIR}/${db}.dump" >/dev/null
  toc="$(sudo pg_restore --list "${DIR}/${db}.dump" | grep -vc '^;' || true)"
  echo "  ${db}.dump  $(sudo stat -c%s "${DIR}/${db}.dump") bytes, toc_entries=${toc}"
done

echo "=== [2/4] /opt/nextdp/storage -> storage.tar.gz ==="
sudo tar -czf "${DIR}/storage.tar.gz" -C /opt/nextdp storage
echo "  storage.tar.gz  $(sudo stat -c%s "${DIR}/storage.tar.gz") bytes, files=$(sudo tar -tzf "${DIR}/storage.tar.gz" | grep -vc '/$')"
echo "  .eml files in 2026-11: $(sudo tar -tzf "${DIR}/storage.tar.gz" | grep -c 'uploads/emails/.*/2026-11/.*\.eml$' || true)"

echo "=== [3/4] app .env (root-only copy, not downloaded) ==="
sudo install -m 0600 -o root -g root /opt/nextdp/config/.env "${DIR}/dot-env.root-only"
echo "  dot-env.root-only saved (0600 root)"

echo "=== [4/4] checksums ==="
(cd "$DIR" && sudo sh -c 'sha256sum *.dump storage.tar.gz > SHA256SUMS')
sudo chown root:ubuntu "$DIR"/*.dump "$DIR"/storage.tar.gz "$DIR"/SHA256SUMS
sudo chmod 0640 "$DIR"/*.dump "$DIR"/storage.tar.gz "$DIR"/SHA256SUMS
sudo cat "${DIR}/SHA256SUMS"
echo "BACKUP_DIR=${DIR}"
df -h / | tail -1
