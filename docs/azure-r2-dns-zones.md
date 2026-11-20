# Azure dns-service: tenants and DNS zones (from the R2 backup)

**Generated file, do not edit by hand.** Rebuild with `scripts/r2/make-domain-docs.ps1` (see [`azure-r2-restore.md`](azure-r2-restore.md)).

- **Source:** R2 snapshot a143e215 of dns_service from nmc-db-1 taken 2026-11-16T05:25:44.994200017Z. Staged read-only as `dns_service_r2` on the DNS VM.
- **Exported:** 2026-11-20T09:51:19Z.
- **Totals in the backup:** 9 tenants, 108 zones (2 soft-deleted). Super admins: `admin@presencive.com`, `rajesh@cconsole.com`.
- **AWS now:** live `dns_db` has tenants `presencive`, `nextdp` and 23 zones; PowerDNS (`pdns`) serves 23 zones.
- **Records are not in this backup.** dns-service keeps only the zone list and lifecycle; the records lived in the PowerDNS `pdns` database on the Azure DNS VMs (`nmc-dns-1/2`), which NMC did not back up to R2. A zone moved to AWS gets its records from the owner or from the brand's defaults.

Zone status (dns-service): `active` = delegation to the tenant's nameservers confirmed; `awaiting_ns` = claimed, waiting for the NS change at the registrar; `detached` = was active, NS moved away; `expired` = 14 days without delegation.

## Summary by tenant

| Tenant | Name | Nameservers | Zones | active | awaiting_ns | detached | expired | deleted | API keys | Users | Tenant on AWS |
|---|---|---|---|---|---|---|---|---|---|---|---|
| `presencive` | Presencive | ns1.presencive.com ns2.presencive.com | 15 | 11 | 0 | 2 | 0 | 2 | 1 | rajesh@presencive.com (tenant) | yes |
| `savadhan` | Savadhan | ns1.savadhan.com ns2.savadhan.com | 1 | 1 | 0 | 0 | 0 | 0 | 0 | rajesh@savadhan.com (tenant) | no |
| `nextdp` | NextDP | ns1.nextdp.com ns2.nextdp.com | 88 | 65 | 0 | 10 | 13 | 0 | 2 | nextdigital@cconsole.com (tenant), rajesh@nextdp.com (tenant) | yes |
| `nextdigital` | Next Digital | ns1.nextdigital.in ns2.nextdigital.in | 0 | 0 | 0 | 0 | 0 | 0 | 1 | rajesh@nextdigital.in (tenant) | no |
| `leadyourbiz` | Lead Your Biz | ns1.leadyourbiz.com ns2.leadyourbiz.com | 1 | 1 | 0 | 0 | 0 | 0 | 1 | support@leadyourbiz.com (tenant) | no |
| `cloudtej` | CloudTej | ns1.cloudtej.com ns2.cloudtej.com | 0 | 0 | 0 | 0 | 0 | 0 | 0 | - | no |
| `yourdpm` | YourDPM | ns1.yourdpm.com ns2.yourdpm.com | 1 | 1 | 0 | 0 | 0 | 0 | 1 | rajesh@yourdpm.com (tenant) | no |
| `ogcen` | Organic Growth Center | ns1.ogcen.com ns2.ogcen.com | 0 | 0 | 0 | 0 | 0 | 0 | 1 | admin@ogcen.com (tenant) | no |
| `proseva` | ProSEVA | ns1.proseva.org ns2.proseva.org | 2 | 1 | 0 | 1 | 0 | 0 | 1 | rajesh@proseva.org (tenant) | no |

## 1. Tenant `presencive` (Presencive)

- Nameservers `ns1.presencive.com,ns2.presencive.com`, SOA contact `dns-admin@presencive.com`, status `active`, created 2026-07-27, webhook to `https://console.presencive.com`, require connect False.

| # | Zone | Status | Delegated | Claimed | Source | NextDP Core brand | On AWS now |
|---|---|---|---|---|---|---|---|
| 1 | `athomepg.in` | active | 2026-07-27 | 2026-07-27 | import | presencive | no |
| 2 | `bharatgetonline.com` | active | 2026-07-28 | 2026-07-28 | api | presencive | no |
| 3 | `bhuvigeotech.co.in` | active | 2026-07-27 | 2026-07-27 | import | presencive | no |
| 4 | `halli.in` | active | 2026-10-28 | 2026-10-28 | api | presencive | no |
| 5 | `hargharme.com` | active | 2026-07-27 | 2026-07-27 | import | presencive | no |
| 6 | `icfluence.com` | active | 2026-07-27 | 2026-07-27 | import | presencive | no |
| 7 | `pdnstest.presencive.com` | active | 2026-07-27 | 2026-07-27 | import | - | no |
| 8 | `pureayurveda.in` | active | 2026-07-27 | 2026-07-27 | import | presencive | no |
| 9 | `rapidbot.in` | active | 2026-07-27 | 2026-07-27 | import | presencive | no |
| 10 | `srinivasulu.in` | active | 2026-07-27 | 2026-07-27 | import | presencive | no |
| 11 | `vayamhindu.com` | active | 2026-07-27 | 2026-07-27 | import | presencive | no |
| 12 | `rajesh.co.in` | detached | 2026-07-27 | 2026-07-27 | import | presencive | no |
| 13 | `rajesh.in` | detached | 2026-07-27 | 2026-07-27 | import | presencive | no |
| 14 | `f03-smoke-test.com` | awaiting_ns (deleted) | - | 2026-07-27 | api | - | no |
| 15 | `f03-verify-10601.com` | awaiting_ns (deleted) | - | 2026-07-27 | api | - | no |

## 2. Tenant `savadhan` (Savadhan)

- Nameservers `ns1.savadhan.com,ns2.savadhan.com`, SOA contact `dns-admin@savadhan.com`, status `active`, created 2026-07-27, webhook to `-`, require connect False.

| # | Zone | Status | Delegated | Claimed | Source | NextDP Core brand | On AWS now |
|---|---|---|---|---|---|---|---|
| 1 | `savadhan.com` | active | 2026-07-27 | 2026-07-27 | api | - | no |

## 3. Tenant `nextdp` (NextDP)

- Nameservers `ns1.nextdp.com,ns2.nextdp.com`, SOA contact `dns-admin@nextdp.com`, status `active`, created 2026-07-27, webhook to `https://console.nextdigital.in`, require connect False.

| # | Zone | Status | Delegated | Claimed | Source | NextDP Core brand | On AWS now |
|---|---|---|---|---|---|---|---|
| 1 | `126.works` | active | 2026-07-28 | 2026-07-28 | api | - | no |
| 2 | `126works.com` | active | 2026-07-28 | 2026-07-28 | api | - | no |
| 3 | `afterai.work` | active | 2026-09-24 | 2026-09-24 | api | nextdigital | no |
| 4 | `afteraiwork.com` | active | 2026-09-24 | 2026-09-24 | api | nextdigital | dns_db: nextdp active; pdns 6 rec, A 3.6.143.66 |
| 5 | `apimw.com` | active | 2026-09-24 | 2026-09-24 | api | nextdigital | no |
| 6 | `associate.works` | active | 2026-07-31 | 2026-07-31 | api | nextdigital | no |
| 7 | `bajrang.org` | active | 2026-07-28 | 2026-07-28 | api | - | no |
| 8 | `bhakthivruksha.org` | active | 2026-07-28 | 2026-07-28 | api | - | no |
| 9 | `cconsole.com` | active | 2026-07-28 | 2026-07-28 | api | nextdigital | dns_db: nextdp active; pdns 18 rec, A 3.6.143.66 |
| 10 | `constituency.in` | active | 2026-07-28 | 2026-07-28 | api | nextdigital | no |
| 11 | `cyjago.com` | active | 2026-10-21 | 2026-10-21 | api | nextdigital | no |
| 12 | `daiskills.com` | active | 2026-10-12 | 2026-10-12 | api | nextdigital | dns_db: nextdp active; pdns 6 rec, A 3.6.143.66 |
| 13 | `dcai.in` | active | 2026-07-28 | 2026-07-28 | api | - | no |
| 14 | `dithim.com` | active | 2026-09-03 | 2026-09-03 | api | nextdigital | no |
| 15 | `factgrid.in` | active | 2026-08-16 | 2026-08-16 | api | nextdigital | no |
| 16 | `forbharat.in` | active | 2026-10-20 | 2026-10-20 | api | nextdigital | dns_db: nextdp active; pdns 6 rec, A 3.6.143.66 |
| 17 | `forbharat.org` | active | 2026-10-20 | 2026-10-20 | api | nextdigital | dns_db: nextdp active; pdns 6 rec, A 3.6.143.66 |
| 18 | `gramam.in` | active | 2026-07-28 | 2026-07-28 | api | nextdigital | no |
| 19 | `havoment.com` | active | 2026-07-28 | 2026-07-28 | api | - | no |
| 20 | `justicefor.info` | active | 2026-07-28 | 2026-07-28 | api | - | no |
| 21 | `justicefor.net` | active | 2026-07-28 | 2026-07-28 | api | - | no |
| 22 | `jyoth.com` | active | 2026-07-28 | 2026-07-28 | api | - | no |
| 23 | `jyothularajesh.com` | active | 2026-09-23 | 2026-09-23 | api | nextdigital | dns_db: nextdp active; pdns 6 rec, A 3.6.143.66 |
| 24 | `kishorekrishna.com` | active | 2026-07-28 | 2026-07-28 | api | - | no |
| 25 | `lewiai.com` | active | 2026-07-28 | 2026-07-28 | api | nextdigital | no |
| 26 | `lewo.in` | active | 2026-07-28 | 2026-07-28 | api | - | no |
| 27 | `lewoin.com` | active | 2026-07-28 | 2026-07-28 | api | - | no |
| 28 | `localcen.com` | active | 2026-11-07 | 2026-11-07 | api | localcen (brand host), nextdigital | dns_db: nextdp awaiting_ns; pdns 6 rec, A 3.6.143.66 |
| 29 | `mananiya.com` | active | 2026-09-07 | 2026-09-07 | api | nextdigital | no |
| 30 | `mastery.center` | active | 2026-07-28 | 2026-07-28 | api | - | no |
| 31 | `mrajesh.com` | active | 2026-11-15 | 2026-11-15 | api | nextdigital | dns_db: nextdp active; pdns 6 rec, A 3.6.143.66 |
| 32 | `navabharatiyam.com` | active | 2026-10-21 | 2026-10-21 | api | nextdigital | no |
| 33 | `navasanatani.com` | active | 2026-07-28 | 2026-07-28 | api | - | no |
| 34 | `navduta.com` | active | 2026-10-11 | 2026-10-11 | api | nextdigital | dns_db: nextdp active; pdns 6 rec, A 3.6.143.66 |
| 35 | `nextidp.com` | active | 2026-10-02 | 2026-10-02 | api | nextdigital | dns_db: nextdp active; pdns 9 rec, A 43.204.42.99 |
| 36 | `nextlocal.in` | active | 2026-10-16 | 2026-10-16 | api | nextdigital | no |
| 37 | `nextskillclub.com` | active | 2026-11-10 | 2026-11-10 | api | nextdigital | dns_db: nextdp active; pdns 6 rec, A 3.6.143.66 |
| 38 | `nextventure.in` | active | 2026-08-05 | 2026-08-05 | api | nextdigital | no |
| 39 | `nextvf.com` | active | 2026-07-28 | 2026-07-28 | api | - | no |
| 40 | `onesign.in` | active | 2026-08-05 | 2026-08-05 | api | nextdigital | no |
| 41 | `padmashali.org` | active | 2026-08-07 | 2026-07-28 | api | nextdigital | no |
| 42 | `panchang.io` | active | 2026-07-28 | 2026-07-28 | api | nextdigital | no |
| 43 | `pattanam.in` | active | 2026-11-09 | 2026-11-09 | api | nextdigital | no |
| 44 | `promptation.ai` | active | 2026-11-13 | 2026-07-28 | api | nextdigital | no |
| 45 | `rajesh.app` | active | 2026-08-10 | 2026-07-28 | api | nextdigital | no |
| 46 | `rajesh.one` | active | 2026-09-24 | 2026-09-24 | api | nextdigital | no |
| 47 | `rajesh1.com` | active | 2026-07-28 | 2026-07-28 | api | nextdigital, presencive | no |
| 48 | `rajeshforbharat.com` | active | 2026-07-28 | 2026-07-28 | api | - | dns_db: nextdp active; pdns 6 rec, A 3.6.143.66 |
| 49 | `rajeshone.com` | active | 2026-08-14 | 2026-08-14 | api | nextdigital | no |
| 50 | `rajeshyukta.in` | active | 2026-09-25 | 2026-09-25 | api | nextdigital, presencive | dns_db: nextdp active; pdns 6 rec, A 3.6.143.66 |
| 51 | `rapidgo.dev` | active | 2026-07-28 | 2026-07-28 | api | - | no |
| 52 | `softskills.training` | active | 2026-10-13 | 2026-10-13 | api | nextdigital | dns_db: nextdp active; pdns 6 rec, A 3.6.143.66 |
| 53 | `srikalabhairavam.com` | active | 2026-08-05 | 2026-08-05 | api | nextdigital | dns_db: nextdp active; pdns 11 rec, A 3.6.143.66 |
| 54 | `srikalabhairavam.in` | active | 2026-09-09 | 2026-09-09 | api | nextdigital | dns_db: nextdp active; pdns 6 rec, A 3.6.143.66 |
| 55 | `startuphouse.in` | active | 2026-08-05 | 2026-08-05 | api | nextdigital | no |
| 56 | `startupthing.in` | active | 2026-07-28 | 2026-07-28 | api | nextdigital | no |
| 57 | `supportfor.in` | active | 2026-07-28 | 2026-07-28 | api | - | no |
| 58 | `teachersclub.in` | active | - | 2026-10-26 | api | nextdigital | no |
| 59 | `vcfo.in` | active | 2026-08-05 | 2026-08-05 | api | nextdigital | no |
| 60 | `wetheleader.in` | active | 2026-07-28 | 2026-07-28 | api | - | no |
| 61 | `whathappened.in` | active | 2026-08-07 | 2026-08-07 | api | nextdigital | no |
| 62 | `whfyi.in` | active | 2026-11-06 | 2026-11-06 | api | nextdigital | no |
| 63 | `withrajesh.com` | active | 2026-07-28 | 2026-07-28 | api | - | no |
| 64 | `xn--1ocz5b4cb0a.com` | active | 2026-08-19 | 2026-08-19 | api | nextdigital | no |
| 65 | `yuktas.com` | active | 2026-07-28 | 2026-07-28 | api | - | no |
| 66 | `ac2.in` | detached | 2026-09-25 | 2026-09-25 | api | nextdigital | no |
| 67 | `forbharat.com` | detached | 2026-07-28 | 2026-07-28 | api | - | dns_db: nextdp active; pdns 6 rec, A 3.6.143.66 |
| 68 | `foryourattention.com` | detached | 2026-08-05 | 2026-08-05 | api | nextdigital | no |
| 69 | `harghar.me` | detached | 2026-10-21 | 2026-10-21 | api | nextdigital | no |
| 70 | `live.care` | detached | 2026-08-05 | 2026-08-05 | api | nextdigital | no |
| 71 | `nextmanager.in` | detached | 2026-07-28 | 2026-07-28 | api | - | no |
| 72 | `rajesh.works` | detached | 2026-08-04 | 2026-08-04 | api | nextdigital | no |
| 73 | `securedbot.in` | detached | 2026-08-05 | 2026-08-05 | api | nextdigital | no |
| 74 | `weddingsite.in` | detached | 2026-08-15 | 2026-08-15 | api | nextdigital | no |
| 75 | `xn--31b1c9bzb.xn--h2brj9c` | detached | 2026-08-19 | 2026-08-19 | api | nextdigital | no |
| 76 | `ahamoment.in` | expired | - | 2026-07-28 | api | - | no |
| 77 | `bsupport.in` | expired | - | 2026-07-28 | api | - | no |
| 78 | `getcybersafety.com` | expired | - | 2026-07-28 | api | - | no |
| 79 | `kalabhairavam.com` | expired | - | 2026-07-28 | api | - | dns_db: nextdp awaiting_ns; pdns 6 rec, A 3.6.143.66 |
| 80 | `masterymd.com` | expired | - | 2026-07-28 | api | - | no |
| 81 | `nareng.in` | expired | - | 2026-07-28 | api | - | no |
| 82 | `nevergiveup.in` | expired | - | 2026-07-28 | api | - | no |
| 83 | `nextdp.com` | expired | - | 2026-07-28 | api | nextdp (brand host) | no |
| 84 | `presencive.com` | expired | - | 2026-07-28 | api | presencive (brand host) | no |
| 85 | `qasandbox.com` | expired | - | 2026-07-28 | api | - | no |
| 86 | `rai.works` | expired | - | 2026-07-28 | api | - | no |
| 87 | `sankalpam.world` | expired | - | 2026-07-28 | api | - | no |
| 88 | `whfya.com` | expired | - | 2026-07-28 | api | - | no |

## 4. Tenant `nextdigital` (Next Digital)

- Nameservers `ns1.nextdigital.in,ns2.nextdigital.in`, SOA contact `dns-admin@nextdigital.in`, status `active`, created 2026-08-03, webhook to `-`, require connect False.

No zones.

## 5. Tenant `leadyourbiz` (Lead Your Biz)

- Nameservers `ns1.leadyourbiz.com,ns2.leadyourbiz.com`, SOA contact `dns-admin@leadyourbiz.com`, status `active`, created 2026-08-06, webhook to `https://console.leadyourbiz.com`, require connect False.

| # | Zone | Status | Delegated | Claimed | Source | NextDP Core brand | On AWS now |
|---|---|---|---|---|---|---|---|
| 1 | `leadyourbiz.in` | active | 2026-08-07 | 2026-08-07 | api | leadyourbiz | no |

## 6. Tenant `cloudtej` (CloudTej)

- Nameservers `ns1.cloudtej.com,ns2.cloudtej.com`, SOA contact `dns-admin@cloudtej.com`, status `active`, created 2026-08-25, webhook to `-`, require connect False.

No zones.

## 7. Tenant `yourdpm` (YourDPM)

- Nameservers `ns1.yourdpm.com,ns2.yourdpm.com`, SOA contact `dns-admin@yourdpm.com`, status `active`, created 2026-08-28, webhook to `https://yourdpm.com`, require connect False.

| # | Zone | Status | Delegated | Claimed | Source | NextDP Core brand | On AWS now |
|---|---|---|---|---|---|---|---|
| 1 | `whydpm.com` | active | 2026-08-28 | 2026-08-28 | api | dpm | no |

## 8. Tenant `ogcen` (Organic Growth Center)

- Nameservers `ns1.ogcen.com,ns2.ogcen.com`, SOA contact `dns-admin@ogcen.com`, status `active`, created 2026-09-18, webhook to `https://my.ogcen.com`, require connect False.

No zones.

## 9. Tenant `proseva` (ProSEVA)

- Nameservers `ns1.proseva.org,ns2.proseva.org`, SOA contact `dns-admin@proseva.org`, status `active`, created 2026-09-22, webhook to `https://console.proseva.org`, require connect False.

| # | Zone | Status | Delegated | Claimed | Source | NextDP Core brand | On AWS now |
|---|---|---|---|---|---|---|---|
| 1 | `haindaviswaraj.org.in` | active | 2026-09-27 | 2026-09-27 | api | proseva | dns_db: nextdp awaiting_ns; pdns 7 rec, A 3.6.143.66 |
| 2 | `proseva.org` | detached | 2026-09-22 | 2026-08-07 | api | nextdigital, proseva (brand host) | dns_db: nextdp awaiting_ns; pdns 6 rec, A 3.6.143.66 |

## Zones on AWS that were not in the Azure dns-service

| Zone | pdns records | Apex A | Apex MX | dns_db tenant |
|---|---|---|---|---|
| `nextdigital.in` | 6 | 3.6.143.66 | mx.nextdp.com | nextdp |
| `ogcen.com` | 6 | 3.6.143.66 | mx.nextdp.com | nextdp |
| `organicgrowth.center` | 6 | 3.6.143.66 | mx.nextdp.com | nextdp |

## Zone transfers between tenants (Azure)

| When | Zone | From | To | Redelegated |
|---|---|---|---|---|
| 2026-09-22 | `proseva.org` | nextdp | proseva | yes |
| 2026-10-04 | `jyothularajesh.com` | ogcen | nextdigital | yes |
| 2026-10-04 | `jyothularajesh.com` | nextdigital | ogcen | yes |
| 2026-10-04 | `jyothularajesh.com` | ogcen | nextdp | yes |
| 2026-11-13 | `promptation.ai` | nextdp | nextdigital | yes |
| 2026-11-13 | `promptation.ai` | nextdigital | nextdp | yes |

