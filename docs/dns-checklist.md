# DNS Checklist — Mail VM (`52.66.111.138`)

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

## Tenant Domains & Outbound Authentication Notes

- **MX for tenant domains**: Any tenant domain whose MX pointed to `mx.nextdp.com` or `mx.rajesh1.com` automatically routes to `52.66.111.138` once those A records resolve. Any tenant domain that pointed directly at `20.207.194.99` (or whose DNS was on stopped `nmc-dns-1`/`nmc-dns-2`) needs its DNS updated separately.
- **Outbound (ZeptoMail)**: Verify SPF/DKIM records for ZeptoMail remain intact in each sending domain's DNS (ZeptoMail signs outbound mail with its own DKIM selector and sends from ZeptoMail IPs, independent of `52.66.111.138`).
- **Cloudflare Proxy**: Keep Cloudflare proxy **DNS-only** (grey cloud) for all mail/webmail subdomains (`mail.*`, `admin.mail.*`, `super-admin.mail.*`, `mx.*`, `autoconfig.*`) so Caddy issues Let's Encrypt certs cleanly (needed for `mail.nextdp.com` SMTP/IMAP/POP3 TLS) and mail protocols connect directly.
