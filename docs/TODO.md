# TODO

Open follow-ups for the AWS setup and migrations. Tick an item and add the date when it is done.

## Mail VM (`52.66.111.138`)

- [ ] **Upload `private-data/mail-vm-offsite-backup.env` to the AW Vault** (project `dev-workspace`).
  - It holds the only copy of the off-site backup password outside the Mail VM. Without it, the R2 backup (`nxtmngr-test/aws-mail-vm`) cannot be restored if both this PC and the VM are lost.
  - Do not delete or regenerate the file: a new password cannot open the existing backup.
  - Details: [`mail-vm-offsite-backup.md`](mail-vm-offsite-backup.md).

- [ ] **Delete `nextdp_mail_aug_old` after 27 Nov 2026** (if no mail problems by then).
  - This is the old August database, kept after the 2026-11-20 cutover. Once it is dropped, the quick rollback (rename back) is gone. The final dump stays on this PC in `D:\nmc-backup\mail-vm\cutover-20261120T043819Z\nextdp_mail-final.dump`.
  - On the Mail VM:
    ```bash
    sudo -u postgres psql -p 5432 -XAtc "SELECT datname FROM pg_database WHERE datname LIKE 'nextdp_mail%' ORDER BY 1;"   # expect nextdp_mail + nextdp_mail_aug_old
    sudo -u postgres psql -p 5432 -c "DROP DATABASE nextdp_mail_aug_old;"
    ```
  - Details: [`mail-vm-db-upgrade-r2.md`](mail-vm-db-upgrade-r2.md) (sections 4.3 and 6).

## CConsole Hub move to Web-1 (`3.6.143.66`)

Details: [`cconsole-hub-web-1.md`](cconsole-hub-web-1.md).

- [x] **Owner: change 5 DNS A records to `3.6.143.66`** (done 2026-11-20): `hub`, `api.hub`, `admin.hub`, `docs.hub`, `sandbox.hub` (`.cconsole.com`).
- [x] **Agent: run `06-deploy-cconsole-hub.ps1 -Phase sites`** (done 2026-11-20; Let's Encrypt on all 5 hosts).
- [x] **Agent: retire on the Mail VM** with `scripts/mail-vm/17-remove-cconsole-hub.sh` (done 2026-11-20).
- [ ] **Later: API keys for the hub** (owner provides, agent sets them on Web-1 in `/srv/phpapps/cconsole-hub/ci4-app/.env`, then `sudo systemctl reload php8.4-fpm`). All 4 are still `__SET_ON_SERVER__`:
  - `ZEPTO_MAIL_API_KEY` (sender `noreply@cconsole.com`). Without it the hub cannot send email (2FA codes, notifications).
  - `RESELLERCLUB_AUTH_USERID`, `RESELLERCLUB_API_KEY`, `RESELLERCLUB_CUSTOMER_ID`. Without them domain search/registration and the `domains:sync` / `domains:renewals` crons cannot reach ResellerClub. `RESELLERCLUB_SANDBOX = true` stays until the owner says to go live.
  - Keys travel through chat or the AW Vault, never git. After setting them, test one sandbox domain check and one email.
- [ ] **Later: first super admin for the hub**. Owner gives email + name. Agent runs `sudo -u webapps php spark auth:create-admin` in `ci4-app` and stores the generated password in `private-data/` (not in chat).
- [ ] **Delete the old hub on the Mail VM after 2026-12-04**: `/srv/phpapps/cconsole-hub` and DB `cconsole_hub` (the R2 dump on this PC stays).

## Web-1

- [x] **Off-site backup for Web-1** (done 2026-11-20): nightly to R2 `nxtmngr-test/aws-web-1`, weekly verify + restore test, alert mail via the Mail VM. See [`web-1-offsite-backup.md`](web-1-offsite-backup.md).
- [ ] **Upload `private-data/web-1-offsite-backup.env` to the AW Vault** (project `dev-workspace`). Same reason as the Mail VM file: without it the Web-1 backup cannot be restored.
