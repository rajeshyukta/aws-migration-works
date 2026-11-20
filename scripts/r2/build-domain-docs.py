#!/usr/bin/env python3
"""Write the two domain inventory docs from the JSON exports of make-domain-docs.ps1.

  docs/azure-r2-brands-and-domains.md  NextDP Core brands (nextdp_core_r2) and every domain per brand
  docs/azure-r2-dns-zones.md           dns-service tenants and zones (dns_service_r2)

Both docs also show what exists on AWS now (live nextdp_core, live dns_db, live pdns).
Pure function of the two JSON files: rerunning gives the same docs for the same input.
"""
import argparse
import json
import os
from collections import Counter, defaultdict

PLATFORM_BRAND = "00000000-0000-7000-8000-000000000000"
ZONE_STATUS_ORDER = ["active", "awaiting_ns", "detached", "expired"]


def load(path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def day(ts):
    return (ts or "")[:10] or "-"


def cell(v):
    s = "-" if v in (None, "", []) else str(v)
    return s.replace("|", "\\|").replace("\n", " ")


def table(headers, rows):
    out = ["| " + " | ".join(headers) + " |", "|" + "|".join("---" for _ in headers) + "|"]
    out += ["| " + " | ".join(cell(c) for c in r) + " |" for r in rows]
    return out


def apex_of(host, known):
    """Longest known domain that host equals or is a subdomain of."""
    best = None
    for d in known:
        if host == d or host.endswith("." + d):
            if best is None or len(d) > len(best):
                best = d
    return best


def build(brands_doc, dns_doc):
    src, live = brands_doc["source"], brands_doc["live"]
    dsrc, dlive, pdns = dns_doc["source"], dns_doc["live"], dns_doc["pdns"]

    brands = src["brands"]
    brand_by_id = {b["id"]: b for b in brands}
    users = {u["id"]: u for u in src["users"]}

    def brand_label(bid):
        if bid in brand_by_id:
            return brand_by_id[bid]["slug"]
        if bid == PLATFORM_BRAND:
            return "(platform, no brand)"
        return f"(unknown brand {str(bid)[:8]})"

    def owner(uid):
        u = users.get(uid or "")
        if not u:
            return "-"
        return (u.get("email") or u.get("name") or f"user {uid[:8]}") + (" (deleted)" if u.get("deleted") else "")

    def user_brand(uid):
        u = users.get(uid or "")
        return u["brand_id"] if u else None

    # Old dns-service zones (by fqdn) and live AWS state.
    tenant_slug = {t["id"]: t["slug"] for t in dsrc["tenants"]}
    old_zone = {}
    for z in dsrc["zones"]:
        old_zone.setdefault(z["fqdn"], []).append(z)
    live_tenant_slug = {t["id"]: t["slug"] for t in dlive["tenants"]}
    live_zone = {z["fqdn"]: z for z in dlive["zones"] if not z["deleted"]}
    pdns_zone = {z["name"].rstrip("."): z for z in pdns["zones"]}
    live_core = set(live["domains"]) | set(live["external_domains"]) | set(live["dns_zones"])
    live_brand_slugs = {b["slug"] for b in live["brands"]}
    live_hosts = set()
    for b in live["brands"]:
        live_hosts |= {b.get("primary_domain"), b.get("admin_domain"), b.get("console_domain")}

    def old_dns_cell(fqdn):
        zs = old_zone.get(fqdn)
        if not zs:
            return "-"
        return "; ".join(
            f"{tenant_slug.get(z['tenant_id'], '?')}: {z['status']}" + (" (deleted)" if z["deleted"] else "")
            for z in zs)

    def aws_cell(fqdn):
        parts = []
        if fqdn in pdns_zone:
            z = pdns_zone[fqdn]
            parts.append(f"DNS VM zone ({z['records']} rec, A {z['apex_a'] or '-'})")
        if fqdn in live_core:
            parts.append("NextDP Core")
        return ", ".join(parts) or "no"

    # Collect every domain per brand.
    per_brand = defaultdict(dict)  # brand_id -> fqdn -> info

    def slot(bid, fqdn):
        return per_brand[bid].setdefault(fqdn, {"registered": None, "external": None, "zone": None, "sites": [], "owner": set()})

    for d in src["domains"]:
        bid = d["brand_id"] or user_brand(d["user_id"]) or PLATFORM_BRAND
        s = slot(bid, d["fqdn"])
        s["registered"] = d
        s["owner"].add(owner(d["user_id"]))
    for e in src["external_domains"]:
        bid = user_brand(e["user_id"]) or PLATFORM_BRAND
        s = slot(bid, e["fqdn"])
        s["external"] = e
        s["owner"].add(owner(e["user_id"]))
    for z in src["dns_zones"]:
        bid = z["brand_id"] or user_brand(z["user_id"]) or PLATFORM_BRAND
        s = slot(bid, z["fqdn"])
        s["zone"] = z
        s["owner"].add(owner(z["user_id"]))
    for site in src["sites"]:
        bid = site["brand_id"] or user_brand(site["user_id"]) or PLATFORM_BRAND
        host = (site["host"] or "").lower()
        apex = apex_of(host, per_brand[bid].keys()) or host
        s = slot(bid, apex)
        s["sites"].append(site)
        s["owner"].add(owner(site["user_id"]))

    brand_ids = [b["id"] for b in brands] + sorted(k for k in per_brand if k not in brand_by_id)
    users_per_brand = Counter(u["brand_id"] for u in src["users"] if not u.get("deleted"))
    feats = defaultdict(list)
    for f in src["features"]:
        if f["is_enabled"]:
            feats[f["brand_id"]].append(f["feature_key"])
    conns = src["connections"]

    # ---------------- brands doc ----------------
    L = []
    L.append("# Azure NextDP Core: brands and their domains (from the R2 backup)")
    L.append("")
    L.append("**Generated file, do not edit by hand.** Rebuild with `scripts/r2/make-domain-docs.ps1` "
             "(see [`azure-r2-restore.md`](azure-r2-restore.md)).")
    L.append("")
    L.append(f"- **Source:** {src['comment']}. Staged read-only as `{src['database']}` on Apps-Core-VM.")
    L.append(f"- **Exported:** {brands_doc['generated_at']}.")
    L.append(f"- **AWS now:** live `nextdp_core` has {len(live['brands'])} brand(s): "
             + ", ".join(f"`{b['slug']}` ({b['admin_domain']}, {b['console_domain']})" for b in live["brands"])
             + f"; {len(live_core)} customer domains. The DNS VM serves {len(pdns_zone)} zones.")
    L.append(f"- **Totals in the backup:** {len(brands)} brands, {len(src['domains'])} registered domains, "
             f"{len(src['external_domains'])} external domains, {len(src['dns_zones'])} DNS zones, "
             f"{len(src['sites'])} sites, {len(src['users'])} users.")
    L.append("")
    L.append("Columns in the per-brand tables:")
    L.append("- **Registered**: a domain bought/managed through the brand (`domains`): status, expiry, provider, nameservers.")
    L.append("- **External**: a customer's own domain added for verification (`external_domains`).")
    L.append("- **Core DNS zone**: the brand's DNS hosting record in NextDP Core (`dns_zones`).")
    L.append("- **Azure dns-service**: the zone in the old dns-service (tenant: status), see [`azure-r2-dns-zones.md`](azure-r2-dns-zones.md).")
    L.append("- **Sites**: LocalCen/blog/docs/handcraft sites on that domain or a subdomain.")
    L.append("- **On AWS now**: whether the new DNS VM serves the zone, or live NextDP Core has the domain.")
    L.append("")
    L.append("## Summary")
    L.append("")
    rows = []
    for bid in brand_ids:
        b = brand_by_id.get(bid)
        items = per_brand.get(bid, {}).values()
        rows.append([
            f"`{brand_label(bid)}`", b["name"] if b else "-", b["primary_product"] if b else "-",
            " / ".join(x or "-" for x in (b["primary_domain"], b["admin_domain"], b["console_domain"], b["idp_host"])) if b else "-",
            b["idp_status"] if b else "-", users_per_brand.get(bid, 0),
            sum(1 for i in items if i["registered"]), sum(1 for i in items if i["external"]),
            sum(1 for i in items if i["zone"]), sum(len(i["sites"]) for i in items),
            ("brand exists" if b and b["slug"] in live_brand_slugs else "no"),
        ])
    L += table(["Brand", "Name", "Primary product", "Hosts: primary / admin / console / accounts", "Sign-in (iDP)",
                "Users", "Registered", "External", "Core DNS zones", "Sites", "On AWS now"], rows)
    L.append("")
    L.append("## Brand service connections (no secrets)")
    L.append("")
    L += table(["Brand", "Kind", "Base URL", "Nameservers", "Active"],
               [[f"`{brand_label(c['brand_id'])}`", c["kind"], c["base_url"],
                 " ".join((c["nameservers"] or "").split()), "yes" if c["active"] else "no"] for c in conns])
    L.append("")

    for n, bid in enumerate(brand_ids, 1):
        b = brand_by_id.get(bid)
        items = per_brand.get(bid, {})
        title = f"{b['name']} (`{b['slug']}`)" if b else brand_label(bid)
        L.append(f"## {n}. {title}")
        L.append("")
        if b:
            L.append(f"- Brand id `{bid}`, status `{b['status']}`, created {day(b['created_at'])}, primary product `{b['primary_product']}`.")
            hosts = [("primary", b["primary_domain"]), ("admin", b["admin_domain"]), ("console", b["console_domain"]), ("accounts (iDP)", b["idp_host"])]
            L.append("- Brand hosts: " + ", ".join(f"{k} `{v}`" for k, v in hosts if v)
                     + (" (no primary domain set)" if not b["primary_domain"] else ""))
            L.append(f"- Sender: `{b['sender_email'] or '-'}`. Brand nameservers: `{' '.join((b['nameservers'] or '').split()) or '-'}`.")
            L.append(f"- Features on: {', '.join(sorted(feats.get(bid, []))) or '-'}.")
            L.append(f"- Users: {users_per_brand.get(bid, 0)}. On AWS now: "
                     + ("brand exists in live NextDP Core." if b["slug"] in live_brand_slugs else "not created yet."))
        else:
            L.append(f"- Brand id `{bid}` has no row in `brands`; these domains belong to users with that brand id.")
        L.append("")
        if not items:
            L.append("No customer domains.")
            L.append("")
            continue
        rows = []
        for i, fqdn in enumerate(sorted(items), 1):
            it = items[fqdn]
            r = it["registered"]
            reg = f"{r['status']}, exp {day(r['expires_at'])}, {r['provider'] or '-'}, NS {r['nameservers'] or '-'}" if r else "-"
            e = it["external"]
            ext = f"{e['status']}" + (f" {day(e['verified_at'])}" if e and e.get("verified_at") else "") if e else "-"
            z = it["zone"]
            zone = f"{z['status']} ({z['source']})" if z else "-"
            sites = ", ".join(f"{s['kind']}: {s['host']} ({s['status']}, {s['dns_status']})" for s in it["sites"]) or "-"
            rows.append([i, f"`{fqdn}`", reg, ext, zone, old_dns_cell(fqdn), sites, aws_cell(fqdn),
                         ", ".join(sorted(o for o in it["owner"] if o != "-")) or "-"])
        L += table(["#", "Domain", "Registered", "External", "Core DNS zone", "Azure dns-service", "Sites",
                    "On AWS now", "Owner"], rows)
        L.append("")

    brands_md = "\n".join(L) + "\n"

    # ---------------- DNS doc ----------------
    core_brand_of = {}
    for bid, items in per_brand.items():
        for fqdn in items:
            core_brand_of.setdefault(fqdn, set()).add(brand_label(bid))
    for b in brands:
        for h in (b["primary_domain"], b["admin_domain"], b["console_domain"]):
            if h:
                core_brand_of.setdefault(h, set()).add(f"{b['slug']} (brand host)")

    zones_by_tenant = defaultdict(list)
    for z in dsrc["zones"]:
        zones_by_tenant[z["tenant_id"]].append(z)

    D = []
    D.append("# Azure dns-service: tenants and DNS zones (from the R2 backup)")
    D.append("")
    D.append("**Generated file, do not edit by hand.** Rebuild with `scripts/r2/make-domain-docs.ps1` "
             "(see [`azure-r2-restore.md`](azure-r2-restore.md)).")
    D.append("")
    D.append(f"- **Source:** {dsrc['comment']}. Staged read-only as `{dsrc['database']}` on the DNS VM.")
    D.append(f"- **Exported:** {dns_doc['generated_at']}.")
    D.append(f"- **Totals in the backup:** {len(dsrc['tenants'])} tenants, {len(dsrc['zones'])} zones "
             f"({sum(1 for z in dsrc['zones'] if z['deleted'])} soft-deleted). Super admins: "
             + ", ".join(f"`{a}`" for a in dsrc["super_admins"]) + ".")
    D.append(f"- **AWS now:** live `dns_db` has tenants " + ", ".join(f"`{t['slug']}`" for t in dlive["tenants"])
             + f" and {len(live_zone)} zones; PowerDNS (`pdns`) serves {len(pdns_zone)} zones.")
    D.append("- **Records are not in this backup.** dns-service keeps only the zone list and lifecycle; the records "
             "lived in the PowerDNS `pdns` database on the Azure DNS VMs (`nmc-dns-1/2`), which NMC did not back up "
             "to R2. A zone moved to AWS gets its records from the owner or from the brand's defaults.")
    D.append("")
    D.append("Zone status (dns-service): `active` = delegation to the tenant's nameservers confirmed; "
             "`awaiting_ns` = claimed, waiting for the NS change at the registrar; `detached` = was active, NS moved "
             "away; `expired` = 14 days without delegation.")
    D.append("")
    D.append("## Summary by tenant")
    D.append("")
    rows = []
    for t in dsrc["tenants"]:
        zs = zones_by_tenant.get(t["id"], [])
        c = Counter(z["status"] for z in zs if not z["deleted"])
        rows.append([f"`{t['slug']}`", t["name"], t["nameservers"].replace(",", " "), len(zs)]
                    + [c.get(s, 0) for s in ZONE_STATUS_ORDER]
                    + [sum(1 for z in zs if z["deleted"]), t["active_api_keys"], t["users"] or "-",
                       "yes" if t["slug"] in live_tenant_slug.values() else "no"])
    D += table(["Tenant", "Name", "Nameservers", "Zones", "active", "awaiting_ns", "detached", "expired", "deleted",
                "API keys", "Users", "Tenant on AWS"], rows)
    D.append("")

    for n, t in enumerate(dsrc["tenants"], 1):
        zs = sorted(zones_by_tenant.get(t["id"], []), key=lambda z: (z["deleted"], ZONE_STATUS_ORDER.index(z["status"]) if z["status"] in ZONE_STATUS_ORDER else 9, z["fqdn"]))
        D.append(f"## {n}. Tenant `{t['slug']}` ({t['name']})")
        D.append("")
        D.append(f"- Nameservers `{t['nameservers']}`, SOA contact `{t['soa_contact'] or '-'}`, status `{t['status']}`, "
                 f"created {day(t['created_at'])}, webhook to `{t['webhook_host'] or '-'}`, require connect {t['require_connect']}.")
        D.append("")
        if not zs:
            D.append("No zones.")
            D.append("")
            continue
        rows = []
        for i, z in enumerate(zs, 1):
            lz = live_zone.get(z["fqdn"])
            aws = []
            if lz:
                aws.append(f"dns_db: {live_tenant_slug.get(lz['tenant_id'], '?')} {lz['status']}")
            if z["fqdn"] in pdns_zone:
                p = pdns_zone[z["fqdn"]]
                aws.append(f"pdns {p['records']} rec, A {p['apex_a'] or '-'}")
            rows.append([i, f"`{z['fqdn']}`", z["status"] + (" (deleted)" if z["deleted"] else ""), day(z["delegated_at"]),
                         day(z["created_at"]), z["source"], ", ".join(sorted(core_brand_of.get(z["fqdn"], []))) or "-",
                         "; ".join(aws) or "no"])
        D += table(["#", "Zone", "Status", "Delegated", "Claimed", "Source", "NextDP Core brand", "On AWS now"], rows)
        D.append("")

    old_fqdns = set(old_zone)
    new_only = sorted(set(pdns_zone) - old_fqdns)
    D.append("## Zones on AWS that were not in the Azure dns-service")
    D.append("")
    if new_only:
        D += table(["Zone", "pdns records", "Apex A", "Apex MX", "dns_db tenant"],
                   [[f"`{f}`", pdns_zone[f]["records"], pdns_zone[f]["apex_a"], pdns_zone[f]["apex_mx"],
                     live_tenant_slug.get(live_zone[f]["tenant_id"], "?") if f in live_zone else "-"] for f in new_only])
    else:
        D.append("None.")
    D.append("")
    D.append("## Zone transfers between tenants (Azure)")
    D.append("")
    D += table(["When", "Zone", "From", "To", "Redelegated"],
               [[day(x["created_at"]), f"`{x['fqdn']}`", tenant_slug.get(x["from_tenant_id"], "?"),
                 tenant_slug.get(x["to_tenant_id"], "?"), "yes" if x["redelegated"] else "no"] for x in dsrc["transfers"]])
    D.append("")
    dns_md = "\n".join(D) + "\n"
    return brands_md, dns_md


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--brands-json", required=True)
    ap.add_argument("--dns-json", required=True)
    ap.add_argument("--out-dir", required=True)
    a = ap.parse_args()
    brands_md, dns_md = build(load(a.brands_json), load(a.dns_json))
    for name, text in (("azure-r2-brands-and-domains.md", brands_md), ("azure-r2-dns-zones.md", dns_md)):
        path = os.path.join(a.out_dir, name)
        with open(path, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(text)
        print(f"wrote {path} ({text.count(chr(10))} lines)")


if __name__ == "__main__":
    main()
