#!/usr/bin/env python3
"""Partition Caddy JSON access logs into daily dated archives and traffic summaries.

Outputs under /var/log/caddy/daily/<YYYY-MM-DD>/:
  - all-domains-<YYYY-MM-DD>.jsonl.gz     (all catch-all parked domain hits)
  - mail-services-<YYYY-MM-DD>.jsonl.gz   (webmail, admin, super-admin, autoconfig)
  - by-domain/<host>-<YYYY-MM-DD>.jsonl.gz (one compressed file per domain)
  - summary-<YYYY-MM-DD>.csv              (per-domain spreadsheet traffic report)
  - summary-<YYYY-MM-DD>.json             (structured daily stats + top paths/referers)
"""

from collections import Counter, OrderedDict, defaultdict
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo
import argparse
import csv
import glob
import gzip
import json
import os
import re
import shutil
import sys

IST = ZoneInfo("Asia/Kolkata")
LIVE_DIR = "/var/log/caddy/live"
LEGACY_DIR = "/var/log/caddy/legacy"
DAILY_ROOT = "/var/log/caddy/daily"

SAFE_HOST_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,252}$")
SCANNER_PATHS = (
    "/.env", "/.git", "/wp-login", "/wp-admin", "/wp-content", "/wp-includes",
    "/actuator", "/trace.axd", "/@vite", "/phpinfo", "/xmlrpc.php", "/boaform",
    "/cgi-bin", "/vendor/phpunit", "/config.json", "/sftp-config", "/.aws",
    "/.well-known/security.txt", "/shell", "/eval-stdin", "/phpmyadmin",
)
SCANNER_UAS = (
    "l9scan", "leakix", "zgrab", "censys", "masscan", "nuclei", "nikto",
    "sqlmap", "nmap", "shodan", "expanse", "palo alto", "curl/", "wget/",
    "python-requests", "python-urllib", "go-http-client", "httpx", "libwww-perl",
)
SEARCH_BOT_UAS = (
    "googlebot", "bingbot", "yandex", "duckduckbot", "baiduspider", "slurp",
    "applebot", "petalbot", "bytespider", "gptbot", "claudebot", "chatgpt-user",
    "perplexitybot", "ahrefsbot", "semrushbot", "mj12bot", "dotbot",
    "facebookexternalhit", "twitterbot", "linkedinbot", "whatsapp", "telegrambot",
    "bot/", "crawler", "spider",
)
BROWSER_UAS = ("mozilla/", "chrome/", "safari/", "firefox/", "edg/", "opera/")


class BoundedGzipPool:
    """Keep at most max_open gzip file handles open while writing per-domain streams."""

    def __init__(self, max_open: int = 48):
        self.max_open = max_open
        self._handles: OrderedDict[str, object] = OrderedDict()

    def write_line(self, path: str, line: str) -> None:
        fh = self._handles.get(path)
        if fh is None:
            if len(self._handles) >= self.max_open:
                _, old_fh = self._handles.popitem(last=False)
                old_fh.close()
            os.makedirs(os.path.dirname(path), exist_ok=True)
            fh = gzip.open(path, "at", encoding="utf-8", compresslevel=5)
            self._handles[path] = fh
        else:
            self._handles.move_to_end(path)
        fh.write(line)

    def close_all(self) -> None:
        while self._handles:
            _, fh = self._handles.popitem(last=False)
            fh.close()


def parse_ts_ist(val) -> datetime | None:
    if val is None:
        return None
    try:
        if isinstance(val, (int, float)):
            return datetime.fromtimestamp(float(val), tz=timezone.utc).astimezone(IST)
        if isinstance(val, str):
            s = val.strip()
            if s.endswith("Z"):
                s = s[:-1] + "+00:00"
            dt = datetime.fromisoformat(s)
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
            return dt.astimezone(IST)
    except Exception:
        return None
    return None


def classify_traffic(uri: str, ua: str, status: int) -> str:
    if status == 308:
        return "redirect"
    u = uri.lower().split("?", 1)[0]
    ua_l = ua.lower()
    if any(u.startswith(p) or p in u for p in SCANNER_PATHS):
        return "scanner"
    if not ua_l or any(s in ua_l for s in SCANNER_UAS):
        return "scanner"
    if any(b in ua_l for b in SEARCH_BOT_UAS):
        return "bot"
    if u in ("/robots.txt", "/favicon.ico", "/ads.txt", "/sitemap.xml"):
        return "asset"
    if any(b in ua_l for b in BROWSER_UAS):
        return "human"
    return "other"


def sanitize_host(raw_host: str) -> str:
    host = raw_host.split(":", 1)[0].strip().rstrip(".").lower()
    if SAFE_HOST_RE.match(host) and ".." not in host:
        return host
    return "_unknown"


def iter_source_files():
    seen = []
    for base in (LEGACY_DIR, LIVE_DIR):
        if os.path.isdir(base):
            for pat in ("*.log", "*.log.gz"):
                seen.extend(sorted(glob.glob(os.path.join(base, pat))))
    return seen


def open_text_auto(path: str):
    if path.endswith(".gz"):
        return gzip.open(path, "rt", encoding="utf-8", errors="replace")
    return open(path, "rt", encoding="utf-8", errors="replace")


def source_kind(path: str) -> str:
    name = os.path.basename(path).lower()
    if name.startswith(("domains-access", "nextdp-maintenance-access")):
        return "parked"
    if name.startswith("dithim-access"):
        return "site"
    return "mail"


def build_daily_archive(target_date: str, write_files: bool = True, print_report: bool = False) -> dict:
    files = iter_source_files()
    stage_dir = os.path.join(DAILY_ROOT, f".tmp-{target_date}-{os.getpid()}")
    final_dir = os.path.join(DAILY_ROOT, target_date)

    pool = BoundedGzipPool(max_open=48)
    stats = defaultdict(lambda: {
        "kind": "parked",
        "total": 0,
        "redirects_308": 0,
        "human": 0,
        "bot": 0,
        "scanner": 0,
        "asset": 0,
        "other": 0,
        "bytes": 0,
        "ips": set(),
        "statuses": Counter(),
        "paths": Counter(),
        "referers": Counter(),
    })

    if write_files:
        if os.path.exists(stage_dir):
            shutil.rmtree(stage_dir)
        os.makedirs(os.path.join(stage_dir, "by-domain"), exist_ok=True)
        domains_out = gzip.open(os.path.join(stage_dir, f"all-domains-{target_date}.jsonl.gz"), "wt", encoding="utf-8", compresslevel=5)
        mail_out = gzip.open(os.path.join(stage_dir, f"mail-services-{target_date}.jsonl.gz"), "wt", encoding="utf-8", compresslevel=5)
    else:
        domains_out = None
        mail_out = None

    total_matched = 0
    try:
        for src in files:
            skind = source_kind(src)
            with open_text_auto(src) as fh:
                for raw_line in fh:
                    if not raw_line.strip():
                        continue
                    try:
                        rec = json.loads(raw_line)
                    except json.JSONDecodeError:
                        continue
                    dt = parse_ts_ist(rec.get("ts"))
                    if dt is None or dt.date().isoformat() != target_date:
                        continue

                    total_matched += 1
                    req = rec.get("request") or {}
                    host = sanitize_host(req.get("host") or "")
                    uri = str(req.get("uri") or "/")
                    ip = str(req.get("client_ip") or req.get("remote_ip") or "")
                    hdrs = req.get("headers") or {}
                    ua_list = hdrs.get("User-Agent") or []
                    ua = str(ua_list[0]) if isinstance(ua_list, list) and ua_list else str(ua_list or "")
                    ref_list = hdrs.get("Referer") or []
                    ref = str(ref_list[0]) if isinstance(ref_list, list) and ref_list else str(ref_list or "")
                    status = int(rec.get("status") or 0)
                    size = int(rec.get("size") or 0)

                    bucket = classify_traffic(uri, ua, status)
                    st = stats[host]
                    st["kind"] = skind
                    st["total"] += 1
                    st["bytes"] += size
                    st["statuses"][str(status)] += 1
                    if ip:
                        st["ips"].add(ip)
                    if bucket == "redirect":
                        st["redirects_308"] += 1
                    else:
                        st[bucket] += 1
                        st["paths"][uri.split("?", 1)[0][:120]] += 1
                        if ref:
                            st["referers"][ref[:160]] += 1

                    if write_files:
                        norm_line = raw_line if raw_line.endswith("\n") else raw_line + "\n"
                        if skind in ("parked", "site"):
                            domains_out.write(norm_line)
                        else:
                            mail_out.write(norm_line)
                        per_host_path = os.path.join(stage_dir, "by-domain", f"{host}-{target_date}.jsonl.gz")
                        pool.write_line(per_host_path, norm_line)
    finally:
        if domains_out is not None:
            domains_out.close()
        if mail_out is not None:
            mail_out.close()
        pool.close_all()

    rows = []
    for host, st in stats.items():
        rows.append({
            "domain": host,
            "kind": st["kind"],
            "total_requests": st["total"],
            "https_requests": st["total"] - st["redirects_308"],
            "human_likely_hits": st["human"],
            "search_bot_hits": st["bot"],
            "scanner_hits": st["scanner"],
            "asset_hits": st["asset"],
            "other_hits": st["other"],
            "redirects_308": st["redirects_308"],
            "unique_ips": len(st["ips"]),
            "bytes_sent": st["bytes"],
            "statuses": dict(st["statuses"]),
            "top_paths": st["paths"].most_common(10),
            "top_referers": st["referers"].most_common(5),
        })

    rows.sort(key=lambda r: (r["human_likely_hits"], r["https_requests"], r["total_requests"]), reverse=True)

    summary = {
        "date_ist": target_date,
        "generated_at_ist": datetime.now(IST).isoformat(timespec="seconds"),
        "source_files_scanned": len(files),
        "total_events": total_matched,
        "distinct_domains": len(rows),
        "totals": {
            "total_requests": sum(r["total_requests"] for r in rows),
            "https_requests": sum(r["https_requests"] for r in rows),
            "human_likely_hits": sum(r["human_likely_hits"] for r in rows),
            "search_bot_hits": sum(r["search_bot_hits"] for r in rows),
            "scanner_hits": sum(r["scanner_hits"] for r in rows),
            "redirects_308": sum(r["redirects_308"] for r in rows),
            "bytes_sent": sum(r["bytes_sent"] for r in rows),
        },
        "domains": rows,
    }

    if write_files:
        csv_path = os.path.join(stage_dir, f"summary-{target_date}.csv")
        with open(csv_path, "w", newline="", encoding="utf-8") as cf:
            writer = csv.writer(cf)
            writer.writerow([
                "date_ist", "domain", "kind", "total_requests", "https_requests",
                "human_likely_hits", "search_bot_hits", "scanner_hits", "asset_hits",
                "other_hits", "redirects_308", "unique_ips", "bytes_sent", "top_path",
            ])
            for r in rows:
                top_path = r["top_paths"][0][0] if r["top_paths"] else ""
                writer.writerow([
                    target_date, r["domain"], r["kind"], r["total_requests"], r["https_requests"],
                    r["human_likely_hits"], r["search_bot_hits"], r["scanner_hits"], r["asset_hits"],
                    r["other_hits"], r["redirects_308"], r["unique_ips"], r["bytes_sent"], top_path,
                ])

        json_path = os.path.join(stage_dir, f"summary-{target_date}.json")
        with open(json_path, "w", encoding="utf-8") as jf:
            json.dump(summary, jf, indent=2)

        os.makedirs(DAILY_ROOT, exist_ok=True)
        for root, dirs, fnames in os.walk(stage_dir):
            os.chmod(root, 0o755)
            for fn in fnames:
                os.chmod(os.path.join(root, fn), 0o644)

        if os.path.exists(final_dir):
            backup_old = f"{final_dir}.old-{os.getpid()}"
            os.replace(final_dir, backup_old)
            os.replace(stage_dir, final_dir)
            shutil.rmtree(backup_old, ignore_errors=True)
        else:
            os.replace(stage_dir, final_dir)

        if os.path.isdir("/var/log/caddy") and _user_exists("ubuntu"):
            shutil.chown(final_dir, user="ubuntu", group="ubuntu")
            for root, dirs, fnames in os.walk(final_dir):
                shutil.chown(root, user="ubuntu", group="ubuntu")
                for fn in fnames:
                    shutil.chown(os.path.join(root, fn), user="ubuntu", group="ubuntu")

    if print_report:
        t = summary["totals"]
        print(f"=== Traffic Summary ({target_date} IST) ===")
        print(
            f"Domains: {summary['distinct_domains']} | Total: {t['total_requests']} | "
            f"HTTPS: {t['https_requests']} | Human: {t['human_likely_hits']} | "
            f"Bots: {t['search_bot_hits']} | Scanners: {t['scanner_hits']} | 308: {t['redirects_308']}"
        )
        print("")
        print(f"{'Domain':<34} {'Kind':<7} {'Human':>7} {'Bots':>6} {'Scan':>7} {'HTTPS':>7} {'IPs':>5}")
        print("-" * 80)
        for r in rows[:30]:
            print(
                f"{r['domain'][:34]:<34} {r['kind']:<7} {r['human_likely_hits']:>7} "
                f"{r['search_bot_hits']:>6} {r['scanner_hits']:>7} {r['https_requests']:>7} {r['unique_ips']:>5}"
            )
    return summary


def _user_exists(name: str) -> bool:
    try:
        import pwd
        pwd.getpwnam(name)
        return True
    except KeyError:
        return False


def prune_old_archives(keep_days: int) -> None:
    if not os.path.isdir(DAILY_ROOT):
        return
    cutoff = (datetime.now(IST).date() - timedelta(days=keep_days)).isoformat()
    for entry in os.listdir(DAILY_ROOT):
        full = os.path.join(DAILY_ROOT, entry)
        if os.path.isdir(full) and re.match(r"^\d{4}-\d{2}-\d{2}$", entry):
            if entry < cutoff:
                shutil.rmtree(full, ignore_errors=True)
    if os.path.isdir(LEGACY_DIR):
        legacy_cutoff = (datetime.now(timezone.utc) - timedelta(days=3)).timestamp()
        for entry in os.listdir(LEGACY_DIR):
            full = os.path.join(LEGACY_DIR, entry)
            try:
                if os.path.isfile(full) and os.stat(full).st_mtime < legacy_cutoff:
                    os.remove(full)
            except OSError:
                pass


def main() -> int:
    parser = argparse.ArgumentParser(description="Daily Caddy access log archiver and traffic report.")
    parser.add_argument("--date", help="Target IST date YYYY-MM-DD (defaults to yesterday IST).")
    parser.add_argument("--today", action="store_true", help="Analyze/archive today's IST date.")
    parser.add_argument("--report", action="store_true", help="Print domain summary table to stdout.")
    parser.add_argument("--no-write", action="store_true", help="Read-only report without rewriting daily archive files.")
    parser.add_argument("--keep-days", type=int, default=30, help="Retention days for daily archives (default: 30).")
    args = parser.parse_args()

    now_ist = datetime.now(IST).date()
    if args.date:
        target = args.date.strip()
    elif args.today:
        target = now_ist.isoformat()
    else:
        target = (now_ist - timedelta(days=1)).isoformat()

    build_daily_archive(target, write_files=not args.no_write, print_report=args.report)
    if not args.no_write:
        prune_old_archives(args.keep_days)
    return 0


if __name__ == "__main__":
    sys.exit(main())
