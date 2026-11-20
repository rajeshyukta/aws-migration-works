# Get one database dump from the old NMC restic repo on R2 (nxtmngr-test/prod-main) to this PC.
#
#   .\scripts\r2\fetch-r2-dump.ps1 -List                         # latest snapshot per database
#   .\scripts\r2\fetch-r2-dump.ps1 -Database nextdp_core               # latest snapshot of nextdp_core
#   .\scripts\r2\fetch-r2-dump.ps1 -Database dns_service -SnapshotId a143e215
#
# Result: D:\nmc-backup\r2\<db>-<snapshot>\{<db>.dump, SHA256SUMS, meta.txt} (SHA-256 verified).
# A verified local copy is reused (no VM access) unless -Force. Returns the folder path.
#
# How: the unseal needs private-data/nmc-main-env.txt (JWT_SECRET) and the recovered NMC DB, which
# only exists on the Mail VM (cluster 16/nmcmain, port 5433). The env file goes to the VM as a 0600
# temp file and is deleted on exit; the cluster is stopped afterwards (use -KeepNmcRunning to skip);
# the dump is removed from the VM after the download. Nothing secret is printed.
param(
    [string]$Database,
    [string]$SnapshotId = "",
    [switch]$List,
    [switch]$Force,
    [switch]$KeepNmcRunning,
    [string]$LocalRoot = "D:\nmc-backup\r2"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if (-not $List -and $Database -notmatch '^[a-z][a-z0-9_]{1,62}$') { throw "Pass -Database <database> (e.g. nextdp_core) or -List" }
if ($SnapshotId -and $SnapshotId -notmatch '^[0-9a-f]{8,64}$') { throw "Invalid snapshot id" }

. (Join-Path $PSScriptRoot "..\mail-vm\common.ps1")

function Test-LocalDump([string]$Dir, [string]$Name) {
    $dump = Join-Path $Dir "$Name.dump"
    $sums = Join-Path $Dir "SHA256SUMS"
    if (-not ((Test-Path $dump) -and (Test-Path $sums) -and (Test-Path (Join-Path $Dir "meta.txt")))) { return $false }
    $expected = ((Get-Content $sums -TotalCount 1) -split '\s+')[0]
    return ((Get-FileHash -Algorithm SHA256 $dump).Hash.ToLowerInvariant() -eq $expected)
}

if (-not $List -and -not $Force) {
    $pattern = if ($SnapshotId) { "$Database-$($SnapshotId.Substring(0, 8))*" } else { "$Database-*" }
    if (Test-Path $LocalRoot) {
        $hit = Get-ChildItem $LocalRoot -Directory -Filter $pattern | Sort-Object LastWriteTime -Descending |
            Where-Object { Test-LocalDump $_.FullName $Database } | Select-Object -First 1
        if ($hit) {
            Write-Host "Reusing verified local dump: $($hit.FullName) (use -Force to fetch again)"
            return $hit.FullName
        }
    }
}

Initialize-Toolchain
$vm = Get-VmTarget -Name "Mail VM"
$envFile = Join-Path (Resolve-RepoRoot) "private-data\nmc-main-env.txt"
if (-not (Test-Path $envFile)) { throw "Missing $envFile" }

$remoteEnv = "/tmp/.nmc-main-env-$PID"
$remoteOut = "/var/tmp/r2-fetch-$Database-$PID"
$ssh = @("-i", $vm.SshKey, "-o", "BatchMode=yes", "-o", "ConnectTimeout=20")
# Create the file 0600 first so scp writes into it without a world-readable window.
Invoke-VmCommand -Vm $vm -Command "umask 077 && : > $remoteEnv"
Copy-ToVm -Vm $vm -LocalPath $envFile -RemotePath $remoteEnv

$mode = if ($List) { "list" } else { "dump" }
$stop = if ($KeepNmcRunning) { "0" } else { "1" }
try {
    Invoke-VmScript -Vm $vm -LocalScriptPath (Join-Path $PSScriptRoot "fetch-r2-dump.sh") `
        -EnvPrefix "NMC_ENV_FILE=$remoteEnv MODE=$mode DB_NAME=$Database SNAPSHOT_ID=$SnapshotId OUT_DIR=$remoteOut STOP_NMC_AFTER=$stop" | Out-Host
} finally {
    & ssh @ssh $vm.Target "rm -f $remoteEnv" 2>$null
}
if ($List) { return }

$incoming = Join-Path $LocalRoot "_incoming-$PID"
New-Item -ItemType Directory -Force -Path $incoming | Out-Null
try {
    foreach ($f in @("$Database.dump", "SHA256SUMS", "meta.txt")) {
        & scp @ssh "$($vm.Target):$remoteOut/$f" $incoming
        if ($LASTEXITCODE -ne 0) { throw "scp download of $f failed" }
    }
    if (-not (Test-LocalDump $incoming $Database)) { throw "SHA-256 mismatch on the local copy" }
    $meta = @{}
    Get-Content (Join-Path $incoming "meta.txt") | Where-Object { $_ -match '^(\w+)=(.*)$' } | ForEach-Object { $meta[$Matches[1]] = $Matches[2] }
    $final = Join-Path $LocalRoot "$Database-$($meta.SNAPSHOT_ID)"
    if (Test-Path $final) { Remove-Item -Recurse -Force $final }
    Move-Item $incoming $final
} catch {
    if (Test-Path $incoming) { Remove-Item -Recurse -Force $incoming }
    throw
} finally {
    & ssh @ssh $vm.Target "rm -rf $remoteOut" 2>$null
}
Write-Host "Verified local dump: $final ($($meta.SNAPSHOT_TIME_IST), $($meta.DUMP_BYTES) bytes)"
return $final
