# Load LocalCen's place packs (states, districts, mandals, villages, panchayats, towns, wards, constituencies) on
# LocalCen-1-VM. Packs: the newest per state from the Azure archive (nmc-php-stage-1-osdisk, code/srv/apps/localcen.tar.zst
# -> srv/apps/localcen/shared/geo-packs/), kept on the PC in D:\nmc-backup\localcen-geo-packs\.
#   .\scripts\localcen-1-vm\07-import-geo-packs.ps1            # fetch packs (if missing) + check
#   .\scripts\localcen-1-vm\07-import-geo-packs.ps1 -Apply     # backup localcen_db, import, status
param([switch]$Apply, [string[]]$Packs = @("36-2026-11-08", "28-2026-11-08"), [string]$LocalDir = "D:\nmc-backup\localcen-geo-packs")
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\mail-vm\common.ps1")
Initialize-Toolchain
$repo = Resolve-RepoRoot
$rv = Get-VmTarget -RepoRoot $repo -Name "Recovery-VM"
$lc = Get-VmTarget -RepoRoot $repo -Name "LocalCen-1-VM"
$ro = @("-i", $rv.SshKey, "-o", "BatchMode=yes", "-o", "ConnectTimeout=20")
$lo = @("-i", $lc.SshKey, "-o", "BatchMode=yes", "-o", "ConnectTimeout=20")
New-Item -ItemType Directory -Force $LocalDir | Out-Null
$missing = @($Packs | Where-Object { -not (Test-Path (Join-Path $LocalDir "$_\manifest.json")) })
if ($missing.Count -gt 0) {
    Write-Host "Fetching $($missing -join ', ') from the archive (Recovery-VM local copy, else the bucket)..."
    $members = ($missing | ForEach-Object { "srv/apps/localcen/shared/geo-packs/$_" }) -join ' '
    $tmp = "/tmp/geo-packs-$PID"
    & ssh -n @ro $rv.Target "sudo bash -c 'set -e; src=/work/out/nmc-php-stage-1-osdisk/code/srv/apps/localcen.tar.zst; if [ ! -s `$src ]; then set -a; . /root/.r2-azure-archive.env; set +a; rclone copyto archive:`$R2_BUCKET/nmc-php-stage-1-osdisk/code/srv/apps/localcen.tar.zst /work/tmp/localcen.tar.zst; src=/work/tmp/localcen.tar.zst; fi; mkdir -p $tmp; zstd -dc `$src | tar -x -C $tmp --strip-components=5 $members; chown -R ubuntu $tmp'"
    if ($LASTEXITCODE -ne 0) { throw "extract on Recovery-VM failed" }
    foreach ($p in $missing) {
        & scp -q -r @ro "$($rv.Target):$tmp/$p" $LocalDir | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "download of $p failed" }
    }
    & ssh -n @ro $rv.Target "sudo rm -rf $tmp /work/tmp/localcen.tar.zst"
}
foreach ($p in $Packs) { if (-not (Test-Path (Join-Path $LocalDir "$p\manifest.json"))) { throw "pack $p missing in $LocalDir" } }
Write-Host "Packs on the PC: $LocalDir ($($Packs -join ', '))"
$stage = "/tmp/geo-packs-$PID"
& ssh -n @lo $lc.Target "mkdir -p $stage" | Out-Null
foreach ($p in $Packs) { & scp -q -r @lo (Join-Path $LocalDir $p) "$($lc.Target):$stage/" | Out-Null; if ($LASTEXITCODE -ne 0) { throw "upload $p failed" } }
$rs = "/tmp/07-geo-$PID.sh"
& scp -q @lo (Join-Path $PSScriptRoot "07-import-geo-packs.sh") "$($lc.Target):$rs" | Out-Null
$mode = if ($Apply) { "apply" } else { "check" }
& ssh -n @lo $lc.Target "sed -i 's/\r$//' $rs && MODE=$mode PACKS_DIR=$stage bash $rs; echo rc=`$?; rm -f $rs"
