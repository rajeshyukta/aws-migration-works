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
- [ ] **Owner: set ZeptoMail + ResellerClub credentials** in `/srv/phpapps/cconsole-hub/ci4-app/.env` on Web-1, and create the first super admin (`php spark auth:create-admin`).
- [ ] **Delete the old hub on the Mail VM after 2026-12-04**: `/srv/phpapps/cconsole-hub` and DB `cconsole_hub` (the R2 dump on this PC stays).

## Web-1

- [ ] **Off-site backup for Web-1.** Web-1 has no backup of its own (DBs `domains_rajesh`, `web1_apps`, `cconsole_hub`, the SQLite files, `/srv`). Same pattern as the Mail VM ([`mail-vm-offsite-backup.md`](mail-vm-offsite-backup.md)) with its own repo prefix, e.g. `aws-web-1`.
