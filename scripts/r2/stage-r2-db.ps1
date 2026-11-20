# Restore an old Azure database from R2 SIDE BY SIDE on an AWS VM (as <db>_r2), or drop that copy.
# The live database and the services are never touched.
#
#   .\scripts\r2\stage-r2-db.ps1 -Vm "Apps-Core-VM" -Database nextdp_core
#   .\scripts\r2\stage-r2-db.ps1 -Vm "DNS VM" -Database dns_service -SnapshotId a143e215
#   .\scripts\r2\stage-r2-db.ps1 -Vm "DNS VM" -Database dns_service -Drop
#
# The dump comes from fetch-r2-dump.ps1 (a verified local copy in D:\nmc-backup\r2 is reused).
# -TargetDb defaults to <db>_r2 and must end in _r2. -Owner defaults to postgres (the staged copy is
# for reading and for import scripts that run as postgres, not for an app).
param(
    [Parameter(Mandatory = $true)][string]$Vm,
    [Parameter(Mandatory = $true)][string]$Database,
    [string]$SnapshotId = "",
    [string]$TargetDb = "",
    [string]$Owner = "postgres",
    [switch]$Drop,
    [switch]$Force,
    [string]$LocalRoot = "D:\nmc-backup\r2"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if ($Database -notmatch '^[a-z][a-z0-9_]{1,62}$') { throw "Invalid -Database" }
if (-not $TargetDb) { $TargetDb = "$($Database)_r2" }
if ($TargetDb -notmatch '^[a-z][a-z0-9_]*_r2$') { throw "-TargetDb must end in _r2" }
if ($Owner -notmatch '^[a-z_][a-z0-9_]*$') { throw "Invalid -Owner" }

. (Join-Path $PSScriptRoot "..\mail-vm\common.ps1")
Initialize-Toolchain
$target = Get-VmTarget -Name $Vm
$script = Join-Path $PSScriptRoot "stage-r2-db.sh"

if ($Drop) {
    Invoke-VmScript -Vm $target -LocalScriptPath $script -EnvPrefix "MODE=drop TARGET_DB=$TargetDb" | Out-Host
    return
}

$fetchArgs = @{ Database = $Database; LocalRoot = $LocalRoot }
if ($SnapshotId) { $fetchArgs.SnapshotId = $SnapshotId }
if ($Force) { $fetchArgs.Force = $true }
$dir = & (Join-Path $PSScriptRoot "fetch-r2-dump.ps1") @fetchArgs | Select-Object -Last 1
$meta = @{}
Get-Content (Join-Path $dir "meta.txt") | Where-Object { $_ -match '^(\w+)=(.*)$' } | ForEach-Object { $meta[$Matches[1]] = $Matches[2] }
$comment = "R2 snapshot $($meta.SNAPSHOT_ID) of $Database from $($meta.SOURCE_HOST) taken $($meta.SNAPSHOT_TIME_UTC)"
if ($comment -notmatch '^[A-Za-z0-9 _.:+\-]+$') { throw "Unexpected characters in meta.txt" }

$remoteDump = "/tmp/.r2-upload-$Database-$PID.dump"
Invoke-VmCommand -Vm $target -Command "umask 077 && : > $remoteDump"
Copy-ToVm -Vm $target -LocalPath (Join-Path $dir "$Database.dump") -RemotePath $remoteDump
Write-Host "Restoring $Database snapshot $($meta.SNAPSHOT_ID) ($($meta.SNAPSHOT_TIME_IST)) as $TargetDb on $Vm"
Invoke-VmScript -Vm $target -LocalScriptPath $script `
    -EnvPrefix "MODE=restore TARGET_DB=$TargetDb DUMP_FILE=$remoteDump DB_OWNER=$Owner DB_COMMENT='$comment'" | Out-Host
