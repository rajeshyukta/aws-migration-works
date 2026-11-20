#!/usr/bin/env bash
# Runs on the DNS VM. Imports the zones of one old Azure PowerDNS account (pdns_azure, exported from
# the nmc-dns-1 disk) into a LIVE dns-service tenant through the dns-service API (127.0.0.1:8080,
# tenant API key from /root/.dns-<KEY_ACCOUNT>-secrets.env, never printed; KEY_ACCOUNT defaults to ACCOUNT,
# set it to the TARGET tenant when an old account is merged into another tenant).
#
# Rules (owner decisions 2026-11-20):
#   - new zone: claim it (ref = NextDP Core dns_zones.id when known), then write every old record set
#   - zone already live: keep every live record set; only add old record sets that are missing
#     (exception: RESTORE_GOOGLE_MX=1 puts back an old Google MX that was replaced on AWS)
#   - never imported: SOA, apex NS, records on DROP_IPS, names in DROP_HOSTS, iDP records
#     (_n1-verify.* TXT, CNAME to *.n1id.*), zones in SKIP_ZONES, disabled records
#   - A/AAAA values rewritten by IP_MAP (old=new ...)
# DRY_RUN=1 (default) only prints the plan. Writes PLAN_TSV (one line per record set) when set.
set -Eeuo pipefail
exec 2>&1

export OLD_DB="${OLD_DB:-pdns_azure}" ACCOUNT="${ACCOUNT:-nextdp}" TENANT_ID="${TENANT_ID:?TENANT_ID required}"
export SKIP_ZONES="${SKIP_ZONES:-}" DROP_IPS="${DROP_IPS:-}" DROP_HOSTS="${DROP_HOSTS:-}" IP_MAP="${IP_MAP:-}"
export KEY_ACCOUNT="${KEY_ACCOUNT:-$ACCOUNT}" DROP_IDP="${DROP_IDP:-1}" RESTORE_GOOGLE_MX="${RESTORE_GOOGLE_MX:-1}" REFS_FILE="${REFS_FILE:-}"
export DRY_RUN="${DRY_RUN:-1}" PLAN_TSV="${PLAN_TSV:-}"
[[ "$OLD_DB" =~ ^[a-z][a-z0-9_]*$ && "$ACCOUNT" =~ ^[a-z0-9-]+$ && "$KEY_ACCOUNT" =~ ^[a-z0-9-]+$ ]] || { echo "FATAL: invalid OLD_DB/ACCOUNT"; exit 1; }
[[ "$TENANT_ID" =~ ^[0-9a-f-]{36}$ ]] || { echo "FATAL: invalid TENANT_ID"; exit 1; }
[[ -z "$PLAN_TSV" || "$PLAN_TSV" == /tmp/dns-import-*.tsv ]] || { echo "FATAL: PLAN_TSV must be /tmp/dns-import-*.tsv"; exit 1; }
SECRETS="/root/.dns-${KEY_ACCOUNT}-secrets.env"
sudo test -f "$SECRETS" || { echo "FATAL: $SECRETS missing"; exit 1; }
cd /tmp

sudo -E python3 - <<'PY'
import json, os, re, subprocess, sys, urllib.error, urllib.request

E = os.environ
DRY = E["DRY_RUN"] != "0"
BASE = "http://127.0.0.1:8080/api/v1"
skip_zones = set(E["SKIP_ZONES"].split())
drop_ips = set(E["DROP_IPS"].split())
drop_hosts = {h.rstrip(".").lower() for h in E["DROP_HOSTS"].split()}
ip_map = dict(p.split("=", 1) for p in E["IP_MAP"].split())
refs = {}
if E.get("REFS_FILE") and os.path.exists(E["REFS_FILE"]):
    for line in open(E["REFS_FILE"]):
        if "\t" in line:
            f, r = line.rstrip("\n").split("\t", 1)
            refs[f.lower()] = r

key = ""
for line in open(f"/root/.dns-{E['KEY_ACCOUNT']}-secrets.env"):
    if line.startswith("NEXTDP_API_KEY=") or line.startswith("API_KEY="):
        key = line.split("=", 1)[1].strip().strip('"')
if not key:
    sys.exit("FATAL: tenant API key not found in the secrets file")

def api(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(BASE + path, data=data, method=method,
                                 headers={"X-API-Key": key, "Accept": "application/json", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read() or b"{}")
        except Exception:
            return e.code, {}

def psql_json(db, sql):
    out = subprocess.run(["sudo", "-u", "postgres", "psql", "-p", "5432", "-d", db, "-XAt", "-v", "ON_ERROR_STOP=1", "-c", sql],
                         text=True, capture_output=True, check=True).stdout.strip()
    return json.loads(out or "null")

st, who = api("GET", "/whoami")
w = (who.get("data") or {}) if st == 200 else {}
if w.get("tenant_id") != E["TENANT_ID"]:
    sys.exit(f"FATAL: API key belongs to tenant {w.get('tenant_id')} ({w.get('account')}), expected {E['TENANT_ID']}")
print(f"tenant {w.get('account')} {w.get('tenant_id')}; DRY_RUN={int(DRY)}")

old = psql_json(E["OLD_DB"], f"""
  SELECT json_agg(json_build_object('zone', d.name, 'records',
    (SELECT COALESCE(json_agg(json_build_object('name', r.name, 'type', r.type, 'content', r.content, 'ttl', r.ttl,
                                                'prio', r.prio, 'disabled', r.disabled)), '[]')
       FROM records r WHERE r.domain_id = d.id AND r.type IS NOT NULL)) ORDER BY d.name)
  FROM domains d WHERE d.account = '{E['ACCOUNT']}'""") or []
all_live = {z["fqdn"]: z for z in (psql_json("dns_db", """
  SELECT json_agg(json_build_object('fqdn', z.fqdn, 'id', z.id, 'tenant_id', z.tenant_id, 'ref', z.ref, 'status', z.status))
  FROM dns_zones z WHERE z.deleted_at IS NULL""") or [])}

SUPPORTED = {"A", "AAAA", "CNAME", "MX", "TXT", "SRV", "CAA", "NS"}
plan_rows, totals = [], {}
def note(zone, name, rtype, action, values=""):
    plan_rows.append((zone, name, rtype, action, values))
    totals[action] = totals.get(action, 0) + 1

def rrsets_of(zone, records):
    sets = {}
    for r in records:
        t, name = r["type"], r["name"].rstrip(".").lower()
        if t == "SOA" or (t == "NS" and name == zone):
            continue
        val = f"{r['prio']} {r['content']}" if t in ("MX", "SRV") else r["content"]
        if r["disabled"]:
            note(zone, name, t, "drop: disabled", val); continue
        if t not in SUPPORTED:
            note(zone, name, t, "drop: type not supported", val); continue
        if name in drop_hosts:
            note(zone, name, t, "drop: brand host", val); continue
        if E["DROP_IDP"] == "1" and ((t == "TXT" and name.startswith("_n1-verify.")) or (t == "CNAME" and ".n1id." in "." + val)):
            note(zone, name, t, "drop: iDP record", val); continue
        if t in ("A", "AAAA"):
            if val in drop_ips:
                note(zone, name, t, "drop: old Azure IP", val); continue
            if val in ip_map:
                note(zone, name, t, "ip rewrite", f"{val} -> {ip_map[val]}")
                val = ip_map[val]
        s = sets.setdefault((name, t), {"ttl": r["ttl"] or 3600, "values": []})
        s["ttl"] = min(s["ttl"], r["ttl"] or 3600)
        if val not in s["values"]:
            s["values"].append(val)
    for s in sets.values():
        s["ttl"] = max(60, min(86400, int(s["ttl"])))
    return sets

def canon(t, v):
    v = v.strip().rstrip(".").lower() if t in ("CNAME", "NS", "A", "AAAA") else v.strip()
    if t in ("MX", "SRV"):
        parts = v.split()
        v = " ".join(parts[:-1] + [parts[-1].rstrip(".").lower()])
    if t == "TXT" and v.startswith('"'):
        # pdns may hold a long value as several "..." "..." strings (DKIM); compare the joined value
        v = "".join(chunk.strip('"').replace('\\"', '"') for chunk in v.split('" "'))
    return v

def delegation(zone):
    """Public NS of the zone right now (via 1.1.1.1), grouped: ours / cloudflare / other / none."""
    # Ask a nameserver of the parent zone (registrar delegation), so a domain that points at our
    # NS but whose zone is not served yet still shows as "ours" instead of failing via a resolver.
    # Names end with "." because dig reads a bare "in" as the query class.
    def run(args):
        try:
            return subprocess.run(["dig", "+time=3", "+tries=1"] + args, text=True, capture_output=True, timeout=12).stdout
        except Exception:
            return ""
    parent = zone.split(".", 1)[1] if "." in zone else zone
    pns = [l.strip() for l in run(["+short", "NS", parent + ".", "@1.1.1.1"]).splitlines() if l.strip().endswith(".")]
    out = []
    for p in pns[:2]:
        auth = run(["+norecurse", "+noall", "+authority", "+answer", "NS", zone + ".", "@" + p.rstrip(".")])
        out = [l.split()[-1] for l in auth.splitlines() if "\tNS\t" in l or " NS " in l]
        if out:
            break
    ns = sorted({h.rstrip(".").lower() for h in out if re.match(r"^[a-z0-9.-]+\.$", h.lower())})
    if not ns:
        return "none/unregistered"
    if all(h.endswith(".nextdp.com") and h.startswith("ns") for h in ns):
        return "ours (" + ",".join(ns) + ")"
    if all(h.endswith("ns.cloudflare.com") for h in ns):
        return "cloudflare"
    return "other (" + ",".join(ns) + ")"

errors = 0
for z in old:
    zone = z["zone"].rstrip(".").lower()
    note(zone, "-", "NS", "public delegation: " + delegation(zone))
    if zone in skip_zones:
        note(zone, "-", "-", "skip zone (SKIP_ZONES)"); continue
    sets = rrsets_of(zone, z["records"])
    live = all_live.get(zone)
    ref = refs.get(zone, "azure-import")
    if live and live["tenant_id"] != E["TENANT_ID"]:
        note(zone, "-", "-", f"CONFLICT: zone is live in another tenant {live['tenant_id']}"); errors += 1; continue
    if not live:
        note(zone, "-", "-", f"create zone (ref {ref})")
        zid = None
        if not DRY:
            st, res = api("POST", "/zones", {"fqdn": zone, "ref": ref, "seed_scan": False})
            zid = ((res.get("data") or {}).get("zone") or {}).get("id")
            if st not in (200, 201) or not zid:
                note(zone, "-", "-", f"ERROR create zone HTTP {st}: {(res.get('error') or res)}"); errors += 1; continue
        live_sets = {}
    else:
        zid = live["id"]
        if ref != "azure-import" and live.get("ref") != ref:
            note(zone, "-", "-", f"set ref {live.get('ref')} -> {ref}")
            if not DRY:
                st, res = api("PATCH", f"/zones/{zid}", {"ref": ref})
                if st != 200:
                    note(zone, "-", "-", f"ERROR set ref HTTP {st}"); errors += 1
        st, res = api("GET", f"/zones/{zid}/records?fresh=1")
        if st != 200:
            note(zone, "-", "-", f"ERROR list live records HTTP {st}"); errors += 1; continue
        live_sets = {(r["name"].lower(), r["type"]): [canon(r["type"], v) for v in r["values"]] for r in (res.get("data") or {}).get("records", [])}

    # CNAME first is not required; write order: non-CNAME then CNAME (coexistence errors are reported).
    for (name, t), s in sorted(sets.items(), key=lambda kv: (kv[0][1] == "CNAME", kv[0])):
        vals = s["values"]
        action = "add"
        if (name, t) in live_sets:
            same = sorted(canon(t, v) for v in vals) == sorted(live_sets[(name, t)])
            google = t == "MX" and any("google.com" in v.lower() for v in vals)
            if same:
                note(zone, name, t, "keep: live already equal", " | ".join(vals)); continue
            if google and E["RESTORE_GOOGLE_MX"] == "1":
                action = "restore Google MX (live had " + " | ".join(live_sets[(name, t)]) + ")"
            else:
                note(zone, name, t, "keep live (old differs)", "old: " + " | ".join(vals)); continue
        if t == "CNAME" and any(k[0] == name and k[1] != "CNAME" for k in list(sets) + list(live_sets)):
            note(zone, name, t, "ERROR: CNAME next to other records at the same name", " | ".join(vals)); errors += 1; continue
        note(zone, name, t, action, " | ".join(vals))
        if not DRY:
            st, res = api("PUT", f"/zones/{zid}/records", {"name": name, "type": t, "ttl": str(s["ttl"]), "values": vals})
            if st != 200:
                note(zone, name, t, f"ERROR write HTTP {st}: {res.get('error') or res}", " | ".join(vals)); errors += 1

print("== totals")
for k in sorted(totals):
    print(f"  {totals[k]:5}  {k}")
zones = [r for r in plan_rows if r[3].startswith("create zone")]
print(f"zones in {E['OLD_DB']} account {E['ACCOUNT']}: {len(old)}; new zones: {len(zones)}; errors: {errors}")
if E.get("PLAN_TSV"):
    with open(E["PLAN_TSV"], "w") as fh:
        for r in plan_rows:
            fh.write("\t".join(r) + "\n")
    os.chmod(E["PLAN_TSV"], 0o644)
sys.exit(1 if errors and not DRY else 0)
PY
