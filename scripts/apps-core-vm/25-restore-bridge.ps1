# Bring back BaluBot / Bridge (balubot.rajesh1.com; was balubot.rajesh.in) on Apps-Core-VM with its old data:
# /etc/bridge/env + gcp-sa.json from the Azure archive of nmc-apps-1-osdisk, the database from nmc-db-1-osdisk.
#   .\scripts\apps-core-vm\25-restore-bridge.ps1          # fetch + check (nothing written on Apps-Core)
#   .\scripts\apps-core-vm\25-restore-bridge.ps1 -Apply   # backups, the repo's setup.sh, old env, DB restore
# Then the repo's own deploy: E:\workspace\projects\products\custom-android-os\tools\bridge-test.ps1 -Deploy
# Secrets pass through private-data/bridge-restore/ (gitignored) and are never printed.
param([switch]$Apply)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\mail-vm\common.ps1")
Initialize-Toolchain
$repo = Resolve-RepoRoot
$app = "E:\workspace\projects\products\custom-android-os"
$rv = Get-VmTarget -RepoRoot $repo -Name "Recovery-VM"
$ac = Get-VmTarget -RepoRoot $repo -Name "Apps-Core-VM"
$ro = @("-i", $rv.SshKey, "-o", "BatchMode=yes", "-o", "ConnectTimeout=20")
$ao = @("-i", $ac.SshKey, "-o", "BatchMode=yes", "-o", "ConnectTimeout=20")
$pc = Join-Path $repo "private-data\bridge-restore"
New-Item -ItemType Directory -Force $pc | Out-Null
if (-not ((Test-Path (Join-Path $pc "env")) -and (Test-Path (Join-Path $pc "gcp-sa.json")) -and (Test-Path (Join-Path $pc "bridge.dump")))) {
    $t = "/tmp/bridge-restore-$PID"
    $fetch = @"
set -euo pipefail
set -a; . /root/.r2-azure-archive.env; set +a
T=/work/tmp/bridge-$PID; mkdir -p `$T; chmod 700 `$T; trap 'rm -rf `$T' EXIT
A=/work/out/nmc-apps-1-osdisk/env.tar.zst.gpg
[ -s `$A ] && cp `$A `$T/env.gpg || rclone copyto archive:`$R2_BUCKET/nmc-apps-1-osdisk/env.tar.zst.gpg `$T/env.gpg
D=`$(ls -d /work/out/nmc-db-1-osdisk/db/*/ 2>/dev/null | head -1)
if [ -n "`$D" ] && [ -s "`$D/bridge.dump" ]; then cp "`$D/bridge.dump" `$T/; else
  rclone copyto "archive:`$R2_BUCKET/nmc-db-1-osdisk/db/`$(rclone lsf archive:`$R2_BUCKET/nmc-db-1-osdisk/db/ | head -1)bridge.dump" `$T/bridge.dump; fi
gpg --batch --quiet --pinentry-mode loopback --passphrase-fd 3 -d `$T/env.gpg 3< <(printf '%s' "`$ARCHIVE_PASSPHRASE") | zstd -dq | tar -x -C `$T etc/bridge/env etc/bridge/gcp-sa.json
install -d -m 700 -o ubuntu $t
install -m 600 -o ubuntu `$T/etc/bridge/env $t/env
install -m 600 -o ubuntu `$T/etc/bridge/gcp-sa.json $t/gcp-sa.json
install -m 600 -o ubuntu `$T/bridge.dump $t/bridge.dump
"@
    $f = Join-Path $env:TEMP "bridge-fetch-$PID.sh"
    [IO.File]::WriteAllText($f, ($fetch -replace "`r`n", "`n"), (New-Object Text.UTF8Encoding($false)))
    & scp -q @ro $f "$($rv.Target):/tmp/bridge-fetch.sh" | Out-Null; Remove-Item $f
    & ssh -n @ro $rv.Target "sudo bash /tmp/bridge-fetch.sh; rc=`$?; rm -f /tmp/bridge-fetch.sh; exit `$rc"
    if ($LASTEXITCODE -ne 0) { throw "extract on Recovery-VM failed" }
    foreach ($n in "env", "gcp-sa.json", "bridge.dump") { & scp -q @ro "$($rv.Target):$t/$n" (Join-Path $pc $n) | Out-Null; if ($LASTEXITCODE -ne 0) { throw "download $n failed" } }
    & ssh -n @ro $rv.Target "rm -rf $t" | Out-Null
    Write-Host "Fetched the old /etc/bridge (env + gcp-sa.json) and bridge.dump into $pc (not printed)"
}
$in = "/tmp/bridge-in-$PID"
& ssh -n @ao $ac.Target "umask 077 && mkdir -p $in" | Out-Null
foreach ($n in "env", "gcp-sa.json", "bridge.dump") { & scp -q @ao (Join-Path $pc $n) "$($ac.Target):$in/$n" | Out-Null; if ($LASTEXITCODE -ne 0) { throw "upload $n failed" } }
& scp -q @ao (Join-Path $app "backend\deploy\setup.sh") "$($ac.Target):$in/setup.sh" | Out-Null
$rs = "/tmp/25-bridge-$PID.sh"
& scp -q @ao (Join-Path $PSScriptRoot "25-restore-bridge.sh") "$($ac.Target):$rs" | Out-Null
$mode = if ($Apply) { "apply" } else { "check" }
& ssh -n @ao $ac.Target "sed -i 's/\r$//' $rs && sudo env MODE=$mode IN_DIR=$in bash $rs; rc=`$?; sudo rm -rf $in; rm -f $rs; exit `$rc"
if ($LASTEXITCODE -ne 0) { throw "prepare on Apps-Core-VM failed" }
