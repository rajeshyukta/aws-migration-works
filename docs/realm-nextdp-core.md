# Next iDP Realm: `nextdp-core` (`id.nextdp.com`)

> **VM**: `Apps-Core-VM` (`43.204.42.99`) · **Updated**: 2026-11-19
> **Security**: Non-secret operational reference only. Never store secrets, `n1k_` keys, or passwords in this document; live credentials live in `0600` `/root/.nextdp-core-idp.env` on the VM and in gitignored `private-data/`.

---

## 1. Identity & Role in Hierarchy

| Field | Value |
|---|---|
| **Display Name** | `NextDP Core` |
| **Slug** | `nextdp-core` |
| **Realm ID** | `01a1f211-23de-7ccf-99e7-76024dc7ecab` |
| **Kind** | `internal` |
| **Parent Realm** | None (top-level platform realm; parent of all `ndp-<brand>` sub-realms) |
| **Issuer Host** | `id.nextdp.com` |
| **Issuer URL** | `https://id.nextdp.com` |
| **Host Status** | `live` (`/.well-known/openid-configuration` verified HTTP `200`) |
| **Protected Application** | NextDP Core Control Plane (`https://core.nextdp.com`) |

Keeping the core control-plane realm at `id.nextdp.com` leaves `accounts.<brand-domain>` cleanly reserved for each tenant brand's own sub-realm (`DefaultIdpHost` in NextDP Core, starting with `accounts.nextdp.com` for the `nextdp` brand).

---

## 2. Realm Administrator

| Field | Value |
|---|---|
| **Email** | `rajesh@nextdp.com` |
| **User ID** | `01a1f211-2411-7fb6-a313-30da480faa8b` |
| **Role in Next iDP** | `realm_admin` (`must_change_password = false`; owner-managed password preserved by setup script) |
| **Mapping in NextDP Core** | Links via verified email on `core.nextdp.com` (`hosts.Core`) to the platform `master_admin` account (`brand_id = 00000000-0000-7000-8000-000000000000`) |

In addition to managing `nextdp-core`, a `realm_admin` of this parent realm has delegated admin visibility into child brand sub-realms via `X-N1-Realm` in Next iDP.

---

## 3. OIDC Client & Integration Keys

### OIDC Application

| Field | Value |
|---|---|
| **Name** | `nextdp-core` |
| **Client ID** | `nextdp-core-6591` |
| **Type / Auth** | `confidential` · `client_secret_basic` |
| **Grants** | `authorization_code`, `refresh_token` |
| **Scopes** | `openid`, `profile`, `email`, `offline_access` |
| **Redirect URI** | `https://core.nextdp.com/auth/callback` |
| **Post-Logout Redirect URI** | `https://core.nextdp.com/` |
| **Back-Channel Logout URI** | `https://core.nextdp.com/auth/backchannel-logout` |
| **Home URI** | `https://core.nextdp.com/` |
| **First-Party / Access Mode** | `true` · `open` |

### API Keys (Prefixes Only)

| Name | Prefix | Scopes | Bound Client | Purpose |
|---|---|---|---|---|
| `nextdp-core-tenants` | `n1k_live_ZY1` | `tenants.admin` | — (top-level tenant key) | `IDP_TENANT_KEY` — creates & manages `ndp-<brand>` child realms |
| `nextdp-core-contract` | `n1k_live_6AV` | `events.read`, `clients.self`, `signals.write`, `dsr.ack` | `nextdp-core-6591` | `IDP_PLATFORM_API_KEY` — F142 change feed, app metadata, signals & DSR acks |

### Webhook

| Field | Value |
|---|---|
| **Webhook ID** | `01a1f234-c2c7-77ce-84fb-4c7ba162f17f` |
| **URL** | `https://core.nextdp.com/api/v1/idp/webhook` |
| **Subscribed Events** | `user.updated`, `user.email_changed`, `user.deleted`, `privacy.dsr.erasure_requested` |

---

## 4. NextDP Core Environment Configuration

Configured in `/srv/apps/nextdp/shared/.env` on `Apps-Core-VM`:

- `IDP_PLATFORM_ISSUER=https://id.nextdp.com`
- `IDP_PLATFORM_REALM_ID=01a1f211-23de-7ccf-99e7-76024dc7ecab`
- `IDP_PLATFORM_CLIENT_ID=nextdp-core-6591`
- `IDP_PLATFORM_CLIENT_SECRET` *(from `0600` secret file / `private-data/`)*
- `IDP_API_BASE=https://nextidp.com` *(use apex master host, never `admin.nextidp.com` which returns 301)*
- `IDP_TENANT_KEY` *(prefix `n1k_live_ZY1`)*
- `IDP_PLATFORM_API_KEY` *(prefix `n1k_live_6AV`)*
- `IDP_WEBHOOK_SECRET` *(HMAC secret for `/api/v1/idp/webhook`)*
- `IDP_CORE_ORIGIN=https://core.nextdp.com`
- `IDP_OWNER_CONTACT=rajesh@nextdp.com`
- `IDP_CORE_LOGIN=false` *(set to `true` when ready to cut over `core.nextdp.com` sign-in to OIDC; legacy `/login` remains mounted as break-glass)*

---

## 5. DNS & Routing

| Type | Name | Value | Status |
|---|---|---|---|
| `A` | `id.nextdp.com` | `43.204.42.99` | Live |
| `TXT` | `_n1-verify.id.nextdp.com` | `n1-verify-NSiPQuFhGn-3WVfI` | Verified |

Caddy TLS on-demand ask (`/usr/local/bin/apps-core-tls-ask.py` → `127.0.0.1:8080/_edge/ask`) returns `200 allow:nextidp` for `id.nextdp.com`.

---

## 6. Operations & Credential Files

- **Idempotent Setup Script**: [12-setup-nextdp-core-realm.ps1](../scripts/apps-core-vm/12-setup-nextdp-core-realm.ps1) ([12-setup-nextdp-core-realm.sh](../scripts/apps-core-vm/12-setup-nextdp-core-realm.sh))
- **Credential Pull Script**: [pull-nextdp-idp-credentials.ps1](../scripts/apps-core-vm/pull-nextdp-idp-credentials.ps1)
- **Secret Paths (gitignored)**:
  - VM: `/root/.nextdp-core-idp.env` (`0600`) and `/srv/apps/nextdp/shared/.env`
  - Local: `aws-setup-and-migrations/private-data/nextdp-core-idp-realm.env`, `nextdp-core/private-data/aws-nextdp-core-idp.env`, `nextidp/private-data/aws-nextdp-core-realm.env`
- **Verify Live Cutover Readiness**:
  1. `curl -I https://core.nextdp.com/auth/login` returns `302` → `https://id.nextdp.com/authorize?...`.
  2. When ready to cut over `core.nextdp.com` sign-in to Next iDP, set `IDP_CORE_LOGIN=true` in `/srv/apps/nextdp/shared/.env` (or re-run `12-setup-nextdp-core-realm.ps1 -EnableCoreLogin`) and test logging into `https://core.nextdp.com` via `id.nextdp.com`.
- **Optional Cleanup**: If you created a temporary `nextdp-core-setup` (`realm.admin`) API key for initial setup, you may revoke it in `https://nextidp.com` → **NextDP Core → API keys** (keep `nextdp-core-tenants` and `nextdp-core-contract`).
