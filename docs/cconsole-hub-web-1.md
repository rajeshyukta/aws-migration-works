# CConsole Hub (reseller-mw): move from Mail VM to Web-1

CConsole Hub (`E:\workspace\projects\platform\reseller-mw`, CodeIgniter 4 API + admin/tenant SPAs + API docs) moves from the Mail VM (`52.66.111.138`) to **Web-1 (`3.6.143.66`)** as a **fresh install** (owner decision, 2026-11-20). No data is copied. If data is needed later, import it from the R2 dump (section 5).

- No secrets in this file.

## 1. Status

| Step | State |
|---|---|
| 1. App installed on Web-1 (`06-deploy-cconsole-hub.ps1 -Phase app`) | **Done 2026-11-20.** 19 tables, seeder run, FPM pool up, `GET /` on api + sandbox = 200 over FastCGI. All other Web-1 sites still OK |
| 2. DNS A records → `3.6.143.66` | **Done 2026-11-20 by owner** (SOA serial 2026112008; ns1, ns2 and 1.1.1.1 all return the new IP) |
| 3. Caddy site + Let's Encrypt on Web-1 (`06-deploy-cconsole-hub.ps1 -Phase sites`) | **Done 2026-11-20.** All 5 hosts have Let's Encrypt certs and return 200 from the internet. SPA deep links fall back to `index.html`. CORS preflight from `hub.cconsole.com` is allowed. `POST /v1/auth/login` with fake credentials returns 401 `AUTH_INVALID_CREDENTIALS` (DB path works) |
| 4. Retire on Mail VM (`17-remove-cconsole-hub.sh`) | **Done 2026-11-20 06:07 UTC.** Caddy site and `webapps` crontab removed, `php8.4-fpm` stopped + disabled. Config archived in `/var/backups/nextdp/retired-cconsole-hub-20261120T060723Z/`. Mail, dithim.com OK. `scripts/mail-vm/09-deploy-reseller-mw.*` is now obsolete |
| 5. Set ZeptoMail + ResellerClub credentials, create the first super admin | **Open**, owner + agent (section 4) |

API base path is `/v1/...` (e.g. `https://api.hub.cconsole.com/v1/auth/login`), not `/api/v1`.

## 2. DNS changes (zone `cconsole.com`, DNS VM / dns-service, `nextdp` tenant)

Change these 5 **A** records from `52.66.111.138` to **`3.6.143.66`** (current TTL 3600; keep it):

| Name | Type | Old value | New value |
|---|---|---|---|
| `hub.cconsole.com` | A | 52.66.111.138 | **3.6.143.66** |
| `api.hub.cconsole.com` | A | 52.66.111.138 | **3.6.143.66** |
| `admin.hub.cconsole.com` | A | 52.66.111.138 | **3.6.143.66** |
| `docs.hub.cconsole.com` | A | 52.66.111.138 | **3.6.143.66** |
| `sandbox.hub.cconsole.com` | A | 52.66.111.138 | **3.6.143.66** |

Checked on 2026-11-20: there are no AAAA, CNAME, wildcard (`*.hub`) or CAA records, so nothing else needs to change. Web-1's firewall already allows 80/443.

Check from any machine: `dig +short A api.hub.cconsole.com @52.66.165.1` (ns1) and `@52.66.25.51` (ns2) must return `3.6.143.66`. The Phase `sites` script checks this itself and refuses to continue otherwise. Public resolvers can show the old IP for up to 1 hour. That does not block Let's Encrypt, which asks ns1/ns2 directly.

## 3. Commands (from `E:\workspace\aws-setup-and-migrations`)

```powershell
# redeploy code any time (keeps .env/secrets); add nothing to rebuild SPAs, or -SkipFrontendBuild to reuse dist/
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\web-1-vm\06-deploy-cconsole-hub.ps1 -Phase app -SkipFrontendBuild
# after DNS: Caddy site + certificates + HTTPS check of all 5 hosts
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\web-1-vm\06-deploy-cconsole-hub.ps1 -Phase sites
# then retire on the Mail VM (refuses while DNS still points there)
. .\scripts\mail-vm\common.ps1; Invoke-VmScript -Vm (Get-VmTarget -Name "Mail VM") -LocalScriptPath .\scripts\mail-vm\17-remove-cconsole-hub.sh
```

## 4. What is on Web-1

| Item | Value |
|---|---|
| Code | `/srv/phpapps/cconsole-hub/{ci4-app,frontend/admin/dist,frontend/tenant/dist}`, owner `webapps:caddy` |
| Config | `ci4-app/.env` (`webapps` 0600). **New** secrets generated on Web-1: DB password (`/root/.cconsole-hub-db-pass`), `JWT_SECRET`, `encryption.key`. Not copied from the Mail VM |
| Still to set | `ZEPTO_MAIL_API_KEY`, `RESELLERCLUB_AUTH_USERID`, `RESELLERCLUB_API_KEY`, `RESELLERCLUB_CUSTOMER_ID` are `__SET_ON_SERVER__` (they were placeholders on the Mail VM too). `RESELLERCLUB_SANDBOX = true` |
| First super admin | None yet. Create with `sudo -u webapps php spark auth:create-admin` in `ci4-app` (it asks for email, name, password) |
| DB | PostgreSQL 16 `cconsole_hub`, role `cconsole_hub`, localhost only |
| Redis | New on Web-1: `redis-server` on 127.0.0.1 only, password in `/root/.web1-redis-pass`, `maxmemory 64mb allkeys-lru`, config `/etc/redis/web1-override.conf`. Hub uses DB 0, prefix `cchub_` |
| PHP | Pool `app-cconsole-hub` (`/run/php/app-cconsole-hub.sock`, `webapps`, ondemand, max 5). Added `php8.4-redis`, `php8.4-bcmath` |
| Cron | `/etc/cron.d/cconsole-hub` (UTC): `api:logs-prune` 03:15, `domains:sync` every 6 h, `domains:renewals` 04:00 |
| Caddy | `templates/caddy/cconsole-hub.web-1.caddy` → `/etc/caddy/sites-enabled/cconsole-hub.caddy` (Phase `sites`). Log `/var/log/caddy/cconsole-hub.log` |

## 5. Old data (if needed later)

| Source | Where |
|---|---|
| R2 snapshot `677d331a` (2026-11-18 09:30 IST, Azure `nmc-php-stage-1`) | `D:\nmc-backup\mail-vm\r2-677d331a\cconsole_hub.dump` + Mail VM `/var/backups/nextdp/r2-677d331a/` (SHA-256 verified, 19 tables) |
| Mail VM install (18–20 Nov, nearly empty: settings, 2 API log rows, 1 audit row, no users) | DB `cconsole_hub` on the Mail VM (port 5432) + `/srv/phpapps/cconsole-hub`; also in the Mail VM nightly off-site backup |

Restore selected tables into Web-1 with `pg_restore --data-only -t <table>` into a scratch DB first, then copy rows. Rows encrypted with the old `encryption.key` (2FA secrets in `TwoFactorService`) cannot be decrypted with the new key. Users would need to set up 2FA again.
