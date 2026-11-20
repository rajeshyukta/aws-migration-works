#!/usr/bin/env bash
# Phase 5 (docs/mail-vm-db-upgrade-r2.md): install the Mail VM off-site backup (restic -> R2 prefix aws-mail-vm/).
# Inputs (staged by the .ps1): /tmp/.offsite-restic.env (0600) and /tmp/nextdp-offsite-backup.sh.
# Idempotent. Initializes the repo if needed, then runs a first backup + verify. Never prints secrets.
set -Eeuo pipefail
exec 2>&1

SRC_ENV="/tmp/.offsite-restic.env"
SRC_SCRIPT="/tmp/nextdp-offsite-backup.sh"
trap 'rm -f "$SRC_ENV" "$SRC_SCRIPT"' EXIT
[ -s "$SRC_ENV" ] && [ -s "$SRC_SCRIPT" ] || { echo "FATAL: staged files missing" >&2; exit 1; }
RUN_NOW="${RUN_NOW:-1}"

echo "=== [1/4] install config + script ==="
sudo install -d -m 0700 -o root -g root /etc/nextdp-backup
sudo install -m 0600 -o root -g root "$SRC_ENV" /etc/nextdp-backup/restic.env
sudo sed -i 's/\r$//' /etc/nextdp-backup/restic.env
sudo install -m 0750 -o root -g root "$SRC_SCRIPT" /usr/local/sbin/nextdp-offsite-backup
sudo sed -i 's/\r$//' /usr/local/sbin/nextdp-offsite-backup
sudo tee /etc/nextdp-backup/README >/dev/null <<'EOF'
Mail VM off-site backup (restic on Cloudflare R2, bucket nxtmngr-test, prefix aws-mail-vm/).
Independent of NextManager Core. Repo password copy: private-data/mail-vm-offsite-backup.env on the
owner PC + AW Vault. Restore runbook: aws-setup-and-migrations/docs/mail-vm-offsite-backup.md
Snapshot contents: /var/backups/nextdp/nightly/db (pg_dump -Fc of every app DB + globals.sql),
/opt/nextdp/storage, /opt/nextdp/config, /etc/caddy, /etc/coredns, /var/lib/dithim, /opt/dithim.
EOF
echo "  /etc/nextdp-backup/restic.env (0600 root), /usr/local/sbin/nextdp-offsite-backup"

echo "=== [2/4] systemd units ==="
sudo tee /etc/systemd/system/nextdp-offsite-backup.service >/dev/null <<'EOF'
[Unit]
Description=NextDP Mail VM off-site backup (restic -> R2)
Wants=network-online.target
After=network-online.target postgresql.service
OnFailure=nextdp-backup-alert@%n.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nextdp-offsite-backup backup
Nice=10
IOSchedulingClass=idle
TimeoutStartSec=3h
EOF
sudo tee /etc/systemd/system/nextdp-offsite-backup.timer >/dev/null <<'EOF'
[Unit]
Description=Nightly NextDP Mail VM off-site backup (02:30 IST)

[Timer]
OnCalendar=*-*-* 21:00:00 UTC
RandomizedDelaySec=10min
Persistent=true

[Install]
WantedBy=timers.target
EOF
sudo tee /etc/systemd/system/nextdp-offsite-verify.service >/dev/null <<'EOF'
[Unit]
Description=NextDP Mail VM off-site backup verify + restore test
Wants=network-online.target
After=network-online.target postgresql.service nextdp-offsite-backup.service
OnFailure=nextdp-backup-alert@%n.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nextdp-offsite-backup verify
Nice=10
IOSchedulingClass=idle
TimeoutStartSec=3h
EOF
sudo tee /etc/systemd/system/nextdp-offsite-verify.timer >/dev/null <<'EOF'
[Unit]
Description=Weekly NextDP Mail VM backup verify + restore test (Sunday 04:00 IST)

[Timer]
OnCalendar=Sat *-*-* 22:30:00 UTC
Persistent=true

[Install]
WantedBy=timers.target
EOF
sudo tee /etc/systemd/system/nextdp-backup-alert@.service >/dev/null <<'EOF'
[Unit]
Description=Mail an alert for failed %i

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nextdp-offsite-backup alert %i
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now nextdp-offsite-backup.timer nextdp-offsite-verify.timer
systemctl list-timers 'nextdp-offsite-*' --no-pager | head -4

echo "=== [3/4] restic repository ==="
if sudo bash -c 'set -a; source /etc/nextdp-backup/restic.env; set +a; RESTIC_CACHE_DIR=/var/cache/restic restic cat config >/dev/null 2>&1'; then
  echo "  repository exists"
else
  sudo install -d -m 0700 /var/cache/restic
  sudo bash -c 'set -a; source /etc/nextdp-backup/restic.env; set +a; RESTIC_CACHE_DIR=/var/cache/restic restic init' | grep -E 'created restic repository|Please note' | sed -E 's/ at s3:.*$/ (R2 aws-mail-vm\/)/'
fi

if [ "$RUN_NOW" = 1 ]; then
  echo "=== [4/4] first backup + verify (via systemd, same as nightly) ==="
  sudo systemctl start nextdp-offsite-backup.service
  sudo journalctl -u nextdp-offsite-backup.service -n 20 --no-pager -o cat | grep -E '^\[|snapshot ' | tail -8
  sudo systemctl start nextdp-offsite-verify.service
  sudo journalctl -u nextdp-offsite-verify.service -n 20 --no-pager -o cat | grep -E '^\[' | tail -5
  sudo /usr/local/sbin/nextdp-offsite-backup status
fi
