# One Azure disk on Recovery-VM (docs/azure-disk-archive.md).
#   .\scripts\recovery-vm\02-disk.ps1 -Disk nmc-php-stage-1-osdisk -Mode download   # read SAS (4 h) -> AzCopy -> revoke
#   .\scripts\recovery-vm\02-disk.ps1 -Disk nmc-php-stage-1-osdisk -Mode inspect    # read-only report
#   .\scripts\recovery-vm\02-disk.ps1 -Disk nmc-php-stage-1-osdisk -Mode umount|cleanup
# Azure: read-only. The SAS goes PC -> VM as a 0600 file, is never printed, and is revoked in `finally`.
param(
    [Parameter(Mandatory)] [string]$Disk,
    [Parameter(Mandatory)] [ValidateSet("download", "inspect", "umount", "cleanup")] [string]$Mode,
    [string]$ResourceGroup = ""
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if ($Disk -notmatch '^[A-Za-z0-9_.-]+$') { throw "Invalid -Disk" }
. (Join-Path $PSScriptRoot "..\mail-vm\common.ps1")
Initialize-Toolchain
$repo = Resolve-RepoRoot
$vm = Get-VmTarget -RepoRoot $repo -Name "Recovery-VM"
$o = @("-i", $vm.SshKey, "-o", "BatchMode=yes", "-o", "ConnectTimeout=20", "-o", "ServerAliveInterval=30")
$rs = "/tmp/02-disk-$PID.sh"
& scp -q @o (Join-Path $PSScriptRoot "02-disk.sh") "$($vm.Target):$rs" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "script upload failed" }
if ($Mode -ne "download") {
    & ssh -n @o $vm.Target "sed -i 's/\r$//' $rs && sudo env DISK=$Disk MODE=$Mode bash $rs; echo rc=`$?; rm -f $rs"
    return
}
if (-not $ResourceGroup) {
    # This az version needs -g for `disk list`; look in each group (PS 5.1: az's stderr must not stop the script).
    $eap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    foreach ($g in (az group list --query "[].name" -o tsv 2>$null)) {
        if (az disk show -g $g -n $Disk --query name -o tsv 2>$null) { $ResourceGroup = $g; break }
    }
    $ErrorActionPreference = $eap
}
if (-not $ResourceGroup) { throw "disk $Disk not found in any resource group" }
$gb = az disk show -g $ResourceGroup -n $Disk --query diskSizeGB -o tsv
if ($LASTEXITCODE -ne 0 -or -not $gb) { throw "az disk show failed" }
$granted = $false
$localSas = Join-Path $repo "private-data\azure-disk-$PID.sas"
$remoteSas = "/tmp/.azure-disk-$PID.sas"
try {
    Write-Host "Granting a 4 h read SAS for $ResourceGroup/$Disk ($gb GB)..."
    $sas = az disk grant-access -g $ResourceGroup -n $Disk --duration-in-seconds 14400 --access-level Read --query accessSAS -o tsv
    if ($LASTEXITCODE -ne 0 -or -not ($sas -like "https://*")) { throw "grant-access failed or returned no SAS" }
    $granted = $true
    [IO.File]::WriteAllText($localSas, $sas.Trim(), (New-Object Text.UTF8Encoding($false)))
    Remove-Variable sas
    & ssh -n @o $vm.Target "umask 077 && : > $remoteSas" | Out-Null
    & scp -q @o $localSas "$($vm.Target):$remoteSas" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "SAS upload failed" }
    Remove-Item -LiteralPath $localSas -Force
    & ssh -n @o $vm.Target "sed -i 's/\r$//' $rs && sudo env DISK=$Disk MODE=download SAS_FILE=$remoteSas EXPECTED_GB=$gb bash $rs; echo rc=`$?; rm -f $rs $remoteSas"
} finally {
    if (Test-Path $localSas) { Remove-Item -LiteralPath $localSas -Force }
    if ($granted) {
        az disk revoke-access -g $ResourceGroup -n $Disk -o none
        if ($LASTEXITCODE -eq 0) { Write-Host "SAS revoked for $Disk" } else { Write-Warning "revoke-access failed: az disk revoke-access -g $ResourceGroup -n $Disk" }
    }
}
