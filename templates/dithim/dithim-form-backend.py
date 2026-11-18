#!/usr/bin/env python3
"""Lightweight stdlib HTTP backend for dithim.com forms.

Handles POST /api/submit(.php) and POST /api/register(.php), validates payloads,
applies per-IP sliding-window rate limits + honeypot filtering, and persists
submissions cleanly into structured .txt files with persistent sequential IDs.
"""

from collections import defaultdict
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
import re
import secrets
import signal
import sys
import threading
import time
from urllib.parse import parse_qs, urlparse
from zoneinfo import ZoneInfo

BIND_HOST = os.environ.get("DITHIM_BIND_HOST", "127.0.0.1")
BIND_PORT = int(os.environ.get("DITHIM_BIND_PORT", "8090"))
SUBMISSIONS_DIR = os.environ.get("DITHIM_SUBMISSIONS_DIR", "/var/lib/dithim/submissions")
STATE_DIR = os.environ.get("DITHIM_STATE_DIR", "/var/lib/dithim/state")

MAX_BODY_BYTES = 65536
IST = ZoneInfo("Asia/Kolkata")
EMAIL_RE = re.compile(r"^[^@\s<>()\[\],;:]+@[^@\s<>()\[\],;:]+\.[^@\s<>()\[\],;:]{2,}$")
CONTROL_LINE_RE = re.compile(r"[\x00-\x1f\x7f]+")
CONTROL_MULTI_RE = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]+")

SUBMIT_SUCCESS_MSG = (
    "Your request has been received. Our systems architecture team will reach out promptly."
)
REGISTER_SUCCESS_MSG = (
    "We are currently providing services to selected enterprise clients. "
    "You will be able to access our services once our architecture board reviews and approves your registration."
)


def sanitize_line(val, max_len: int = 300) -> str:
    if val is None:
        return ""
    cleaned = CONTROL_LINE_RE.sub(" ", str(val)).strip()
    return cleaned[:max_len]


def sanitize_multiline(val, max_len: int = 4000) -> str:
    if val is None:
        return ""
    normalized = str(val).replace("\r\n", "\n").replace("\r", "\n")
    cleaned = CONTROL_MULTI_RE.sub("", normalized).strip()
    return cleaned[:max_len]


def validate_email(val) -> str:
    candidate = sanitize_line(val, max_len=254)
    if not candidate or not EMAIL_RE.match(candidate):
        return ""
    return candidate


def client_ip(headers, fallback: str) -> str:
    for header_name in ("CF-Connecting-IP", "X-Forwarded-For"):
        raw = headers.get(header_name)
        if raw:
            first = raw.split(",", 1)[0].strip()
            if first:
                return sanitize_line(first, max_len=64)
    return sanitize_line(fallback or "unknown", max_len=64)


class SlidingRateLimiter:
    """Thread-safe per-(endpoint, ip) sliding window rate limiter."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._hits: dict[tuple[str, str], list[float]] = defaultdict(list)

    def allow(self, endpoint: str, ip: str, per_min: int, per_hour: int) -> str | None:
        now = time.time()
        key = (endpoint, ip)
        with self._lock:
            stale = [k for k, ts_list in self._hits.items() if not ts_list or (now - ts_list[-1]) > 7200]
            for k in stale:
                del self._hits[k]

            recent = [t for t in self._hits[key] if (now - t) < 3600]
            self._hits[key] = recent

            last_min = sum(1 for t in recent if (now - t) < 60)
            if last_min >= per_min:
                return (
                    f"Rate limit exceeded: maximum {per_min} attempts allowed per minute. "
                    "Please pause for 60 seconds."
                )
            if len(recent) >= per_hour:
                return (
                    f"Hourly limit exceeded: maximum {per_hour} attempts per hour per IP. "
                    "Please contact your administrator."
                )
            recent.append(now)
            return None


class CounterStore:
    """Thread-safe persistent sequential ID generator backed by counters.json."""

    def __init__(self, path: str) -> None:
        self._path = path
        self._lock = threading.Lock()

    def next_id(self, prefix: str) -> str:
        with self._lock:
            os.makedirs(os.path.dirname(self._path), exist_ok=True)
            data = {}
            if os.path.exists(self._path):
                try:
                    with open(self._path, "r", encoding="utf-8") as fh:
                        loaded = json.load(fh)
                        if isinstance(loaded, dict):
                            data = loaded
                except (OSError, json.JSONDecodeError):
                    data = {}

            val = int(data.get(prefix, 0)) + 1
            data[prefix] = val
            tmp_path = f"{self._path}.tmp-{os.getpid()}-{threading.get_ident()}"
            with open(tmp_path, "w", encoding="utf-8") as fh:
                json.dump(data, fh, indent=2)
                fh.write("\n")
                fh.flush()
                os.fsync(fh.fileno())
            os.replace(tmp_path, self._path)
            return f"{prefix}-{val:06d}"


class TxtArchiveWriter:
    """Appends structured form entries cleanly to category and daily .txt files."""

    def __init__(self, base_dir: str) -> None:
        self._base_dir = base_dir
        self._lock = threading.Lock()

    def record(
        self,
        category_file: str,
        reference_id: str,
        header_fields: list[tuple[str, str]],
        body_label: str,
        body_text: str,
    ) -> None:
        now_utc = datetime.now(timezone.utc)
        now_ist = now_utc.astimezone(IST)
        lines = [
            "=" * 72,
            f"Reference ID : {reference_id}",
            f"Submitted At : {now_ist.isoformat(timespec='seconds')} ({now_utc.strftime('%Y-%m-%dT%H:%M:%SZ')})",
        ]
        for label, value in header_fields:
            lines.append(f"{label:<13}: {value if value else '-'}")
        lines.append(f"{body_label}:")
        if body_text:
            for row in body_text.split("\n"):
                lines.append(f"  {row}")
        else:
            lines.append("  -")
        lines.append("")
        block = "\n".join(lines) + "\n"

        targets = [
            os.path.join(self._base_dir, category_file),
            os.path.join(self._base_dir, "daily", f"{now_ist.date().isoformat()}.txt"),
        ]
        with self._lock:
            for path in targets:
                os.makedirs(os.path.dirname(path), exist_ok=True)
                with open(path, "a", encoding="utf-8") as fh:
                    fh.write(block)
                    fh.flush()
                    os.fsync(fh.fileno())
                try:
                    os.chmod(path, 0o640)
                except OSError:
                    pass


RATE_LIMITER = SlidingRateLimiter()
COUNTERS = CounterStore(os.path.join(STATE_DIR, "counters.json"))
TXT_WRITER = TxtArchiveWriter(SUBMISSIONS_DIR)


def _extract_products(payload: dict) -> str:
    raw = payload.get("products")
    if raw is None:
        raw = payload.get("product")
    if isinstance(raw, list):
        items = [sanitize_line(item, max_len=80) for item in raw]
        return ", ".join(item for item in items if item)
    if raw is None:
        return ""
    return sanitize_line(raw, max_len=300)


def handle_submit(payload: dict, ip: str, ua: str) -> tuple[int, dict]:
    honeypot = sanitize_line(payload.get("hp_website_portal"), max_len=120)
    if honeypot:
        return 200, {
            "success": True,
            "message": SUBMIT_SUCCESS_MSG,
            "reference_id": f"DTH-{secrets.token_hex(3).upper()}",
        }

    limit_err = RATE_LIMITER.allow("submit", ip, per_min=10, per_hour=40)
    if limit_err:
        return 429, {"success": False, "error": limit_err}

    form_type = sanitize_line(payload.get("form_type") or "contact_form", max_len=64)
    name = sanitize_line(payload.get("name"), max_len=160)
    email = validate_email(payload.get("email"))
    company = sanitize_line(payload.get("company"), max_len=180)
    products = _extract_products(payload)
    message = sanitize_multiline(payload.get("message") or payload.get("scope"), max_len=4000)

    if not email:
        return 400, {"success": False, "error": "Valid email address is required."}

    ref_id = COUNTERS.next_id("DTH")
    TXT_WRITER.record(
        category_file="contact-submissions.txt",
        reference_id=ref_id,
        header_fields=[
            ("Endpoint", "/api/submit"),
            ("Form Type", form_type),
            ("Name", name),
            ("Email", email),
            ("Company", company),
            ("Products", products),
            ("Client IP", ip),
            ("User-Agent", ua),
        ],
        body_label="Message / Scope",
        body_text=message,
    )
    return 200, {
        "success": True,
        "message": SUBMIT_SUCCESS_MSG,
        "reference_id": ref_id,
    }


def handle_register(payload: dict, ip: str, ua: str) -> tuple[int, dict]:
    limit_err = RATE_LIMITER.allow("register", ip, per_min=3, per_hour=10)
    if limit_err:
        return 429, {"success": False, "error": limit_err}

    honeypot = sanitize_line(payload.get("hp_website_portal"), max_len=120)
    if honeypot:
        return 200, {
            "success": True,
            "reference_id": f"REG-{secrets.token_hex(3).upper()}",
            "message": REGISTER_SUCCESS_MSG,
        }

    name = sanitize_line(payload.get("name"), max_len=160)
    email = validate_email(payload.get("email"))
    company = sanitize_line(payload.get("company"), max_len=180)
    role = sanitize_line(payload.get("role"), max_len=120)
    cloud_provider = sanitize_line(payload.get("cloud_provider"), max_len=120)
    workload_scope = sanitize_multiline(
        payload.get("workload_scope") or payload.get("message"),
        max_len=4000,
    )

    if not name or not email or not company:
        return 400, {
            "success": False,
            "error": "Full Name, Corporate Email, and Organization Name are required.",
        }

    ref_id = COUNTERS.next_id("REG")
    TXT_WRITER.record(
        category_file="registrations.txt",
        reference_id=ref_id,
        header_fields=[
            ("Endpoint", "/api/register"),
            ("Name", name),
            ("Email", email),
            ("Company", company),
            ("Role", role),
            ("Cloud", cloud_provider),
            ("Client IP", ip),
            ("User-Agent", ua),
        ],
        body_label="Workload Scope",
        body_text=workload_scope,
    )
    return 200, {
        "success": True,
        "reference_id": ref_id,
        "message": REGISTER_SUCCESS_MSG,
    }


POST_ROUTES = {
    "/api/submit": handle_submit,
    "/api/submit.php": handle_submit,
    "/api/register": handle_register,
    "/api/register.php": handle_register,
}


class DithimHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _send_json(self, status: int, body: dict) -> None:
        raw = json.dumps(body).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def _read_payload(self) -> tuple[dict | None, str | None]:
        raw_len = self.headers.get("Content-Length")
        if not raw_len:
            return {}, None
        try:
            length = int(raw_len)
        except ValueError:
            return None, "Invalid Content-Length header."
        if length < 0 or length > MAX_BODY_BYTES:
            return None, "Request payload too large."
        if length == 0:
            return {}, None

        raw_bytes = self.rfile.read(length)
        content_type = (self.headers.get("Content-Type") or "").lower()
        text = raw_bytes.decode("utf-8", errors="replace")

        if "application/json" in content_type or text.lstrip().startswith("{"):
            try:
                parsed = json.loads(text)
            except json.JSONDecodeError:
                return None, "Malformed JSON payload."
            return (parsed if isinstance(parsed, dict) else {}), None

        if "application/x-www-form-urlencoded" in content_type:
            qs = parse_qs(text, keep_blank_values=True)
            parsed = {}
            for k, vals in qs.items():
                clean_k = k[:-2] if k.endswith("[]") else k
                if k.endswith("[]") or len(vals) > 1:
                    parsed[clean_k] = vals
                else:
                    parsed[clean_k] = vals[0] if vals else ""
            return parsed, None

        return None, "Unsupported Content-Type."

    def do_GET(self) -> None:
        path = urlparse(self.path).path
        if path in ("/healthz", "/api/health"):
            self._send_json(200, {"ok": True, "service": "dithim-form-backend"})
            return
        if path in POST_ROUTES:
            self._send_json(405, {"success": False, "error": "Method not allowed."})
            return
        self._send_json(404, {"success": False, "error": "Endpoint not found."})

    def do_POST(self) -> None:
        path = urlparse(self.path).path
        handler_fn = POST_ROUTES.get(path)
        if not handler_fn:
            self._send_json(404, {"success": False, "error": "Endpoint not found."})
            return

        payload, err = self._read_payload()
        if err is not None:
            self._send_json(400, {"success": False, "error": err})
            return

        ip = client_ip(self.headers, self.client_address[0] if self.client_address else "")
        ua = sanitize_line(self.headers.get("User-Agent") or "Unknown", max_len=255)
        try:
            status, body = handler_fn(payload or {}, ip, ua)
        except Exception as exc:
            sys.stderr.write(f"[dithim-form-backend] unexpected error on {path}: {exc}\n")
            sys.stderr.flush()
            self._send_json(500, {"success": False, "error": "Unable to process request right now."})
            return
        self._send_json(status, body)

    def log_message(self, format: str, *args) -> None:
        sys.stderr.write(f"[dithim-form-backend] {self.address_string()} - {format % args}\n")
        sys.stderr.flush()


def main() -> int:
    os.makedirs(SUBMISSIONS_DIR, exist_ok=True)
    os.makedirs(os.path.join(SUBMISSIONS_DIR, "daily"), exist_ok=True)
    os.makedirs(STATE_DIR, exist_ok=True)

    server = ThreadingHTTPServer((BIND_HOST, BIND_PORT), DithimHandler)

    def _stop(_signum, _frame):
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)
    sys.stderr.write(f"[dithim-form-backend] listening on http://{BIND_HOST}:{BIND_PORT}\n")
    sys.stderr.flush()
    try:
        server.serve_forever(poll_interval=0.5)
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
