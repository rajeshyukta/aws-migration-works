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
