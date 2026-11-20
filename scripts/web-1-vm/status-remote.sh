#!/usr/bin/env bash
# Health & routing audit for Lightsail Web-1 (3.6.143.66)
set -euo pipefail

echo "=== Services ==="
for svc in postgresql php8.4-fpm caddy fail2ban daiskills-mail.timer domains-rajesh-check.timer domains-rajesh-digest.timer web1-diskcheck.timer; do
  printf "  %-28s %s\n" "$svc" "$(systemctl is-active "$svc" 2>/dev/null || echo inactive)"
done

echo "=== Listening Sockets ==="
ss -ltnup | grep -E ':(22|80|443|5432)\s' || true

echo "=== PHP 8.4 Security INI & Active FPM Sockets ==="
php8.4 -i | grep -E '^(expose_php|display_errors|cgi\.fix_pathinfo|opcache\.enable)' | head -n 10 || true
ls -1 /run/php/app-*.sock | sort

echo "=== PostgreSQL 16 Databases ==="
(cd /tmp && sudo -u postgres psql -P pager=off -Atc "SELECT datname FROM pg_database WHERE NOT datistemplate ORDER BY 1")

echo "=== SQLite DB Health ==="
for db in /srv/phpapps/daiskills.com/shared/enquiries.sqlite /srv/phpapps/organicgrowth.center/data/ogcen.sqlite /srv/phpapps/nextdigital.in/data/nextdigital.sqlite /srv/phpapps/proseva.org/data/proseva.sqlite; do
  if sudo test -f "$db"; then
    printf "  %-60s %s\n" "$db" "$(sudo sqlite3 "$db" 'PRAGMA quick_check;' 2>/dev/null || echo ERROR)"
  else
    printf "  %-60s MISSING\n" "$db"
  fi
done

echo "=== Caddy Config Adapt (as caddy user) ==="
sudo -u caddy caddy adapt --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null
echo "Caddy adapt OK ($(ls -1 /etc/caddy/sites-enabled/*.caddy | wc -l) site files)"

echo "=== Local FastCGI Smoke Test via Direct FPM Sockets (as caddy user) ==="
sudo -u caddy python3 - <<'PY'
import socket, struct, re

SITES = [
    ("softskills.training",      "/srv/phpapps/softskills.training/current/public/index.php",      "/"),
    ("daiskills.com",            "/srv/phpapps/daiskills.com/current/public/index.php",            "/"),
    ("nextskillclub.com",        "/srv/phpapps/nextskillclub.com/current/public/index.php",        "/"),
    ("localcen.com",             "/srv/phpapps/localcen.com/current/public/index.php",             "/"),
    ("mrajesh.com",              "/srv/phpapps/mrajesh.com/current/public/index.php",              "/"),
    ("organicgrowth.center",     "/srv/phpapps/organicgrowth.center/public/index.php",             "/"),
    ("afteraiwork.com",          "/srv/phpapps/afteraiwork.com/public/index.php",                  "/"),
    ("nextdigital.in",           "/srv/phpapps/nextdigital.in/public/index.php",                   "/"),
    ("proseva.org",              "/srv/phpapps/proseva.org/public/index.php",                      "/"),
    ("dev.srikalabhairavam.com", "/srv/phpapps/dev.srikalabhairavam.com/current/public/index.php", "/"),
    ("domains.rajesh.app",       "/srv/phpapps/domains.rajesh.app/public/index.php",               "/login"),
]

def fcgi_rec(rtype, req_id, payload=b""):
    pad = (-len(payload)) & 7
    return struct.pack("!BBHHBx", 1, rtype, req_id, len(payload), pad) + payload + (b"\x00" * pad)

def enc_kv(k, v):
    kb, vb = k.encode(), v.encode()
    out = bytearray()
    for b in (kb, vb):
        n = len(b)
        out += bytes([n]) if n < 128 else struct.pack("!I", n | 0x80000000)
    return bytes(out) + kb + vb

failed = 0
for dom, script, uri in SITES:
    sock_dom = "domains.rajesh.app" if dom == "domains.rajesh.app" else dom
    host_hdr = "domains.rajesh.in" if dom == "domains.rajesh.app" else dom
    sock_path = f"/run/php/app-{sock_dom}.sock"
    docroot = script.rsplit("/", 1)[0]
    params = b"".join(enc_kv(k, v) for k, v in {
        "REQUEST_METHOD": "GET",
        "SCRIPT_FILENAME": script,
        "SCRIPT_NAME": "/index.php",
        "REQUEST_URI": uri,
        "DOCUMENT_ROOT": docroot,
        "SERVER_NAME": host_hdr,
        "SERVER_PORT": "443",
        "HTTPS": "on",
        "HTTP_HOST": host_hdr,
    }.items())
    req = (
        fcgi_rec(1, 1, struct.pack("!HB5x", 1, 0)) +
        fcgi_rec(4, 1, params) +
        fcgi_rec(4, 1, b"") +
        fcgi_rec(5, 1, b"")
    )
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(5)
        s.connect(sock_path)
        s.sendall(req)
        stdout = bytearray()
        stderr = bytearray()
        buf = bytearray()
        while True:
            chunk = s.recv(8192)
            if not chunk:
                break
            buf.extend(chunk)
            while len(buf) >= 8:
                _, rt, _, clen, plen = struct.unpack("!BBHHBx", buf[:8])
                need = 8 + clen + plen
                if len(buf) < need:
                    break
                data = bytes(buf[8:8 + clen])
                del buf[:need]
                if rt == 6:
                    stdout.extend(data)
                elif rt == 7:
                    stderr.extend(data)
        s.close()
        text = stdout.decode("utf-8", "replace")
        head, _, body = text.partition("\r\n\r\n")
        m_st = re.search(r"(?im)^Status:\s*(\d+[^\r\n]*)", head)
        status = m_st.group(1) if m_st else "200 OK"
        m_t = re.search(r"(?is)<title>(.*?)</title>", body)
        title = m_t.group(1).strip()[:55] if m_t else f"{len(body)}B body"
        x_pow = "X-Powered-By" in head
        err_note = f" stderr={stderr.decode('utf-8','replace').strip()[:80]}" if stderr else ""
        if not status.startswith("200") or x_pow or len(body) < 100:
            failed += 1
            print(f"  FAIL {dom:28s} {status} x_pow={x_pow} ({title}){err_note}")
        else:
            print(f"  OK   {dom:28s} {status} | {title}{err_note}")
    except Exception as exc:
        failed += 1
        print(f"  ERR  {dom:28s} {exc}")

if failed:
    raise SystemExit(f"{failed} FPM probe(s) failed")
PY

echo "=== Static Site Docroots Check (readable by caddy) ==="
for p in \
  /srv/static/rajeshforbharat.com/index.html \
  /srv/static/forbharat.in/index.html \
  /srv/static/haindaviswaraj.org.in/index.html \
  /srv/static/dev.haindaviswaraj.org.in/index.html \
  /srv/static/jyothularajesh.com/current/index.html \
  /srv/phpapps/navduta.com/current/public/index.html \
  /srv/static/srikalabhairavam.com/index.html \
  /srv/static/dev2.srikalabhairavam.com/current/index.html \
  /srv/static/dev8.srikalabhairavam.com/current/index.html \
  /srv/static/dev9.srikalabhairavam.com/current/index.html \
  /srv/static/dev10.srikalabhairavam.com/current/index.html \
  /srv/static/kalabhairavam.com/index.html; do
  if sudo -u caddy test -r "$p"; then
    printf "  OK   %s\n" "$p"
  else
    printf "  FAIL %s\n" "$p"
  fi
done

echo "=== Caddy HTTP Port-80 Host Routing Test (expect 308 HTTPS redirects for configured hosts, 404 unknown) ==="
for h in softskills.training www.softskills.training daiskills.com nextskillclub.com localcen.com mrajesh.com rajeshyukta.in www.rajeshyukta.in organicgrowth.center ogcen.com afteraiwork.com nextdigital.in proseva.org rajeshforbharat.com forbharat.in forbharat.com forbharat.org haindaviswaraj.org.in dev.haindaviswaraj.org.in jyothularajesh.com navduta.com srikalabhairavam.com srikalabhairavam.in dev.srikalabhairavam.com dev2.srikalabhairavam.com dev8.srikalabhairavam.com dev9.srikalabhairavam.com dev10.srikalabhairavam.com kalabhairavam.com domains.rajesh.in domains.rajesh1.com unknown.invalid; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --resolve "${h}:80:127.0.0.1" "http://${h}/" || echo ERR)
  printf "  %-32s http:// -> %s\n" "$h" "$code"
done

echo "=== Self-Signed TLS Check (domains.rajesh.in) ==="
echo | openssl s_client -connect 127.0.0.1:443 -servername domains.rajesh.in 2>/dev/null | openssl x509 -noout -subject -dates
printf "  https://domains.rajesh.in/login -> HTTP %s\n" "$(curl -sk --resolve domains.rajesh.in:443:127.0.0.1 -o /dev/null -w '%{http_code}' https://domains.rajesh.in/login)"

echo "=== Memory, Swap & Disk ==="
free -h
df -h /
sudo ufw status | head -n 12
