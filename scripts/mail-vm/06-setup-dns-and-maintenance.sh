#!/usr/bin/env bash
# Install CoreDNS (authoritative DNS for ns1/ns2.nextdp.com) and configure Caddy
# catch-all HTTPS maintenance page guarded by nextdp-tls-ask.
set -euo pipefail

STAGE="${STAGE_DIR:-/tmp/nextdp-dns-stage}"
COREDNS_VER="1.15.0"
COREDNS_SHA256="2495c5b8f3fab6d0a336c397f1227b75406d86e6ec7125744a29df9e936ab8cd"

if [ ! -d "$STAGE" ]; then
  echo "FATAL: stage dir missing: $STAGE" >&2
  exit 1
fi

sed -i 's/\r$//' "$STAGE/Corefile" "$STAGE/index.html" "$STAGE/nextdp-tls-ask.py" "$STAGE/Caddyfile"

echo "=== [1/5] Install CoreDNS v${COREDNS_VER} ==="
CUR_VER=""
if [ -x /usr/local/bin/coredns ]; then
  CUR_VER="$(/usr/local/bin/coredns -version 2>/dev/null | head -n 1 || true)"
fi
if [[ "$CUR_VER" != *"CoreDNS-${COREDNS_VER}"* ]]; then
  TMP_CD="/tmp/coredns-dl-$$"
  mkdir -p "$TMP_CD"
  curl -fsSL "https://github.com/coredns/coredns/releases/download/v${COREDNS_VER}/coredns_${COREDNS_VER}_linux_amd64.tgz" -o "${TMP_CD}/coredns.tgz"
  echo "${COREDNS_SHA256}  ${TMP_CD}/coredns.tgz" | sha256sum -c -
  tar -xzf "${TMP_CD}/coredns.tgz" -C "$TMP_CD"
  sudo install -m 0755 -o root -g root "${TMP_CD}/coredns" /usr/local/bin/coredns
  rm -rf "$TMP_CD"
fi
/usr/local/bin/coredns -version | head -n 2

id -u coredns >/dev/null 2>&1 || sudo useradd --system --no-create-home --shell /usr/sbin/nologin coredns

echo "=== [2/5] Configure CoreDNS (/etc/coredns/Corefile) ==="
sudo mkdir -p /etc/coredns
sudo install -m 0644 -o root -g coredns "$STAGE/Corefile" /etc/coredns/Corefile

sudo tee /etc/systemd/system/coredns.service >/dev/null <<'EOF'
[Unit]
Description=CoreDNS Authoritative DNS Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=coredns
Group=coredns
ExecStart=/usr/local/bin/coredns -conf /etc/coredns/Corefile
ExecReload=/bin/kill -SIGUSR1 $MAINPID
Restart=on-failure
RestartSec=3
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadOnlyPaths=/etc/coredns
LimitNOFILE=8192

[Install]
WantedBy=multi-user.target
EOF

echo "=== [3/5] Install Maintenance HTML & on-demand TLS ask guard ==="
sudo mkdir -p /opt/nextdp/maintenance
sudo install -m 0644 -o ubuntu -g ubuntu "$STAGE/index.html" /opt/nextdp/maintenance/index.html
sudo chown -R ubuntu:ubuntu /opt/nextdp/maintenance

sudo install -m 0755 -o root -g root "$STAGE/nextdp-tls-ask.py" /usr/local/bin/nextdp-tls-ask.py
sudo tee /etc/systemd/system/nextdp-tls-ask.service >/dev/null <<'EOF'
[Unit]
Description=Caddy on-demand TLS domain verification guard
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=nobody
Group=nogroup
Environment=PYTHONUNBUFFERED=1
Environment=VM_PUBLIC_IP=52.66.111.138
Environment=ASK_PORT=9055
ExecStart=/usr/bin/python3 /usr/local/bin/nextdp-tls-ask.py
Restart=always
RestartSec=2
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now coredns nextdp-tls-ask
sudo systemctl restart coredns nextdp-tls-ask

for _ in $(seq 1 15); do
  if curl -fsS http://127.0.0.1:9055/healthz >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
curl -fsS http://127.0.0.1:9055/healthz

echo "=== [4/5] Install & reload Caddyfile (explicit mail + wildcard maintenance) ==="
sudo cp "$STAGE/Caddyfile" /etc/caddy/Caddyfile
sudo chown root:root /etc/caddy/Caddyfile
sudo chmod 644 /etc/caddy/Caddyfile
sudo caddy fmt --overwrite /etc/caddy/Caddyfile
sudo mkdir -p /var/log/caddy/live
for lf in $(grep -oE '/var/log/caddy/[A-Za-z0-9._/-]+\.log' /etc/caddy/Caddyfile | sort -u); do
  sudo mkdir -p "$(dirname "$lf")"
  sudo touch "$lf"
done
sudo chown caddy:caddy /var/log/caddy
sudo chown -R caddy:caddy /var/log/caddy/live
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

echo "=== [5/5] Self-check CoreDNS & TLS ask guard ==="
sudo ss -tulnp | grep -E ':(53|9055)\b' || true
if ! command -v dig >/dev/null 2>&1; then
  sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq dnsutils
fi

echo "--- dig @172.26.3.188 checks ---"
dig @172.26.3.188 example.com A +noall +answer +comments | grep -E 'status:|flags:|IN\s+A' || true
dig @172.26.3.188 www.example.com A +noall +answer +comments | grep -E 'status:|flags:|IN\s+A' || true
dig @172.26.3.188 example.com MX +noall +answer +additional +comments | grep -E 'status:|flags:|IN\s+(MX|A)' || true
dig @172.26.3.188 example.com NS +noall +answer +additional +comments | grep -E 'status:|flags:|IN\s+(NS|A)' || true
dig @172.26.3.188 example.com SOA +noall +answer +comments | grep -E 'status:|flags:|IN\s+SOA' || true
dig @172.26.3.188 example.com CAA +noall +authority +comments | grep -E 'status:|flags:|IN\s+SOA' || true
dig @172.26.3.188 example.com AAAA +noall +authority +comments | grep -E 'status:|flags:|IN\s+SOA' || true
dig @172.26.3.188 1.0.0.127.in-addr.arpa PTR +noall +comments | grep -E 'status:|flags:' || true

echo "--- nextdp-tls-ask checks ---"
for test_dom in "mail.nextdp.com" "mx.nextdp.com" "google.com" "52.66.111.138" "a.b.c.d.nextdp.com"; do
  code=$(curl -s -o /tmp/ask-body -w '%{http_code}' "http://127.0.0.1:9055/ask?domain=${test_dom}")
  echo "  ask?domain=${test_dom} -> HTTP ${code} ($(tr -d '\r\n' </tmp/ask-body))"
done
rm -f /tmp/ask-body
