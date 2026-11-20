# Task 1.2 (docs/mail-vm-db-upgrade-r2.md): stage the R2 nextdp_mail snapshot as a side-by-side DB.
# Sends private-data/nmc-main-env.txt to the VM as a 0600 temp file (deleted on exit), keeps the
# extracted dump on the VM under /var/backups/nextdp/r2-<snapshot>/ and downloads a copy here.
param(
    [string]$SnapshotId = "689c5e6a",
    [string]$TargetDb = "nextdp_mail_r2",
    [switch]$ForceDownload,
    [string]$LocalRoot = "D:\nmc-backup\mail-vm"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if ($SnapshotId -notmatch '^[0-9a-f]{8,64}$') { throw "Invalid snapshot id" }
if ($TargetDb -notmatch '^nextdp_mail_[a-z0-9_]+$') { throw "TargetDb must match nextdp_mail_<suffix>" }

. (Join-Path $PSScriptRoot "common.ps1")
Initialize-Toolchain
$vm = Get-VmTarget -Name "Mail VM"
$envFile = Join-Path (Resolve-RepoRoot) "private-data\nmc-main-env.txt"
if (-not (Test-Path $envFile)) { throw "Missing $envFile" }

Copy-ToVm -Vm $vm -LocalPath $envFile -RemotePath "/tmp/.nmc-main-env"
Invoke-VmCommand -Vm $vm -Command "chmod 600 /tmp/.nmc-main-env"
$reuse = if ($ForceDownload) { "0" } else { "1" }
try {
    Invoke-VmScript -Vm $vm -LocalScriptPath (Join-Path $PSScriptRoot "11-stage-r2-mail-db.sh") `
        -EnvPrefix "SNAPSHOT_ID=$SnapshotId TARGET_DB=$TargetDb REUSE_DUMP=$reuse"
} finally {
    & ssh -i $vm.SshKey -o BatchMode=yes $vm.Target "rm -f /tmp/.nmc-main-env" 2>$null
}

$localDir = Join-Path $LocalRoot "r2-$SnapshotId"
New-Item -ItemType Directory -Force -Path $localDir | Out-Null
& scp -i $vm.SshKey -o BatchMode=yes "$($vm.Target):/var/backups/nextdp/r2-$SnapshotId/nextdp_mail.dump" "$($vm.Target):/var/backups/nextdp/r2-$SnapshotId/SHA256SUMS" $localDir
if ($LASTEXITCODE -ne 0) { throw "scp download failed" }
$expected = ((Get-Content (Join-Path $localDir "SHA256SUMS")) -split '\s+')[0]
$actual = (Get-FileHash -Algorithm SHA256 (Join-Path $localDir "nextdp_mail.dump")).Hash.ToLowerInvariant()
if ($actual -ne $expected) { throw "SHA-256 mismatch on local copy" }
Write-Host "Local copy verified: $localDir\nextdp_mail.dump"
