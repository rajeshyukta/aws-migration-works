# LocalCen SaaS on AWS: integration with Next iDP and NextDP Core

Plan and status for running LocalCen (LocalCen-1-VM `3.111.132.3`) as a SaaS sold through NextDP Core brands, with sign-in through Next iDP (Apps-Core-VM `43.204.42.99`).

- **Created:** 2026-11-20. **Owner decisions (2026-11-20):** fresh setup (old data only as reference), deploy the latest LocalCen `main`, brand **`localcen`** sells Locals (brand **`nextdp`** enabled for testing), platform admin = the owner's `cconsole` account, **phone-only sign-in with Reverse OTP only**. Right after this setup: deploy the SMS service from its R2 backup and connect it to Next iDP and LocalCen (it is the Reverse OTP gateway).
- **No secrets in this file.** Values live in `/root/.localcen-idp.env` (Apps-Core-VM), `/srv/apps/localcen/shared/.env` (LocalCen-1-VM) and `private-data/`.
- Sources: LocalCen repo `docs/references/localcen-hosted-signin-guide.md`, `localcen-idp-rename.md`, `localcen-nextdp-brand-setup.md`, `machine-api.md`; NextDP Core F146/F150; staged old data `nextlocal_r2`, `nextidp_r2`, `nextdp_core_r2` on Apps-Core-VM ([`azure-r2-restore.md`](azure-r2-restore.md)).

## 1. How it fits together

| Who | Signs in at | Next iDP realm |
|---|---|---|
| Platform admin + LocalCen tenants (`admin.localcen.cconsole.com`, `localcen.cconsole.com`) | `accounts.cconsole.com` | `cconsole` (apps `localcen-admin`: roles `realm_admin`/`support`; `localcen-console`: organisation per tenant) |
| Brand members who buy Locals (`console.localcen.com`) | `accounts.localcen.com` | `ndp-localcen` (live) |
| Residents of every Local + each Local's service admin | `myaccount.localcen.com`, phone + Reverse OTP | `localcen-people` (child of top-level `localcen`); LocalCen creates one app per Local itself (group `localcen-locals`, `private_key_jwt`, JWKS from `idp:client-keys`) |

NextDP Core ↔ LocalCen: one LocalCen **tenant per brand**, machine API `https://localcen.cconsole.com/v1` (`X-API-Key: bk_…`), service IP `3.111.132.3`, LocalCen webhook `https://console.<brand host>/webhooks/local-2fa` (HMAC `X-Local-Signature`). Wired with NextDP Core `ops:local-wire-brand` (pings before storing).

## 2. Steps and status

| # | Step | Status |
|---|---|---|
| 1 | Backup LocalCen-1-VM before changes | ✅ 2026-11-20 `/var/backups/localcen/pre-idp-20261120T155026Z/` + `D:\nmc-backup\localcen-1\pre-idp-20261120T155026Z\` |
| 2 | Deploy latest LocalCen `main` | ✅ 2026-11-20 `df9f633`, release `20261120T160221`, 2 data migrations, health OK |
| 3 | Next iDP: `cconsole` apps + key + webhook, owner `realm_admin`; realm `localcen` + tenant key; realm `localcen-people` (`myaccount.localcen.com`, phone only, Reverse OTP only, en/hi/te) | ✅ 2026-11-20 (`scripts/apps-core-vm/18-setup-localcen-idp -Apply`; Next iDP DB backup first: `/var/backups/nextidp/pre-localcen-idp-20261120T193349Z/`): realm `localcen` (`01a1f9fa-bcab-7bc3-88ec-9dd72adb6290`, made by the owner, hosted on `localcen.nextidp.com` because an API-only realm has no page for its keys, Next iDP TD-061) + tenant key `localcen-tenants`; cconsole apps `localcen-console-2542` (access assigned) and `localcen-admin-1188` (roles realm_admin, support), key `localcen-contract`, webhook `/v1/idp/webhook`, `rajesh@cconsole.com` → `realm_admin`; realm `localcen-people` (`01a1fa73-9c4e-7a43-9db7-36b9e8dd0252`, `myaccount.localcen.com`, phone only, Reverse OTP only, sign-up by phone, en/hi/te) + webhook `/v1/idp/tenant-webhook`. Values: `/root/.localcen-idp.env` (0600). Script access: owner-made keys in `private-data/localcen-idp-input.env` (`admin@cconsole.com` asks for a second factor). Owner steps still open (need a session, matter only once the SMS service runs): `localcen` → Allow platform SMS gateway; Reverse OTP SMS / WhatsApp = inherit |
| 4 | Owner: TXT `_n1-verify.myaccount.localcen.com` (value from step 3) | ✅ 2026-11-20: realm `localcen-people` live, `https://myaccount.localcen.com` has its certificate (discovery 200) |
| 5 | LocalCen: Next iDP env, `localcen idp:client-keys`, `IDP_LOGIN=true`, restart; owner signs in to `admin.localcen.cconsole.com` | ✅ 2026-11-20 (`scripts/localcen-1-vm/05-wire-localcen-idp -Apply`; `.env` backup `/var/backups/localcen/pre-idp-env-20261120T194421Z/`): 18 keys merged into `/srv/apps/localcen/shared/.env`, client key set made (`/srv/apps/localcen/shared/keys/local-apps.jwks.json`, public at `/v1/idp/local-apps-jwks.json`), healthy; `localcen.cconsole.com` and `admin.localcen.cconsole.com` redirect to `accounts.cconsole.com`. PC copy of the values: `private-data/localcen-idp.env`. **Owner check open**: sign in to `https://admin.localcen.cconsole.com` as `rajesh@cconsole.com` |
| 6 | LocalCen tenants `localcen` + `nextdp` (key, webhook secret, webhook URL, `cconsole` organisation) | ⏳ |
| 7 | NextDP Core: `ops:local-wire-brand` for `localcen` and `nextdp`; Test connection; signed test webhook | ⏳ |
| 8 | End-to-end test Local on `console.localcen.com` (host, DNS auto-wire, certificate, per-Local app) | ⏳ (resident sign-in needs step 9) |
| 9 | **SMS service** from R2 (`r1sms` `fb986270`) as the Reverse OTP gateway for Next iDP (`smsgw` registration) | ⏳ next, owner decision |
| 10 | Prices (`local_village`, `local_town`, …), nightly LocalCen backup, docs | ⏳ |

## 3. Findings

- **No Reverse OTP gateway on AWS:** Next iDP `smsgw_registrations` is empty. On Azure the gateway was the SMS service (registrations hold its base URL + key). Until step 9, the hosted phone page cannot deliver, and the IdP falls back to the email form.
- **Old data (reference only, owner: fresh setup):** `nextlocal_r2` (8 Nov) is pre-rename test data (tenants `test`, `nextdigital`; 2 Locals). The renamed `localcen_db` on Azure (`nmc-php-stage-1`, after 8 Nov; 6 NextDigital Locals such as `ailapur.nextlocal.in`) was never in R2.
- **NextDP Core console:** the Local's service-admin form offers 4 sign-up methods; LocalCen accepts only **phone** (small NextDP Core fix; until then choose Phone).
- **Base URL** must end in `/v1` (`https://localcen.cconsole.com/v1`).
- **Shared domains** (`gramam.in`, `pattanam.in`, `constituency.in`) stay off; their zones are in DNS tenant `nextdp`, so LocalCen's `domains:setup` must not be run without a decision.
- NextDP Core ignores LocalCen's `local.host_status` webhook (TD-021); it checks hosts itself.
