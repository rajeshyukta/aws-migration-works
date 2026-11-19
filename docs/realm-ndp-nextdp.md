# Next iDP Child Sub-Realm: `ndp-nextdp` (`accounts.nextdp.com`) & `nextdp` Brand

> **VM**: `Apps-Core-VM` (`43.204.42.99`) · **Updated**: 2026-11-19
> **Security**: Non-secret operational reference only. Never store secrets, client secrets, `n1k_` keys, or passwords in this document; live credentials live in `0600` `/root/.nextdp-brand-idp.env` on the VM and in gitignored `private-data/`.

---

## 1. Brand & Sub-Realm Identity

| Property | Value |
|---|---|
| **Brand Name / Slug** | `NextDP` (`nextdp`) |
| **Brand UUID** | `34831870-c4c1-4d8b-bd45-b77672b541d3` |
| **Marketing / Primary Domain** | `nextdp.com` *(static site outside NextDP Core)* |
| **Brand Admin Host** | `https://admin.nextdp.com` |
| **Member Console Host** | `https://console.nextdp.com` |
| **Primary Product** | `domains` |
| **Enabled Features** | `domains`, `dns`, `blogs`, `handcraft`, `direct_register` *(opt-in `local`, `docs`, `store` off)* |
| **Child Realm Slug / ID** | `ndp-nextdp` / `01a1f23b-5094-7f42-957f-925f93a5d11e` |
| **Parent Realm** | `nextdp-core` (`01a1f211-23de-7ccf-99e7-76024dc7ecab`, `https://id.nextdp.com`) |
| **Child Issuer Host / URL** | `accounts.nextdp.com` / `https://accounts.nextdp.com` |
| **Current `host_status` / `idp_login`** | `pending` / `false` *(awaiting `_n1-verify.accounts.nextdp.com` TXT update)* |

Per Next iDP's N+1 realm hierarchy (`nextdp-core` -> `ndp-<brand>`), `ndp-nextdp` is governed by `nextdp-core` via `IDP_TENANT_KEY` (`tenants.admin`) and holds its own isolated user directory, sessions, OIDC signing keys, and per-brand OIDC clients.

---

## 2. Accounts & Area Access Boundaries

| Surface | Identity Location | Role / Group | Purpose |
|---|---|---|---|
| `accounts.nextdp.com` (`ndp-nextdp`) | Next iDP User `01a1f23b-517a-7bac-aaf7-3f66f2206d72` (`rajesh@nextdp.com`) | `realm_admin` (`must_change_password = false`) | Brand realm administrator; authenticates into `admin.nextdp.com` via `nextdp-admin` client |
| `admin.nextdp.com` (`hosts.Admin`) | NextDP Core `users` (`brand_id = 34831870-c4c1-4d8b-bd45-b77672b541d3`) | `superadmin` (plus platform `master_admin` access) | Brand admin panel (`/login` pre-cutover; `/auth/login` via `nextdp-admin-8390` after cutover) |
| `console.nextdp.com` (`hosts.Console`) | Customer member accounts (`brand_id = 34831870-c4c1-4d8b-bd45-b77672b541d3`) | `member` (`direct_register` enabled) | Member self-service console (`/register`, `/get-started`, `/auth/login` via `nextdp-console-6231`) |

> **Important Shield Isolation Note**: NextDP Core enforces strict area separation (`idp_auth_controller.go:authorizedHere`). `admin.nextdp.com` requires `superadmin` (or `master_admin`), whereas `console.nextdp.com` requires the `member` group on `brand_id = 34831870-c4c1-4d8b-bd45-b77672b541d3`. Use `rajesh@nextdp.com` (`realm_admin` -> `superadmin`) for `admin.nextdp.com` and create/register dedicated `member` accounts for `console.nextdp.com` sign-in testing.

---

## 3. OIDC Clients & Per-Brand Realm Key

Provisioned automatically by NextDP Core `idp.Service.Provision` inside `ndp-nextdp`:

| Property | Admin Client | Console Client |
|---|---|---|
| **Name** | `nextdp-admin` | `nextdp-console` |
| **Client ID** | `nextdp-admin-8390` | `nextdp-console-6231` |
| **Redirect URI** | `https://admin.nextdp.com/auth/callback` | `https://console.nextdp.com/auth/callback` |
| **Back-Channel Logout** | `https://admin.nextdp.com/auth/backchannel-logout` | `https://console.nextdp.com/auth/backchannel-logout` |
| **Access Policy** | Restricted to `realm_admin` | Open (`member`) |
| **Secret Storage** | Encrypted in `nextdp_core.brands.idp_admin_secret` + pulled `.env` | Encrypted in `nextdp_core.brands.idp_console_secret` + pulled `.env` |

> **Child-Realm Operations**: `nextdp_core.brands.idp_realm_key` is intentionally empty (`provision_test.go`) — NextDP Core manages `ndp-nextdp` and all future child realms through the parent platform's `IDP_TENANT_KEY` (`tenants.admin`) with `X-N1-Realm: 01a1f23b-5094-7f42-957f-925f93a5d11e`.

---

## 4. DNS & Verification Checklist

Verified via Cloudflare / `1.1.1.1` on 2026-11-19:

| Type | Hostname | Target / Value | Status |
|---|---|---|---|
| `A` | `admin.nextdp.com` | `43.204.42.99` | Live (Caddy `200`, `/login` `200`) |
| `A` | `console.nextdp.com` | `43.204.42.99` | Live (Caddy `200`, `/login` `200`) |
| `A` | `accounts.nextdp.com` | `43.204.42.99` | Live on DNS |
| `TXT` | `_n1-verify.accounts.nextdp.com` | `n1-verify-eAX9_d9ibqkuIUsu` | **Owner action needed** — update in Cloudflare from stale Azure TXT record |

Until the TXT record verifies, Next iDP keeps `host_status = pending` (`accounts.nextdp.com` returns HTTP `421` on direct auth requests and `/_edge/ask` refuses on-demand TLS) and NextDP Core keeps `idp_login = false` (legacy `/login` remains active on `admin.nextdp.com` and `console.nextdp.com`).

---

## 5. Post-DNS Cutover Steps

1. Update Cloudflare DNS `TXT` record **`_n1-verify.accounts.nextdp.com`** to:
   ```text
   n1-verify-eAX9_d9ibqkuIUsu
   ```
   (Ensure Cloudflare proxy is DNS-only / grey cloud on `accounts.nextdp.com`, `admin.nextdp.com`, `console.nextdp.com`, and `id.nextdp.com`.)
2. Open `https://core.nextdp.com/brands/nextdp/signin` and click **Re-check** (`POST /brands/nextdp/signin/recheck`). Confirm status changes from **`pending`** to **`live`**.
3. Toggle **Sign-in via Next iDP** on (`POST /brands/nextdp/signin/toggle`).
4. Verify:
   - `https://accounts.nextdp.com/.well-known/openid-configuration` returns `200`.
   - `https://admin.nextdp.com/auth/login` redirects (`302`) to `https://accounts.nextdp.com/authorize?client_id=nextdp-admin-8390...`.
   - `https://console.nextdp.com/auth/login` redirects (`302`) to `https://accounts.nextdp.com/authorize?client_id=nextdp-console-6231...`.

---

## 6. Operations & Credential Files

- **Idempotent Setup Script**: [13-setup-nextdp-brand.ps1](../scripts/apps-core-vm/13-setup-nextdp-brand.ps1) ([13-setup-nextdp-brand.sh](../scripts/apps-core-vm/13-setup-nextdp-brand.sh))
- **Credential Pull Script**: [pull-nextdp-idp-credentials.ps1](../scripts/apps-core-vm/pull-nextdp-idp-credentials.ps1)
- **Secret Paths (gitignored)**:
  - VM: `/root/.nextdp-brand-idp.env` (`0600`)
  - Local: `aws-setup-and-migrations/private-data/nextdp-brand-idp-realm.env`, `nextdp-core/private-data/aws-nextdp-brand-idp.env`, `nextidp/private-data/aws-nextdp-brand-realm.env`, plus combined summary files `*nextdp-idp-realms.txt`
