#!/usr/bin/env bash
# Install a LocalCen release on LocalCen-1-VM (:8092, dedicated Caddy). Repeatable: unpack -> migrate -> flip
# `current` -> restart -> health check -> rollback on failure. Needs shared/.env (from 02-copy-localcen-data).
set -Eeuo pipefail
exec 2>&1
STAGE_DIR="${STAGE_DIR:?}"
APP=/srv/apps/localcen
ENV_FILE=$APP/shared/.env
TS=$(date -u +%Y%m%dT%H%M%S)
REL=$APP/releases/$TS
PREV=$(readlink -f "$APP/current" 2>/dev/null || true)
trap 'rm -rf "$STAGE_DIR"' EXIT
[ -s "$STAGE_DIR/localcen-release.tar.gz" ] || { echo "FATAL: release tarball missing" >&2; exit 1; }
sudo test -f "$ENV_FILE" || { echo "FATAL: $ENV_FILE missing (run 02-copy-localcen-data first)" >&2; exit 1; }
cd /tmp

echo "=== [1/5] unpack -> $REL ==="
sudo mkdir -p "$REL"
sudo tar -xzf "$STAGE_DIR/localcen-release.tar.gz" -C "$REL"
sudo chown -R webapps:webapps "$REL"; sudo chmod -R u=rwX,go=rX "$REL"; sudo chmod 755 "$REL/localcen"
sudo ls "$REL" | paste -sd' '

echo "=== [2/5] systemd units ==="
for kind in serve work; do
  unit=localcen; desc="LocalCen service"; cmd="serve"
  if [ "$kind" = work ]; then unit=localcen-worker; desc="LocalCen queue worker"; cmd="work -q default --timeout 60 -w 2"; fi
  sudo tee /etc/systemd/system/$unit.service >/dev/null <<EOF
# Managed by aws-setup-and-migrations/scripts/localcen-1-vm/03-deploy-localcen.sh
[Unit]
Description=$desc
After=network-online.target postgresql.service
Wants=postgresql.service

[Service]
User=webapps
Group=webapps
WorkingDirectory=$APP/current
ExecStart=$APP/current/localcen $cmd
EnvironmentFile=$ENV_FILE
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=$APP/shared/storage $APP/shared/lang $APP/shared/certs
ProtectKernelTunables=true
ProtectControlGroups=true
RestrictSUIDSGID=true

[Install]
WantedBy=multi-user.target
EOF
done
if [ -s "$STAGE_DIR/cleanup-setup.sh" ]; then sudo bash -c "sed 's/\r$//' '$STAGE_DIR/cleanup-setup.sh' | bash" | tail -2; fi
sudo systemctl daemon-reload
sudo systemctl enable -q localcen.service localcen-worker.service

echo "=== [3/5] migrate ==="
(cd "$REL" && sudo -u webapps bash -c "set -a; . '$ENV_FILE'; set +a; ./localcen migrate") | tail -3

echo "=== [4/5] flip current + restart ==="
sudo ln -sfn "$REL" "$APP/current"
sudo systemctl restart localcen.service localcen-worker.service

echo "=== [5/5] health ==="
for i in $(seq 1 10); do
  if out=$(curl -fsS --max-time 5 http://127.0.0.1:8092/healthz 2>/dev/null); then
    echo "  healthy: $out"
    systemctl is-active localcen localcen-worker localcen-cleanup.timer 2>/dev/null | paste -sd' '
    ls -1dt "$APP"/releases/* | tail -n +6 | xargs -r sudo rm -rf
    echo "DEPLOY_OK release=$TS"
    exit 0
  fi
  sleep 2
done
echo "!! health check failed"; sudo journalctl -u localcen -n 30 --no-pager || true
if [ -n "$PREV" ] && [ -d "$PREV" ]; then sudo ln -sfn "$PREV" "$APP/current"; sudo systemctl restart localcen localcen-worker; echo "rolled back to $PREV"; fi
exit 1
