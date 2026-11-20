#!/usr/bin/env python3
"""On-demand TLS ask multiplexer for Apps-Core-VM (127.0.0.1:8099).

Chains Caddy's ask check across co-hosted backends on the VM:
  1. Next iDP    (127.0.0.1:8080/_edge/ask)
  2. NextDP Core (127.0.0.1:8090/internal/tls/ask)
  3. LocalCen    (127.0.0.1:8092/internal/tls-allow)
Returns HTTP 200 on the first 2xx match, else 403.
"""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, quote, urlparse
from urllib.request import Request, urlopen

LISTEN_HOST = "127.0.0.1"
LISTEN_PORT = 8099

UPSTREAMS = (
    ("nextidp", "http://127.0.0.1:8080/_edge/ask?domain="),
    ("nextdp-core", "http://127.0.0.1:8090/internal/tls/ask?domain="),
    ("localcen", "http://127.0.0.1:8092/internal/tls-allow?domain="),
)


def query_upstream(base_url: str, domain: str) -> bool:
    req = Request(f"{base_url}{quote(domain, safe='')}", method="GET")
    try:
        with urlopen(req, timeout=2.0) as resp:
            return 200 <= resp.status < 300
    except (HTTPError, URLError, OSError):
        return False


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/healthz":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok\n")
            return
        if parsed.path != "/ask":
            self.send_response(404)
            self.end_headers()
            return

        domain = parse_qs(parsed.query).get("domain", [""])[0].strip().lower()
        if not domain:
            self.send_response(400)
            self.end_headers()
            self.wfile.write(b"missing domain\n")
            return

        for name, url in UPSTREAMS:
            if query_upstream(url, domain):
                self.send_response(200)
                self.end_headers()
                self.wfile.write(f"allow:{name}\n".encode("utf-8"))
                return

        self.send_response(403)
        self.end_headers()
        self.wfile.write(b"denied\n")

    def log_message(self, format, *args):
        return


if __name__ == "__main__":
    server = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), Handler)
    server.serve_forever()
