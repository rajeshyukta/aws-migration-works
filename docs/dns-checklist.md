# DNS Checklist — Mail VM (`52.66.111.138`)

> **History (2026-11-18).** The "Nameserver Cutover" section below is superseded: `ns1.nextdp.com` → `52.66.165.1` and `ns2.nextdp.com` → `52.66.25.51` (DNS VM, PowerDNS). Current DNS facts: [`vms-setup-and-services-and-all-info.md`](vms-setup-and-services-and-all-info.md) section 7. The mail hostnames in the first table are still correct.

Verified against `1.1.1.1` on 2026-11-18. Both `nextdp.com` and `rajesh1.com` are hosted on Cloudflare.

## Core Mail & Console Hostnames

| Hostname | Type | Target | Status |
|---|---|---|---|
| `mail.nextdp.com` | A | `52.66.111.138` | Live |
| `admin.mail.nextdp.com` | A | `52.66.111.138` | Live |
| `super-admin.mail.nextdp.com` | A | `52.66.111.138` | Live (updated 2026-11-18) |
| `autoconfig.nextdp.com` | A | `52.66.111.138` | Live |
| `mx.nextdp.com` | A | `52.66.111.138` | Live (`nextdp.com MX -> 0 mx.nextdp.com`) |
| `mail.rajesh1.com` | A | `52.66.111.138` | Live |
| `admin.mail.rajesh1.com` | A | `52.66.111.138` | Live |
| `super-admin.mail.rajesh1.com` | A | `52.66.111.138` | Live |
| `mx.rajesh1.com` | A | `52.66.111.138` | Live (`rajesh1.com MX -> 0 mx.rajesh1.com`) |
| `autoconfig.rajesh1.com` | A | `52.66.111.138` | Optional — currently absent; omitted from initial `Caddyfile.mail-vm` so ACME does not fail |
| `dithim.com` | A | `52.66.111.138` | Live (`dithim-web.service` + `/opt/dithim/public`) |
| `www.dithim.com` | A | `52.66.111.138` | Live (`301` redirect → `https://dithim.com{uri}`) |

## Nameserver Cutover (`ns1.nextdp.com` & `ns2.nextdp.com` → `52.66.111.138`)

Currently (checked `2026-11-18` via `1.1.1.1`), `ns1.nextdp.com` (`4.224.62.222`) and `ns2.nextdp.com` (`172.198.131.111`) still point to the stopped Azure `nmc-dns-1` / `nmc-dns-2` VMs, causing delegated domains (`navasanatani.com`, `associate.works`, `cconsole.com`, `yuktas.com`, `digpre.com`, `proseva.org`, `rapidbot.in`, etc.) to `SERVFAIL`.

To activate the CoreDNS service running on `52.66.111.138`:
1. **Cloudflare DNS (`nextdp.com`)**: Update `A` records for `ns1.nextdp.com` and `ns2.nextdp.com` to `52.66.111.138` (DNS-only / grey cloud).
2. **`nextdp.com` Domain Registrar (Glue / Child Nameservers)**: Update host glue records for `ns1.nextdp.com` and `ns2.nextdp.com` to `52.66.111.138` so `.com`/`.in`/`.org` TLD referrals send recursive resolvers to AWS Lightsail instead of stopped Azure VMs.

> **Important Operational Notes**:
> - **Sending email (SPF/DKIM)**: CoreDNS is configured with zero per-domain records (`MX 0 mx.nextdp.com` + `A 52.66.111.138`, no `TXT`). Domains that only *receive* mail or display the maintenance page work immediately on `ns1`/`ns2.nextdp.com`; domains actively *sending* outbound mail via ZeptoMail (`nextdp.com`, `rajesh1.com`, `presencive.com`, etc.) should stay on Cloudflare DNS (or move back to Cloudflare / explicit CoreDNS zone files) so ZeptoMail SPF/DKIM TXT records remain intact.
> - **Dual-NS single IP**: Some strict TLDs/registrars disallow identical IPs for `ns1` and `ns2`; for `.com`/`.in`/`.org`/`.works` this works during temporary migration, and a cheap secondary Lightsail IP/VM running the identical `Corefile` can later serve `ns2`.

## Tenant Domains & Outbound Authentication Notes

- **MX for tenant domains**: Any tenant domain whose MX pointed to `mx.nextdp.com` or `mx.rajesh1.com` (or uses `ns1`/`ns2.nextdp.com`) automatically routes inbound mail to `52.66.111.138` once `ns1`/`ns2` A/glue records point to `52.66.111.138`.
- **Outbound (ZeptoMail)**: Verify SPF/DKIM records for ZeptoMail remain intact in each sending domain's DNS (ZeptoMail signs outbound mail with its own DKIM selector and sends from ZeptoMail IPs, independent of `52.66.111.138`).
- **Cloudflare Proxy**: Keep Cloudflare proxy **DNS-only** (grey cloud) for all mail/webmail subdomains (`mail.*`, `admin.mail.*`, `super-admin.mail.*`, `mx.*`, `autoconfig.*`) and `ns1`/`ns2` so Caddy issues Let's Encrypt certs cleanly and mail/DNS protocols connect directly.
