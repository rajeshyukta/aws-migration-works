# Azure NextDP Core: brands and their domains (from the R2 backup)

**Generated file, do not edit by hand.** Rebuild with `scripts/r2/make-domain-docs.ps1` (see [`azure-r2-restore.md`](azure-r2-restore.md)).

- **Source:** R2 snapshot 468f8e88 of nextdp_core from nmc-db-1 taken 2026-11-18T03:15:41.274721536Z. Staged read-only as `nextdp_core_r2` on Apps-Core-VM.
- **Exported:** 2026-11-20T12:59:49Z.
- **AWS now:** live `nextdp_core` has 1 brand(s): `nextdp` (admin.nextdp.com, console.nextdp.com); 78 customer domains. The DNS VM serves 100 zones.
- **Totals in the backup:** 9 brands, 24 registered domains, 57 external domains, 70 DNS zones, 17 sites, 24 users.

Columns in the per-brand tables:
- **Registered**: a domain bought/managed through the brand (`domains`): status, expiry, provider, nameservers.
- **External**: a customer's own domain added for verification (`external_domains`).
- **Core DNS zone**: the brand's DNS hosting record in NextDP Core (`dns_zones`).
- **Azure dns-service**: the zone in the old dns-service (tenant: status), see [`azure-r2-dns-zones.md`](azure-r2-dns-zones.md).
- **Sites**: LocalCen/blog/docs/handcraft sites on that domain or a subdomain.
- **On AWS now**: whether the new DNS VM serves the zone, or live NextDP Core has the domain.

## Summary

| Brand | Name | Primary product | Hosts: primary / admin / console / accounts | Sign-in (iDP) | Users | Registered | External | Core DNS zones | Sites | On AWS now |
|---|---|---|---|---|---|---|---|---|---|---|
| `presencive` | Presencive | domains | presencive.com / admin.presencive.com / console.presencive.com / accounts.presencive.com | live | 5 | 10 | 11 | 13 | 9 | no brand; 21/21 domains in live NextDP Core |
| `nextdigital` | NextDigital | local | nextdigital.in / admin.nextdigital.in / console.nextdigital.in / accounts.nextdigital.in | live | 6 | 11 | 44 | 54 | 7 | no brand; 55/55 domains in live NextDP Core |
| `leadyourbiz` | Lead Your Biz | domains | leadyourbiz.com / admin.leadyourbiz.com / console.leadyourbiz.com / accounts.leadyourbiz.com | none | 2 | 1 | 0 | 1 | 0 | no brand; 1/1 domains in live NextDP Core |
| `digpre` | DigPre | domains | - / admin.digpre.com / console.digpre.com / accounts.digpre.com | none | 0 | 0 | 0 | 0 | 0 | no brand; 0/0 domains in live NextDP Core |
| `nextdp` | Next Digital Platforms | domains | nextdp.com / admin.nextdp.com / console.nextdp.com / accounts.nextdp.com | none | 2 | 2 | 0 | 0 | 0 | brand exists; 2/2 domains in live NextDP Core |
| `dpm` | YOUR DPM | domains | - / admin.yourdpm.com / yourdpm.com / accounts.yourdpm.com | none | 2 | 0 | 1 | 1 | 1 | no brand; 1/1 domains in live NextDP Core |
| `ogcen` | Organic Growth Center | domains | organicgrowth.center / admin.ogcen.com / my.ogcen.com / accounts.ogcen.com | live | 2 | 0 | 0 | 0 | 0 | no brand; 0/0 domains in live NextDP Core |
| `proseva` | ProSEVA | domains | proseva.org / admin.proseva.org / console.proseva.org / accounts.proseva.org | live | 2 | 0 | 1 | 1 | 0 | no brand; 1/1 domains in live NextDP Core |
| `localcen` | LocalCen | domains | localcen.com / admin.localcen.com / console.localcen.com / accounts.localcen.com | live | 2 | 0 | 0 | 0 | 0 | no brand; 0/0 domains in live NextDP Core |

## Brand service connections (no secrets)

| Brand | Kind | Base URL | Nameservers | Active |
|---|---|---|---|---|
| `presencive` | blog | https://blogs.cconsole.com/v1 | - | yes |
| `presencive` | dns | https://dns.cconsole.com | ns1.presencive.com ns2.presencive.com | yes |
| `presencive` | docs | https://docs-service.cconsole.com/v1 | - | yes |
| `presencive` | local | https://nextlocal.cconsole.com/v1 | - | yes |
| `nextdigital` | dns | https://dns.cconsole.com | ns1.nextdp.com ns2.nextdp.com | yes |
| `nextdigital` | local | https://localcen.cconsole.com/v1 | - | yes |
| `ogcen` | dns | https://dns.cconsole.com | ns1.ogcen.com ns2.ogcen.com | yes |
| `dpm` | blog | https://blogs.cconsole.com/v1 | - | yes |
| `dpm` | dns | https://dns.cconsole.com | ns1.yourdpm.com ns2.yourdpm.com | yes |
| `proseva` | dns | https://dns.cconsole.com | ns1.proseva.org ns2.proseva.org | yes |
| `leadyourbiz` | dns | https://dns.cconsole.com | ns1.leadyourbiz.com ns2.leadyourbiz.com | yes |

## 1. Presencive (`presencive`)

- Brand id `01900000-0000-7000-8000-000000000001`, status `active`, created 2026-07-28, primary product `domains`.
- Brand hosts: primary `presencive.com`, admin `admin.presencive.com`, console `console.presencive.com`, accounts (iDP) `accounts.presencive.com`
- Sender: `admin@presencive.com`. Brand nameservers: `ns1.presencive.com ns2.presencive.com`.
- Features on: blogs, dns, docs, domains, handcraft, idp_login, lms, local, store.
- Users: 5. On AWS now: brand not created; 21 of 21 domains are in live NextDP Core (moved into a live brand as external domains).

| # | Domain | Registered | External | Core DNS zone | Azure dns-service | Sites | On AWS now | Owner |
|---|---|---|---|---|---|---|---|---|
| 1 | `athomepg.in` | active, exp 2027-07-19, manual, NS ns1.presencive.com ns2.presencive.com | - | active (registered) | presencive: active | handcraft: athomepg.in (active, dns_ok) | DNS VM zone (5 rec, A 3.6.143.66), NextDP Core | guruvishnu609@gmail.com |
| 2 | `bharatgetonline.com` | - | verified 2026-07-28 | active (external) | presencive: active | - | DNS VM zone (3 rec, A -), NextDP Core | rajesh.yukta@gmail.com |
| 3 | `bhuvigeotech.co.in` | active, exp 2027-07-18, manual, NS ns1.presencive.com ns2.presencive.com | - | active (registered) | presencive: active | - | DNS VM zone (3 rec, A -), NextDP Core | sirasanagandlasreenivasulu@gmail.com |
| 4 | `firstvote.in` | - | verified 2026-07-01 | - | - | - | NextDP Core | rajesh.yukta@gmail.com |
| 5 | `halli.in` | - | verified 2026-10-28 | active (external) | presencive: active | docs: bangalore-test.halli.in (active, dns_ok), docs: docs.halli.in (active, dns_ok) | DNS VM zone (8 rec, A 3.6.143.66), NextDP Core | rajesh.yukta@gmail.com |
| 6 | `hargharme.com` | - | verified 2026-07-17 | active (external) | presencive: active | blog: blog.hargharme.com (active, dns_ok), docs: nextdocs.hargharme.com (active, dns_ok), docs: prodocs.hargharme.com (active, dns_ok) | DNS VM zone (10 rec, A -), NextDP Core | rajesh.yukta@gmail.com |
| 7 | `icfluence.com` | - | verified 2026-07-22 | active (external) | presencive: active | - | DNS VM zone (11 rec, A 20.244.35.68), NextDP Core | rajesh.yukta@gmail.com |
| 8 | `pureayurveda.in` | - | verified 2026-07-19 | active (external) | presencive: active | blog: blog.pureayurveda.in (active, dns_ok), handcraft: pureayurveda.in (active, dns_ok) | DNS VM zone (6 rec, A 3.6.143.66), NextDP Core | rajesh.yukta@gmail.com |
| 9 | `rajesh.co.in` | active, exp 2027-07-18, manual, NS ns1.presencive.com ns2.presencive.com | - | detached (registered) | presencive: detached | - | DNS VM zone (3 rec, A -), NextDP Core | rajesh.yukta@gmail.com |
| 10 | `rajesh.in` | active, exp 2027-07-18, manual, NS ns1.presencive.com ns2.presencive.com | - | detached (registered) | presencive: detached | - | DNS VM zone (3 rec, A -), NextDP Core | rajesh.yukta@gmail.com |
| 11 | `rajesh1.com` | - | verified 2026-07-18 | - | nextdp: active | - | NextDP Core | rajesh.yukta@gmail.com |
| 12 | `rajesh123.com` | active, exp 2027-07-18, cconsole, NS ns1.presencive.com ns2.presencive.com | - | - | - | - | NextDP Core | rajesh.yukta@gmail.com |
| 13 | `rajeshyukta.co` | active, exp 2027-07-03, cconsole, NS ns1.presencive.com ns2.presencive.com | - | - | - | - | NextDP Core | rajesh.yukta@gmail.com |
| 14 | `rajeshyukta.in` | - | verified 2026-07-09 | - | nextdp: active | blog: blog.rajeshyukta.in (active, pending_dns) | DNS VM zone (6 rec, A 3.6.143.66), NextDP Core | rajesh.yukta@gmail.com |
| 15 | `rajeshyukta.net` | active, exp 2027-07-03, manual, NS ns1.presencive.com ns2.presencive.com | - | - | - | - | NextDP Core | rajesh.yukta@gmail.com |
| 16 | `rajeshyukta.org` | active, exp 2027-07-01, manual, NS ns1.nextdp.com ns2.nextdp.com | - | - | - | - | NextDP Core | rajesh.yukta@gmail.com |
| 17 | `rajeshyukta.xyz` | active, exp 2027-07-03, manual, NS ns1.presencive.com ns2.presencive.com | - | - | - | - | NextDP Core | rajesh.yukta@gmail.com |
| 18 | `rapidbot.in` | - | verified 2026-07-21 | active (external) | presencive: active | - | DNS VM zone (20 rec, A 3.6.143.66), NextDP Core | rajesh.yukta@gmail.com |
| 19 | `srinivasulu.in` | active, exp 2027-07-18, manual, NS ns1.presencive.com ns2.presencive.com | - | active (registered) | presencive: active | - | DNS VM zone (3 rec, A -), NextDP Core | sirasanagandlasreenivasulu@gmail.com |
| 20 | `vayamhindu.com` | - | verified 2026-07-24 | active (external) | presencive: active | - | DNS VM zone (3 rec, A -), NextDP Core | rajesh.yukta@gmail.com |
| 21 | `vircto.com` | - | pending | awaiting_ns (external) | - | - | NextDP Core | rajesh.yukta@gmail.com |

## 2. NextDigital (`nextdigital`)

- Brand id `43a192be-9e73-4674-8691-e43dbb5b4255`, status `active`, created 2026-07-29, primary product `local`.
- Brand hosts: primary `nextdigital.in`, admin `admin.nextdigital.in`, console `console.nextdigital.in`, accounts (iDP) `accounts.nextdigital.in`
- Sender: `support@nextdigital.in`. Brand nameservers: `ns1.nextdp.com ns2.nextdp.com`.
- Features on: dns, domains, idp_login, local.
- Users: 6. On AWS now: brand not created; 55 of 55 domains are in live NextDP Core (moved into a live brand as external domains).

| # | Domain | Registered | External | Core DNS zone | Azure dns-service | Sites | On AWS now | Owner |
|---|---|---|---|---|---|---|---|---|
| 1 | `ac2.in` | - | verified 2026-09-25 | detached (external) | nextdp: detached | - | DNS VM zone (7 rec, A -), NextDP Core | rajesh@associate.works |
| 2 | `afterai.work` | - | verified 2026-09-24 | active (external) | nextdp: active | - | DNS VM zone (6 rec, A -), NextDP Core | rajesh@associate.works |
| 3 | `afteraiwork.com` | - | verified 2026-09-24 | active (external) | nextdp: active | - | DNS VM zone (9 rec, A 3.6.143.66), NextDP Core | rajesh@associate.works |
| 4 | `apimw.com` | - | verified 2026-09-24 | active (external) | nextdp: active | - | DNS VM zone (5 rec, A -), NextDP Core | rajesh@associate.works |
| 5 | `associate.works` | - | verified 2026-10-13 | active (external) | nextdp: active | - | DNS VM zone (7 rec, A -), NextDP Core | rajesh@associate.works |
| 6 | `cconsole.com` | - | verified 2026-10-16 | active (external) | nextdp: active | - | DNS VM zone (23 rec, A 3.6.143.66), NextDP Core | rajesh@associate.works |
| 7 | `constituency.in` | - | verified 2026-11-09 | active (external) | nextdp: active | - | DNS VM zone (6 rec, A 3.6.143.66), NextDP Core | rajesh@associate.works |
| 8 | `cyjago.com` | - | verified 2026-10-21 | active (external) | nextdp: active | - | DNS VM zone (3 rec, A -), NextDP Core | rajesh@associate.works |
| 9 | `daiskills.com` | - | verified 2026-10-12 | active (external) | nextdp: active | - | DNS VM zone (9 rec, A 3.6.143.66), NextDP Core | rajesh@associate.works |
| 10 | `dithim.com` | - | verified 2026-09-03 | active (external) | nextdp: active | - | NextDP Core | rajesh@associate.works |
| 11 | `esangh.com` | - | verified 2026-11-17 | active (external) | - | - | DNS VM zone (8 rec, A -), NextDP Core | rajesh@associate.works |
| 12 | `factgrid.in` | - | verified 2026-08-16 | active (external) | nextdp: active | - | DNS VM zone (4 rec, A -), NextDP Core | rajesh@associate.works |
| 13 | `forbharat.in` | - | verified 2026-10-20 | active (external) | nextdp: active | - | DNS VM zone (6 rec, A 3.6.143.66), NextDP Core | rajesh@associate.works |
| 14 | `forbharat.org` | - | verified 2026-10-20 | active (external) | nextdp: active | - | DNS VM zone (6 rec, A 3.6.143.66), NextDP Core | rajesh@associate.works |
| 15 | `foryourattention.com` | active, exp 2027-04-21, manual, NS ns1.nextdp.com ns2.nextdp.com | - | detached (registered) | nextdp: detached | - | DNS VM zone (5 rec, A 3.6.143.66), NextDP Core | rajesh@associate.works |
| 16 | `gramam.in` | - | verified 2026-11-06 | active (external) | nextdp: active | - | DNS VM zone (8 rec, A 3.6.143.66), NextDP Core | rajesh@associate.works |
| 17 | `harghar.me` | - | verified 2026-10-21 | detached (external) | nextdp: detached | - | DNS VM zone (3 rec, A -), NextDP Core | rajesh@associate.works |
| 18 | `jyothularajesh.com` | active, exp 2027-09-13, manual, NS ns1.nextdp.com ns2.nextdp.com | - | active (registered) | nextdp: active | handcraft: jyothularajesh.com (crafting, dns_ok) | DNS VM zone (6 rec, A 3.6.143.66), NextDP Core | jyothularajesh9@gmail.com |
| 19 | `lewiai.com` | - | verified 2026-10-19 | active (external) | nextdp: active | - | DNS VM zone (7 rec, A 3.6.143.66), NextDP Core | rajesh@associate.works |
| 20 | `live.care` | active, exp 2027-11-10, manual, NS ns1.nextdp.com ns2.nextdp.com | - | detached (registered) | nextdp: detached | - | DNS VM zone (6 rec, A 3.6.143.66), NextDP Core | rajesh@associate.works |
| 21 | `localcen.com` | - | verified 2026-11-07 | active (external) | nextdp: active | - | DNS VM zone (6 rec, A 3.6.143.66), NextDP Core | rajesh@associate.works |
| 22 | `mananiya.com` | - | verified 2026-09-07 | active (external) | nextdp: active | - | DNS VM zone (8 rec, A -), NextDP Core | rajesh@associate.works |
| 23 | `mrajesh.com` | - | verified 2026-11-15 | active (external) | nextdp: active | - | DNS VM zone (8 rec, A 3.6.143.66), NextDP Core | rajesh@associate.works |
| 24 | `navabharatiyam.com` | - | verified 2026-10-21 | active (external) | nextdp: active | - | DNS VM zone (3 rec, A -), NextDP Core | rajesh@associate.works |
| 25 | `navduta.com` | - | verified 2026-10-11 | active (external) | nextdp: active | - | DNS VM zone (8 rec, A 3.6.143.66), NextDP Core | rajesh@associate.works |
| 26 | `nextidp.com` | - | verified 2026-10-02 | active (external) | nextdp: active | - | DNS VM zone (11 rec, A 43.204.42.99), NextDP Core | rajesh@associate.works |
| 27 | `nextlocal.in` | - | verified 2026-10-16 | active (external) | nextdp: active | local: ailapur.nextlocal.in (active, dns_ok), local: chinnametpallu.nextlocal.in (active, dns_ok), local: mohanraopet.nextlocal.in (active, dns_ok), local: nexttest.nextlocal.in (active, dns_ok) | DNS VM zone (7 rec, A -), NextDP Core | rajesh@associate.works |
| 28 | `nextskillclub.com` | - | verified 2026-11-10 | active (external) | nextdp: active | - | DNS VM zone (6 rec, A 3.6.143.66), NextDP Core | rajesh@associate.works |
| 29 | `nextventure.in` | active, exp 2027-06-12, manual, NS ns1.nextdp.com ns2.nextdp.com | - | active (registered) | nextdp: active | - | DNS VM zone (3 rec, A -), NextDP Core | rajesh@associate.works |
| 30 | `onesign.in` | active, exp 2027-06-06, manual, NS ns1.nextdp.com ns2.nextdp.com | - | active (registered) | nextdp: active | - | DNS VM zone (3 rec, A -), NextDP Core | rajesh@associate.works |
| 31 | `padmashali.org` | - | verified 2026-10-25 | active (external) | nextdp: active | - | DNS VM zone (6 rec, A 3.6.143.66), NextDP Core | rajesh@associate.works |
| 32 | `panchang.io` | - | verified 2026-10-31 | active (external) | nextdp: active | - | DNS VM zone (7 rec, A 3.6.143.66), NextDP Core | rajesh@associate.works |
| 33 | `pattanam.in` | - | verified 2026-11-09 | active (external) | nextdp: active | - | DNS VM zone (4 rec, A -), NextDP Core | rajesh@associate.works |
| 34 | `promptation.ai` | - | verified 2026-11-13 | active (external) | nextdp: active | - | DNS VM zone (19 rec, A 3.6.143.66), NextDP Core | rajesh@associate.works |
| 35 | `proseva.org` | active, exp 2027-08-09, manual, NS ns1.nextdp.com ns2.nextdp.com | - | detached (registered) | proseva: detached | - | DNS VM zone (9 rec, A 3.6.143.66), NextDP Core | rajesh@associate.works |
| 36 | `rajesh.app` | - | verified 2026-08-10 | active (external) | nextdp: active | - | DNS VM zone (8 rec, A 3.6.143.66), NextDP Core | rajesh@associate.works |
| 37 | `rajesh.one` | - | verified 2026-09-24 | active (external) | nextdp: active | - | NextDP Core | rajesh@associate.works |
| 38 | `rajesh.works` | - | verified 2026-08-04 | detached (external) | nextdp: detached | - | DNS VM zone (5 rec, A -), NextDP Core | rajesh@associate.works |
| 39 | `rajesh1.com` | - | verified 2026-10-26 | detached (external) | nextdp: active | - | NextDP Core | rajesh@associate.works |
| 40 | `rajeshone.com` | - | verified 2026-08-14 | active (external) | nextdp: active | - | NextDP Core | rajesh@associate.works |
| 41 | `rajeshyukta.in` | - | verified 2026-09-25 | active (external) | nextdp: active | - | DNS VM zone (6 rec, A 3.6.143.66), NextDP Core | rajesh@associate.works |
| 42 | `securedbot.in` | - | verified 2026-08-05 | detached (external) | nextdp: detached | - | DNS VM zone (3 rec, A -), NextDP Core | rajesh@associate.works |
| 43 | `softskills.training` | - | verified 2026-10-13 | active (external) | nextdp: active | - | DNS VM zone (9 rec, A 3.6.143.66), NextDP Core | rajesh@associate.works |
| 44 | `srikalabhairavam.com` | active, exp 2027-08-03, manual, NS ns1.nextdp.com ns2.nextdp.com | - | active (registered) | nextdp: active | - | DNS VM zone (13 rec, A 3.6.143.66), NextDP Core | kishoreavrk@gmail.com |
| 45 | `srikalabhairavam.in` | active, exp 2027-08-03, manual, NS ns1.nextdp.com ns2.nextdp.com | - | active (registered) | nextdp: active | - | DNS VM zone (6 rec, A 3.6.143.66), NextDP Core | kishoreavrk@gmail.com |
| 46 | `startuphouse.in` | active, exp 2027-02-23, manual, NS ns1.nextdp.com ns2.nextdp.com | - | active (registered) | nextdp: active | - | DNS VM zone (6 rec, A 3.6.143.66), NextDP Core | rajesh@associate.works |
| 47 | `startupthing.in` | - | verified 2026-10-28 | active (external) | nextdp: active | - | DNS VM zone (7 rec, A 3.6.143.66), NextDP Core | rajesh@associate.works |
| 48 | `teachersclub.in` | - | verified 2026-10-26 | active (external) | nextdp: active | - | DNS VM zone (5 rec, A 3.6.143.66), NextDP Core | rajesh@associate.works |
| 49 | `vcfo.in` | active, exp 2027-06-28, manual, NS ns1.nextdp.com ns2.nextdp.com | - | active (registered) | nextdp: active | - | DNS VM zone (3 rec, A -), NextDP Core | rajesh@associate.works |
| 50 | `vircto.com` | active, exp 2027-03-17, manual, NS ns1.nextdp.com ns2.nextdp.com | - | - | - | - | NextDP Core | rajesh@associate.works |
| 51 | `weddingsite.in` | - | verified 2026-08-15 | detached (external) | nextdp: detached | - | DNS VM zone (7 rec, A 18.233.215.69), NextDP Core | rajesh@associate.works |
| 52 | `whathappened.in` | - | verified 2026-08-07 | active (external) | nextdp: active | - | DNS VM zone (8 rec, A 3.6.143.66), NextDP Core | rajesh@associate.works |
| 53 | `whfyi.in` | - | verified 2026-11-06 | active (external) | nextdp: active | local: dharmaram.whfyi.in (active, dns_ok), local: test.whfyi.in (active, dns_ok) | DNS VM zone (5 rec, A -), NextDP Core | rajesh@associate.works |
| 54 | `xn--1ocz5b4cb0a.com` | - | verified 2026-08-19 | active (external) | nextdp: active | - | DNS VM zone (7 rec, A -), NextDP Core | rajesh@associate.works |
| 55 | `xn--31b1c9bzb.xn--h2brj9c` | - | verified 2026-08-19 | detached (external) | nextdp: detached | - | DNS VM zone (4 rec, A -), NextDP Core | rajesh@associate.works |

## 3. Lead Your Biz (`leadyourbiz`)

- Brand id `f7a36f6d-dcd8-4788-8b04-3e588862c040`, status `active`, created 2026-08-06, primary product `domains`.
- Brand hosts: primary `leadyourbiz.com`, admin `admin.leadyourbiz.com`, console `console.leadyourbiz.com`, accounts (iDP) `accounts.leadyourbiz.com`
- Sender: `support@leadyourbiz.com`. Brand nameservers: `ns1.leadyourbiz.com ns2.leadyourbiz.com`.
- Features on: blogs, direct_register, dns, domains, handcraft, store.
- Users: 2. On AWS now: brand not created; 1 of 1 domains are in live NextDP Core (moved into a live brand as external domains).

| # | Domain | Registered | External | Core DNS zone | Azure dns-service | Sites | On AWS now | Owner |
|---|---|---|---|---|---|---|---|---|
| 1 | `leadyourbiz.in` | active, exp 2027-08-06, manual, NS ns1.leadyourbiz.com ns2.leadyourbiz.com | - | active (registered) | leadyourbiz: active | - | DNS VM zone (5 rec, A 3.6.143.66), NextDP Core | rajesh@leadyourbiz.com |

## 4. DigPre (`digpre`)

- Brand id `ab88644b-2559-4e5e-ab2c-a6eef56ae887`, status `active`, created 2026-08-22, primary product `domains`.
- Brand hosts: admin `admin.digpre.com`, console `console.digpre.com`, accounts (iDP) `accounts.digpre.com` (no primary domain set)
- Sender: `support@digpre.com`. Brand nameservers: `-`.
- Features on: blogs, direct_register, dns, domains, handcraft.
- Users: 0. On AWS now: brand not created; 0 of 0 domains are in live NextDP Core.

No customer domains.

## 5. Next Digital Platforms (`nextdp`)

- Brand id `68ae9cda-6cda-4fec-9ce9-de355737633e`, status `active`, created 2026-08-24, primary product `domains`.
- Brand hosts: primary `nextdp.com`, admin `admin.nextdp.com`, console `console.nextdp.com`, accounts (iDP) `accounts.nextdp.com`
- Sender: `noreply@nextdp.com`. Brand nameservers: `-`.
- Features on: blogs, direct_register, dns, domains, handcraft, store.
- Users: 2. On AWS now: brand exists in live NextDP Core; 2 of 2 domains are in live NextDP Core (moved into a live brand as external domains).

| # | Domain | Registered | External | Core DNS zone | Azure dns-service | Sites | On AWS now | Owner |
|---|---|---|---|---|---|---|---|---|
| 1 | `hamarards.com` | active, exp 2027-08-25, manual, NS joan.ns.cloudflare.com renan.ns.cloudflare.com | - | - | - | - | NextDP Core | hamarapublications@gmail.com |
| 2 | `hamarards.org` | active, exp 2027-08-25, manual, NS joan.ns.cloudflare.com renan.ns.cloudflare.com | - | - | - | - | NextDP Core | hamarapublications@gmail.com |

## 6. YOUR DPM (`dpm`)

- Brand id `5b4a6759-091a-4182-bd58-20f1b39f8efd`, status `active`, created 2026-08-28, primary product `domains`.
- Brand hosts: admin `admin.yourdpm.com`, console `yourdpm.com`, accounts (iDP) `accounts.yourdpm.com` (no primary domain set)
- Sender: `support@yourdpm.com`. Brand nameservers: `-`.
- Features on: blogs, direct_register, dns, domains, handcraft, store.
- Users: 2. On AWS now: brand not created; 1 of 1 domains are in live NextDP Core (moved into a live brand as external domains).

| # | Domain | Registered | External | Core DNS zone | Azure dns-service | Sites | On AWS now | Owner |
|---|---|---|---|---|---|---|---|---|
| 1 | `whydpm.com` | - | verified 2026-08-28 | active (external) | yourdpm: active | blog: whydpm.com (active, dns_ok) | DNS VM zone (4 rec, A -), NextDP Core | admin@yourdpm.com |

## 7. Organic Growth Center (`ogcen`)

- Brand id `49f7b95e-fa84-4f3b-8af9-150b30851074`, status `active`, created 2026-09-18, primary product `domains`.
- Brand hosts: primary `organicgrowth.center`, admin `admin.ogcen.com`, console `my.ogcen.com`, accounts (iDP) `accounts.ogcen.com`
- Sender: `support@ogcen.com`. Brand nameservers: `-`.
- Features on: blogs, direct_register, dns, domains, handcraft, idp_login, store.
- Users: 2. On AWS now: brand not created; 0 of 0 domains are in live NextDP Core.

No customer domains.

## 8. ProSEVA (`proseva`)

- Brand id `e5badb08-9e14-4eae-8094-5479cef65386`, status `active`, created 2026-09-22, primary product `domains`.
- Brand hosts: primary `proseva.org`, admin `admin.proseva.org`, console `console.proseva.org`, accounts (iDP) `accounts.proseva.org`
- Sender: `noreply@proseva.org`. Brand nameservers: `ns1.proseva.org ns2.proseva.org`.
- Features on: blogs, direct_register, dns, domains, handcraft, idp_login, store.
- Users: 2. On AWS now: brand not created; 1 of 1 domains are in live NextDP Core (moved into a live brand as external domains).

| # | Domain | Registered | External | Core DNS zone | Azure dns-service | Sites | On AWS now | Owner |
|---|---|---|---|---|---|---|---|---|
| 1 | `haindaviswaraj.org.in` | - | verified 2026-09-27 | active (external) | proseva: active | - | DNS VM zone (7 rec, A 3.6.143.66), NextDP Core | support@proseva.org |

## 9. LocalCen (`localcen`)

- Brand id `e1dda649-da60-48d8-aa2c-6f3e3627b6ee`, status `active`, created 2026-11-15, primary product `domains`.
- Brand hosts: primary `localcen.com`, admin `admin.localcen.com`, console `console.localcen.com`, accounts (iDP) `accounts.localcen.com`
- Sender: `support@localcen.com`. Brand nameservers: `ns1.localcen.com ns2.localcen.com`.
- Features on: direct_register, dns, domains, idp_login, local, store.
- Users: 2. On AWS now: brand not created; 0 of 0 domains are in live NextDP Core.

No customer domains.

