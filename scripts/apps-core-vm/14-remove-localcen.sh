#!/usr/bin/env bash
# Remove the old LocalCen install from Apps-Core-VM (moved to LocalCen-1-VM 3.111.132.3 on 2026-11-20).
# Final DB dump first (kept in /var/backups/localcen-retired/ and downloaded by the .ps1), then: services/timers off and
# deleted, Caddy blocks + member-host file removed, LocalCen dropped from the tls-ask multiplexer, DB + role dropped,
# /srv/apps/localcen deleted. Caddy is validated before reload and restored on failure. Next iDP / NextDP Core untouched.
set -Eeuo pipefail
exec 2>&1
cd /tmp
TS=$(date -u +%Y%m%dT%H%M%SZ)
ARCH=/var/backups/localcen-retired/$TS
F=/etc/caddy/Caddyfile
ASK=/usr/local/bin/apps-core-tls-ask.py

echo "=== [0/6] safety: LocalCen must be live on LocalCen-1-VM ==="
for h in localcen.cconsole.com admin.localcen.cconsole.com; do
  a=$(dig +short A "$h" @ns1.nextdp.com | tail -1); echo "  $h -> $a"
  [ "$a" = 3.111.132.3 ] || { echo "FATAL: $h does not point to LocalCen-1-VM" >&2; exit 1; }
done
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 https://localcen.cconsole.com/); echo "  https://localcen.cconsole.com -> $code"
[ "$code" = 200 ] || { echo "FATAL: new LocalCen not answering 200" >&2; exit 1; }

echo "=== [1/6] final dump + config archive -> $ARCH ==="
sudo install -d -m 0750 -o root -g ubuntu "$ARCH"
if sudo -u postgres psql -XAt -c "SELECT 1 FROM pg_database WHERE datname='localcen_db'" | grep -q 1; then
  sudo -u postgres pg_dump -Fc -d localcen_db | sudo tee "$ARCH/localcen_db.dump" >/dev/null
  echo "  dump $(sudo stat -c%s "$ARCH/localcen_db.dump") bytes, toc $(sudo pg_restore --list "$ARCH/localcen_db.dump" | grep -vc '^;')"
fi
sudo tar -czf "$ARCH/localcen-config.tar.gz" --ignore-failed-read \
  /srv/apps/localcen/shared /etc/systemd/system/localcen* /usr/local/sbin/localcen-caddy-sync.sh \
  /etc/caddy/sites-enabled/localcen-hosts.caddy "$F" "$ASK" 2>/dev/null || true
sudo chmod 0640 "$ARCH"/*; sudo chgrp ubuntu "$ARCH"/*
sudo ls -l "$ARCH" | tail -n +2

echo "=== [2/6] services + timers off ==="
UNITS="localcen.service localcen-worker.service localcen-caddy-sync.path localcen-caddy-sync.timer localcen-caddy-sync.service localcen-cleanup.timer localcen-cleanup.service"
sudo systemctl disable --now $UNITS >/dev/null 2>&1 || true
for u in $UNITS; do sudo rm -f "/etc/systemd/system/$u"; done
sudo rm -f /usr/local/sbin/localcen-caddy-sync.sh
sudo systemctl daemon-reload; sudo systemctl reset-failed >/dev/null 2>&1 || true
echo "  remaining localcen units: $(systemctl list-unit-files 'localcen*' --no-legend | wc -l)"

echo "=== [3/6] Caddy: drop LocalCen blocks + member file ==="
sudo cp -p "$F" "$F.bak-$TS"
[ -f /etc/caddy/sites-enabled/localcen-hosts.caddy ] && sudo mv /etc/caddy/sites-enabled/localcen-hosts.caddy "$ARCH/"
sudo python3 - "$F" <<'PY'
import sys
p = sys.argv[1]
lines = open(p, encoding="utf-8").read().split("\n")
out, skip, depth = [], False, 0
starts = ("https://admin.localcen.cconsole.com {", "https://localcen.cconsole.com {")
for ln in lines:
    s = ln.strip()
    if not skip and (s.startswith("# ── LocalCen consoles") or s.startswith("#   - LocalCen ")):
        continue
    if not skip and s in starts:
        skip, depth = True, 0
    if skip:
        depth += ln.count("{") - ln.count("}")
        if depth <= 0 and "}" in ln:
            skip = False
        continue
    out.append(ln)
text = "\n".join(out)
while "\n\n\n" in text:
    text = text.replace("\n\n\n", "\n\n")
open(p, "w", encoding="utf-8").write(text)
PY
if grep -qE '^https?://[^ ]*localcen|/srv/apps/localcen' "$F"; then echo "FATAL: blocks still present, restoring"; sudo cp -p "$F.bak-$TS" "$F"; exit 1; fi

echo "=== [4/6] tls-ask: drop LocalCen upstream ==="
sudo cp -p "$ASK" "$ASK.bak-$TS"
sudo sed -i -e '/("localcen", "http:\/\/127.0.0.1:8092\/internal\/tls-allow?domain="),/d' -e '/^  3\. LocalCen .*8092/d' "$ASK"
grep -q '127.0.0.1:8092/internal/tls-allow?domain=' "$ASK" && { echo "FATAL: 8092 still in tls-ask"; sudo cp -p "$ASK.bak-$TS" "$ASK"; sudo cp -p "$F.bak-$TS" "$F"; exit 1; }
python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$ASK"
sudo systemctl restart apps-core-tls-ask

echo "=== [5/6] validate + reload Caddy ==="
if ! sudo -u caddy caddy adapt --config "$F" --adapter caddyfile >/dev/null 2>&1 || ! sudo systemctl reload caddy; then
  echo "FATAL: Caddy invalid or reload failed - restoring"; sudo cp -p "$F.bak-$TS" "$F"; sudo cp -p "$ASK.bak-$TS" "$ASK"
  sudo systemctl restart apps-core-tls-ask; sudo systemctl reload caddy || true; exit 1
fi
echo "  reloaded; site lines now:"; grep -nE '^https?://' "$F" | sed 's/^/    /'

echo "=== [6/6] drop DB + role, delete app dir ==="
sudo -u postgres psql -Xq -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='localcen_db';" >/dev/null
sudo -u postgres psql -Xq -c "DROP DATABASE IF EXISTS localcen_db;"
sudo -u postgres psql -Xq -c "DROP ROLE IF EXISTS localcen_u;"
sudo rm -rf /srv/apps/localcen
for f in admin-localcen.access.log localcen.access.log public-localcen.access.log; do [ -f "/var/log/caddy/$f" ] && sudo mv "/var/log/caddy/$f" "$ARCH/" || true; done
echo "  dbs now: $(sudo -u postgres psql -XAt -c "SELECT string_agg(datname,' ' ORDER BY datname) FROM pg_database WHERE NOT datistemplate AND datname<>'postgres'")"

echo "=== checks ==="
systemctl is-active nextidp nextidp-worker nextdp nextdp-worker nextdp-scheduler caddy apps-core-tls-ask postgresql | paste -sd' '
for h in core.nextdp.com nextidp.com admin.nextdp.com console.nextdp.com; do
  printf '  %-22s %s\n' "$h" "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --resolve "$h:443:127.0.0.1" "https://$h/")"
done
echo "  :8092 listening: $(ss -ltnH 'sport = :8092' | wc -l)"
free -m | awk 'NR==2{print "  RAM used "$3" / "$2" MiB"}'
echo "ARCHIVE=$ARCH"
echo "REMOVED_OK"
