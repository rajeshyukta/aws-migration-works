# Dump PostgreSQL databases straight from an old Azure VM OS disk (for data NMC never backed up to R2,
# e.g. the PowerDNS `pdns` DB on nmc-dns-1). Read-only on Azure (temporary read SAS, revoked at the end).
#
#   .\scripts\r2\azure-disk-pgdump.ps1 -Disk nmc-dns-1-osdisk -ResourceGroup DNS -Databases pdns
#   .\scripts\r2\azure-disk-pgdump.ps1 -Disk nmc-dns-1-osdisk -ResourceGroup DNS          # only list DBs
#
# Result per DB: D:\nmc-backup\azure\<disk>\<db>\{<db>.dump, SHA256SUMS, meta.txt} (same layout as
# fetch-r2-dump.ps1, so stage-r2-db.ps1 -DumpDir can restore it side by side).
# Needs `az login` on this PC and a helper VM with PostgreSQL 16 and disk >= disk size + 3 GB.
# Everything on the helper VM (VHD, data copy, temp cluster) is removed at the end, also on failure.
param(
    [Parameter(Mandatory = $true)][string]$Disk,
    [Parameter(Mandatory = $true)][string]$ResourceGroup,
    [string[]]$Databases = @(),
    [string]$HelperVm = "Apps-Core-VM",
    [string]$PgCluster = "16/main",
    [string]$Subscription = "53b184f6-7bb2-4fb9-9970-bc1aaf1e5818",
    [string]$LocalRoot = "D:\nmc-backup\azure",
    [switch]$KeepOnFailure,   # leave the VHD on the helper VM after an error (rerun with -SkipDownload)
    [switch]$SkipDownload     # reuse a VHD already downloaded by a run with -KeepOnFailure
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if ($Disk -notmatch '^[A-Za-z0-9._-]+$' -or $ResourceGroup -notmatch '^[A-Za-z0-9._-]+$') { throw "Invalid disk or resource group" }
if ($PgCluster -notmatch '^\d+/[a-z0-9_]+$') { throw "Invalid -PgCluster" }
foreach ($d in $Databases) { if ($d -notmatch '^[a-z][a-z0-9_]*$') { throw "Invalid database $d" } }

. (Join-Path $PSScriptRoot "..\mail-vm\common.ps1")
Initialize-Toolchain
$vm = Get-VmTarget -Name $HelperVm
$script = Join-Path $PSScriptRoot "azure-disk-pgdump.sh"
$ssh = @("-i", $vm.SshKey, "-o", "BatchMode=yes", "-o", "ConnectTimeout=20")

$gb = az disk show --subscription $Subscription -g $ResourceGroup -n $Disk --query diskSizeGB -o tsv
if ($LASTEXITCODE -ne 0 -or -not $gb) { throw "az disk show failed (az login?)" }
Write-Host "Disk $Disk ($gb GB) -> helper $HelperVm"
$base = "DISK_NAME=$Disk DISK_GB=$gb PG_CLUSTER=$PgCluster"
$remoteSas = "/tmp/.azure-disk-$PID.sas"
$localSas = Join-Path (Resolve-RepoRoot) "private-data\azure-disk-$PID.sas"
$granted = $false
$ok = $false
try {
  if (-not $SkipDownload) {
    $sas = az disk grant-access --subscription $Subscription -g $ResourceGroup -n $Disk --duration-in-seconds 7200 --access-level Read --query accessSAS -o tsv
    if ($LASTEXITCODE -ne 0 -or -not ($sas -like "https://*")) { throw "grant-access failed or returned no SAS" }
    $granted = $true
    [IO.File]::WriteAllText($localSas, $sas.Trim(), (New-Object Text.UTF8Encoding($false)))
    Remove-Variable sas
    Invoke-VmCommand -Vm $vm -Command "umask 077 && : > $remoteSas"
    Copy-ToVm -Vm $vm -LocalPath $localSas -RemotePath $remoteSas
    Remove-Item -LiteralPath $localSas -Force
    Invoke-VmScript -Vm $vm -LocalScriptPath $script -EnvPrefix "MODE=download $base SAS_FILE=$remoteSas" | Out-Host
  }
    Invoke-VmScript -Vm $vm -LocalScriptPath $script -EnvPrefix "MODE=dump $base DBS='$($Databases -join ' ')'" | Out-Host

    foreach ($db in $Databases) {
        $dir = Join-Path (Join-Path $LocalRoot $Disk) $db
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        foreach ($f in @("$db.dump", "SHA256SUMS", "meta.txt")) {
            & scp @ssh "$($vm.Target):/var/tmp/azure-disk-$Disk/out/$db/$f" $dir
            if ($LASTEXITCODE -ne 0) { throw "scp of $db/$f failed" }
        }
        $expected = ((Get-Content (Join-Path $dir "SHA256SUMS") -TotalCount 1) -split '\s+')[0]
        if ((Get-FileHash -Algorithm SHA256 (Join-Path $dir "$db.dump")).Hash.ToLowerInvariant() -ne $expected) { throw "SHA-256 mismatch for $db" }
        Write-Host "Verified local dump: $dir"
    }
    $ok = $true
} finally {
    if (Test-Path $localSas) { Remove-Item -LiteralPath $localSas -Force }
    if ($ok -or -not $KeepOnFailure) {
        try { Invoke-VmScript -Vm $vm -LocalScriptPath $script -EnvPrefix "MODE=cleanup $base SAS_FILE=$remoteSas" | Out-Host } catch { Write-Warning "helper cleanup failed: $_" }
    } else { Write-Warning "Kept the VHD on $HelperVm (-KeepOnFailure). Rerun with -SkipDownload, or without it to clean up." }
    if ($granted) {
        az disk revoke-access --subscription $Subscription -g $ResourceGroup -n $Disk -o none
        if ($LASTEXITCODE -eq 0) { Write-Host "SAS revoked for $Disk" } else { Write-Warning "revoke-access failed: run az disk revoke-access -g $ResourceGroup -n $Disk" }
    }
}
