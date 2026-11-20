#!/usr/bin/env bash
# Install the per-VM off-site backup (restic -> Cloudflare R2). Used for the Mail VM (16-setup-offsite-backup.ps1)
# and Web-1 (scripts/web-1-vm/07-setup-offsite-backup.ps1).
# Inputs (staged by the .ps1): /tmp/.offsite-restic.env (0600), /tmp/nextdp-offsite-backup.sh and optionally
# /tmp/nextdp-backup.conf (non-secret per-VM overrides). Env: VM_LABEL, REPO_PREFIX, PW_FILE, RUNBOOK,
# BACKUP_CAL, VERIFY_CAL, RUN_NOW. Idempotent; initializes the repo if needed. Never prints secrets.
set -Eeuo pipefail
exec 2>&1

SRC_ENV="/tmp/.offsite-restic.env"
SRC_SCRIPT="/tmp/nextdp-offsite-backup.sh"
SRC_CONF="/tmp/nextdp-backup.conf"
trap 'rm -f "$SRC_ENV" "$SRC_SCRIPT" "$SRC_CONF"' EXIT
[ -s "$SRC_ENV" ] && [ -s "$SRC_SCRIPT" ] || { echo "FATAL: staged files missing" >&2; exit 1; }
RUN_NOW="${RUN_NOW:-1}"
VM_LABEL="${VM_LABEL:-Mail VM}"
REPO_PREFIX="${REPO_PREFIX:-aws-mail-vm}"
PW_FILE="${PW_FILE:-mail-vm-offsite-backup.env}"
RUNBOOK="${RUNBOOK:-mail-vm-offsite-backup.md}"
BACKUP_CAL="${BACKUP_CAL:-*-*-* 21:00:00 UTC}"
VERIFY_CAL="${VERIFY_CAL:-Sat *-*-* 22:30:00 UTC}"
RESTIC_VERSION="0.19.1"
RESTIC_SHA256="f415415624dcc452f2a02b8c33641791a8c6d6d3b65bbb3543fcf9a25151585c"

echo "=== [1/4] restic, config + script ==="
if ! command -v restic >/dev/null 2>&1 || ! restic version | grep -q "restic ${RESTIC_VERSION}"; then
  T="$(mktemp /tmp/restic.XXXXXX.bz2)"
  curl -fsSL "https://github.com/restic/restic/releases/download/v${RESTIC_VERSION}/restic_${RESTIC_VERSION}_linux_amd64.bz2" -o "$T"
  echo "${RESTIC_SHA256}  ${T}" | sha256sum -c - >/dev/null
  python3 -c 'import bz2,sys; sys.stdout.buffer.write(bz2.open(sys.argv[1]).read())' "$T" > /tmp/.restic.bin; rm -f "$T"
  sudo install -m 0755 -o root -g root /tmp/.restic.bin /usr/local/bin/restic; rm -f /tmp/.restic.bin
  sudo chmod 0755 /usr/local/bin/restic
fi
echo "  $(restic version | cut -d' ' -f1-2)"
sudo install -d -m 0700 -o root -g root /etc/nextdp-backup
sudo install -m 0600 -o root -g root "$SRC_ENV" /etc/nextdp-backup/restic.env
sudo sed -i 's/\r$//' /etc/nextdp-backup/restic.env
sudo install -m 0750 -o root -g root "$SRC_SCRIPT" /usr/local/sbin/nextdp-offsite-backup
sudo sed -i 's/\r$//' /usr/local/sbin/nextdp-offsite-backup
if [ -s "$SRC_CONF" ]; then
  sudo install -m 0644 -o root -g root "$SRC_CONF" /etc/nextdp-backup/backup.conf
  sudo sed -i 's/\r$//' /etc/nextdp-backup/backup.conf
  echo "  backup.conf installed (per-VM overrides)"
fi
sudo tee /etc/nextdp-backup/README >/dev/null <<EOF
${VM_LABEL} off-site backup (restic on Cloudflare R2, bucket nxtmngr-test, prefix ${REPO_PREFIX}/).
Independent of NextManager Core. Repo password copy: private-data/${PW_FILE} on the owner PC + AW Vault.
Restore runbook: aws-setup-and-migrations/docs/${RUNBOOK}
Run: sudo nextdp-offsite-backup status|backup|verify   Config: /etc/nextdp-backup/{restic.env,backup.conf}
EOF
echo "  /etc/nextdp-backup/restic.env (0600 root), /usr/local/sbin/nextdp-offsite-backup"

echo "=== [2/4] systemd units ==="
sudo tee /etc/systemd/system/nextdp-offsite-backup.service >/dev/null <<EOF
[Unit]
Description=${VM_LABEL} off-site backup (restic -> R2)
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
sudo tee /etc/systemd/system/nextdp-offsite-backup.timer >/dev/null <<EOF
[Unit]
Description=Nightly ${VM_LABEL} off-site backup

[Timer]
OnCalendar=${BACKUP_CAL}
RandomizedDelaySec=10min
Persistent=true

[Install]
WantedBy=timers.target
EOF
sudo tee /etc/systemd/system/nextdp-offsite-verify.service >/dev/null <<EOF
[Unit]
Description=${VM_LABEL} off-site backup verify + restore test
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
sudo tee /etc/systemd/system/nextdp-offsite-verify.timer >/dev/null <<EOF
[Unit]
Description=Weekly ${VM_LABEL} backup verify + restore test

[Timer]
OnCalendar=${VERIFY_CAL}
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
  sudo bash -c 'set -a; source /etc/nextdp-backup/restic.env; set +a; RESTIC_CACHE_DIR=/var/cache/restic restic init' | grep -E 'created restic repository' | sed -E "s# at s3:.*\$# (R2 ${REPO_PREFIX}/)#"
fi

if [ "$RUN_NOW" = 1 ]; then
  echo "=== [4/4] first backup + verify (via systemd, same as nightly) ==="
  sudo systemctl start nextdp-offsite-backup.service
  sudo journalctl -u nextdp-offsite-backup.service -n 40 --no-pager -o cat --since "-15min" | grep -E '^\[|snapshot ' | tail -14
  sudo systemctl start nextdp-offsite-verify.service
  sudo journalctl -u nextdp-offsite-verify.service -n 20 --no-pager -o cat --since "-15min" | grep -E '^\[' | tail -5
  sudo /usr/local/sbin/nextdp-offsite-backup status
fi
