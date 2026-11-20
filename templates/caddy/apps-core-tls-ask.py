#!/usr/bin/env python3
"""On-demand TLS ask multiplexer + host router for Apps-Core-VM (127.0.0.1:8099).

GET /ask?domain=<host>   Caddy on-demand TLS check, chained across co-hosted backends:
                           1. Next iDP    (127.0.0.1:8080/_edge/ask)
                           2. NextDP Core (127.0.0.1:8090/internal/tls/ask)
                         200 on the first 2xx match, else 403.
GET /route               Used by Caddy forward_auth in the https:// catch-all. Reads the original
                         host from X-Forwarded-Host and always answers 200 with
                         X-Apps-Backend: idp | core, so Caddy can send the request (including its
                         body) straight to the right app. Hosts Next iDP owns -> idp; everything
                         else -> core (the same result as the old "Next iDP answers 421" fallthrough,
                         which loses POST bodies). Answers are cached for CACHE_TTL seconds.
GET /healthz             200 ok
"""

import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, quote, urlparse
from urllib.request import Request, urlopen

LISTEN_HOST = "127.0.0.1"
LISTEN_PORT = 8099
CACHE_TTL = 30.0

NEXTIDP_ASK = "http://127.0.0.1:8080/_edge/ask?domain="
CORE_ASK = "http://127.0.0.1:8090/internal/tls/ask?domain="
UPSTREAMS = (("nextidp", NEXTIDP_ASK), ("nextdp-core", CORE_ASK))

_route_cache = {}
_route_lock = threading.Lock()


def query_upstream(base_url: str, domain: str) -> bool:
    req = Request(f"{base_url}{quote(domain, safe='')}", method="GET")
    try:
        with urlopen(req, timeout=2.0) as resp:
            return 200 <= resp.status < 300
    except (HTTPError, URLError, OSError):
        return False


def clean_host(raw: str) -> str:
    host = (raw or "").split(",")[0].strip().lower()
    if host.startswith("["):
        return host
    return host.rsplit(":", 1)[0] if host.count(":") == 1 else host


def route_for(host: str) -> str:
    now = time.monotonic()
    with _route_lock:
        hit = _route_cache.get(host)
        if hit and now - hit[1] < CACHE_TTL:
            return hit[0]
    backend = "idp" if host and query_upstream(NEXTIDP_ASK, host) else "core"
    with _route_lock:
        if len(_route_cache) > 5000:
            _route_cache.clear()
        _route_cache[host] = (backend, now)
    return backend


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _reply(self, code: int, body: bytes = b"", headers=None):
        self.send_response(code)
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/healthz":
            return self._reply(200, b"ok\n")
        if parsed.path == "/route":
            backend = route_for(clean_host(self.headers.get("X-Forwarded-Host", "")))
            return self._reply(200, b"", {"X-Apps-Backend": backend})
        if parsed.path != "/ask":
            return self._reply(404)

        domain = parse_qs(parsed.query).get("domain", [""])[0].strip().lower()
        if not domain:
            return self._reply(400, b"missing domain\n")

        for name, url in UPSTREAMS:
            if query_upstream(url, domain):
                return self._reply(200, f"allow:{name}\n".encode("utf-8"))
        return self._reply(403, b"denied\n")

    def log_message(self, format, *args):
        return


if __name__ == "__main__":
    import sys
    port = int(sys.argv[1]) if len(sys.argv) > 1 else LISTEN_PORT
    server = ThreadingHTTPServer((LISTEN_HOST, port), Handler)
    server.daemon_threads = True
    server.serve_forever()
