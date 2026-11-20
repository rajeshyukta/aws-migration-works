# Phase 2 (docs/mail-vm-db-upgrade-r2.md): rehearse (default, no downtime) or run the real cutover.
#   powershell -File .\scripts\mail-vm\14-cutover-mail-db.ps1              # rehearsal
#   powershell -File .\scripts\mail-vm\14-cutover-mail-db.ps1 -Cutover     # ~5-10 min mail downtime
param(
    [switch]$Cutover,
    [string]$SnapshotId = "689c5e6a",
    [string]$LocalRoot = "D:\nmc-backup\mail-vm"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if ($SnapshotId -notmatch '^[0-9a-f]{8,64}$') { throw "Invalid snapshot id" }

. (Join-Path $PSScriptRoot "common.ps1")
Initialize-Toolchain
$vm = Get-VmTarget -Name "Mail VM"
$mode = if ($Cutover) { "cutover" } else { "rehearse" }
$remoteDir = "/tmp/awsmig-cutover-$PID"

Invoke-VmCommand -Vm $vm -Command "mkdir -p $remoteDir && chmod 700 $remoteDir"
try {
    foreach ($f in "11-stage-r2-mail-db.sh", "13-merge-aws-delta.sh", "13-merge-aws-delta.sql", "14-cutover-mail-db.sh") {
        Copy-ToVm -Vm $vm -LocalPath (Join-Path $PSScriptRoot $f) -RemotePath "$remoteDir/$f"
    }
    Invoke-VmCommand -Vm $vm -Command "sed -i 's/\r$//' $remoteDir/*.sh && MODE=$mode SNAPSHOT_ID=$SnapshotId SCRIPT_DIR=$remoteDir bash $remoteDir/14-cutover-mail-db.sh 2>&1 | tee $remoteDir/run.log; exit `${PIPESTATUS[0]}"
} finally {
    & ssh -i $vm.SshKey -o BatchMode=yes $vm.Target "rm -rf $remoteDir" 2>$null
}

if ($Cutover) {
    $last = (& ssh -i $vm.SshKey -o BatchMode=yes $vm.Target "ls -1d /var/backups/nextdp/cutover-*Z 2>/dev/null | tail -1").Trim()
    if ($last) {
        $localDir = Join-Path $LocalRoot (Split-Path $last -Leaf)
        New-Item -ItemType Directory -Force -Path $localDir | Out-Null
        & scp -i $vm.SshKey -o BatchMode=yes "$($vm.Target):$last/*.dump" "$($vm.Target):$last/*.tar.gz" "$($vm.Target):$last/*.csv" "$($vm.Target):$last/SHA256SUMS" $localDir
        if ($LASTEXITCODE -ne 0) { throw "download of cutover backups failed" }
        Write-Host "Cutover backups downloaded to $localDir (dot-env copy stays on the VM)"
    }
}
