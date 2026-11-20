# Install Web-1's own off-site backup (restic -> R2 nxtmngr-test/aws-web-1), same tool as the Mail VM.
# Creates private-data/web-1-offsite-backup.env (new restic password) once; upload it to the AW Vault.
# Nightly 02:45 IST, weekly verify + restore test of domains_rajesh Sunday 04:30 IST.
# Failure alerts go to rajesh@nextdp.com through the Mail VM's SMTP on its private IP (AWS blocks public :25).
param([switch]$NoRunNow)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
& (Join-Path $PSScriptRoot "..\mail-vm\16-setup-offsite-backup.ps1") `
    -VmName "Web-1" -VmLabel "Web-1" -RepoPrefix "aws-web-1" `
    -PasswordFileName "web-1-offsite-backup.env" -RunbookName "web-1-offsite-backup.md" `
    -BackupConf (Join-Path $repoRoot "templates\backup\web-1.backup.conf") `
    -AlertSmtpHost "172.26.3.188" `
    -BackupCalendar "*-*-* 21:15:00 UTC" -VerifyCalendar "Sat *-*-* 23:00:00 UTC" `
    -NoRunNow:$NoRunNow
