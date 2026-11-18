#!/usr/bin/env python3
"""On-demand TLS ask gate for Caddy catch-all maintenance virtual host.

Allows Let's Encrypt certificate issuance only for valid public hostnames that:
- are not IP literals or internal/local domains,
- are apex, www, or single-level subdomains (<= base_len + 1 labels),
- resolve in public DNS to this VM's public IP (52.66.111.138), and
- stay within per-base-domain and hourly rate caps to block scanner abuse.
"""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs
from collections import deque
import ipaddress
import os
import re
import socket
import threading
import time

EXPECTED_IP = os.environ.get("VM_PUBLIC_IP", "52.66.111.138")
LISTEN_HOST = "127.0.0.1"
LISTEN_PORT = int(os.environ.get("ASK_PORT", "9055"))

LABEL_RE = re.compile(r"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$")
BLOCKED_SUFFIXES = (
    ".local",
    ".internal",
    ".localhost",
    ".arpa",
    ".localdomain",
    ".home",
    ".lan",
    ".sslip.io",
    ".nip.io",
    ".xip.io",
)
MULTI_PART_TLDS = {
    "co.in", "org.in", "net.in", "ac.in", "edu.in", "gov.in", "ind.in",
    "co.uk", "org.uk", "me.uk", "net.uk",
    "com.au", "net.au", "org.au",
}

MAX_HOSTS_PER_BASE = 10
MAX_NEW_PER_HOUR = 500
POS_CACHE_TTL = 300
NEG_CACHE_TTL = 20

_lock = threading.Lock()
_approved = {}          # domain -> expiry timestamp
_negative = {}          # domain -> expiry timestamp
_subs_by_base = {}      # base_domain -> set of approved hostnames
_recent_new = deque()   # timestamps of new host approvals


def is_ip_literal(host: str) -> bool:
    try:
        ipaddress.ip_address(host.strip("[]"))
        return True
    except ValueError:
        return False


def base_domain(labels: list[str]) -> str:
    if len(labels) >= 3 and f"{labels[-2]}.{labels[-1]}" in MULTI_PART_TLDS:
        return ".".join(labels[-3:])
    if len(labels) >= 2:
        return ".".join(labels[-2:])
    return ".".join(labels)


def resolves_to_vm(domain: str) -> bool:
    try:
        infos = socket.getaddrinfo(domain, 443, socket.AF_INET, socket.SOCK_STREAM)
        ips = {info[4][0] for info in infos}
        return EXPECTED_IP in ips
    except OSError:
        return False


def check_domain(raw_domain: str) -> tuple[bool, str]:
    domain = raw_domain.strip().rstrip(".").lower()
    if not domain or len(domain) > 253 or is_ip_literal(domain):
        return False, "invalid_or_ip"
    if any(domain.endswith(sfx) for sfx in BLOCKED_SUFFIXES):
        return False, "blocked_suffix"

    labels = domain.split(".")
    if len(labels) < 2 or not all(LABEL_RE.match(lbl) for lbl in labels):
        return False, "bad_labels"

    base = base_domain(labels)
    base_len = len(base.split("."))
    if len(labels) > base_len + 1:
        return False, "too_many_labels"

    now = time.monotonic()
    with _lock:
        if _approved.get(domain, 0) > now:
            return True, "cached_allow"
        if _negative.get(domain, 0) > now:
            return False, "cached_deny"

        while _recent_new and now - _recent_new[0] > 3600:
            _recent_new.popleft()

        known_subs = _subs_by_base.get(base, set())
        if domain not in known_subs:
            if len(known_subs) >= MAX_HOSTS_PER_BASE:
                _negative[domain] = now + NEG_CACHE_TTL
                return False, "base_cap_reached"
            if len(_recent_new) >= MAX_NEW_PER_HOUR:
                _negative[domain] = now + NEG_CACHE_TTL
                return False, "hourly_cap_reached"

    if not resolves_to_vm(domain):
        with _lock:
            _negative[domain] = time.monotonic() + NEG_CACHE_TTL
        return False, "dns_mismatch"

    with _lock:
        now2 = time.monotonic()
        _approved[domain] = now2 + POS_CACHE_TTL
        subs = _subs_by_base.setdefault(base, set())
        if domain not in subs:
            subs.add(domain)
            _recent_new.append(now2)
    return True, "ok"


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

        domain = parse_qs(parsed.query).get("domain", [""])[0]
        allowed, reason = check_domain(domain)
        self.send_response(200 if allowed else 403)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.end_headers()
        self.wfile.write(f"{reason}\n".encode("utf-8"))

    def log_message(self, format, *args):
        return


if __name__ == "__main__":
    server = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), Handler)
    server.serve_forever()
