# Set up Recovery-VM (16.4.71.66) for the Azure disk archive: work volume, tools, R2 remote, bucket test.
#   .\scripts\recovery-vm\01-setup.ps1
# private-data/r2-azure-archive.env (R2_BUCKET, R2_ENDPOINT, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, ARCHIVE_PASSPHRASE)
# goes to the VM as /root/.r2-azure-archive.env (0600). Nothing secret is printed. Doc: docs/azure-disk-archive.md
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\mail-vm\common.ps1")
Initialize-Toolchain
$repo = Resolve-RepoRoot
$vm = Get-VmTarget -RepoRoot $repo -Name "Recovery-VM"
$o = @("-i", $vm.SshKey, "-o", "BatchMode=yes", "-o", "ConnectTimeout=20")
$envFile = Join-Path $repo "private-data\r2-azure-archive.env"
if (-not (Test-Path $envFile)) { throw "missing $envFile" }
$names = Get-Content $envFile | ForEach-Object { if ($_ -match '^\s*([A-Z0-9_]+)\s*=\s*\S') { $Matches[1] } }
foreach ($k in "R2_BUCKET", "R2_ENDPOINT", "R2_ACCESS_KEY_ID", "R2_SECRET_ACCESS_KEY", "ARCHIVE_PASSPHRASE") {
    if ($names -notcontains $k) { throw "$k missing in $envFile" }
}
$tmp = "/tmp/.r2-azure-archive-$PID.env"
& ssh -n @o $vm.Target "umask 077 && : > $tmp" | Out-Null
& scp -q @o $envFile "$($vm.Target):$tmp" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "env upload failed" }
& ssh -n @o $vm.Target "sed -i 's/\r$//' $tmp && sudo install -o root -g root -m 0600 $tmp /root/.r2-azure-archive.env; rm -f $tmp"
Write-Host "Installed /root/.r2-azure-archive.env (not printed)"
$rs = "/tmp/01-recovery-setup-$PID.sh"
& scp -q @o (Join-Path $PSScriptRoot "01-setup.sh") "$($vm.Target):$rs" | Out-Null
& ssh -n @o $vm.Target "sed -i 's/\r$//' $rs && bash $rs; echo rc=`$?; rm -f $rs"
