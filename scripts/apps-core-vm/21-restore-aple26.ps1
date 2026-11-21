# Bring back aple26 (AP 2026 Local Elections, aple26.ogcen.com) on Apps-Core-VM with its old data from the Azure
# disk archive (nmc-php-stage-1-osdisk: db/.../aple26.dump + the old shared/.env from env.tar.zst.gpg).
#   .\scripts\apps-core-vm\21-restore-aple26.ps1            # fetch from the archive + check (nothing written on Apps-Core)
#   .\scripts\apps-core-vm\21-restore-aple26.ps1 -Apply     # backups, user, old .env, DB restore, then the app's own
#                                                           # scripts/deploy.sh --bootstrap (DEPLOY_HOST = Apps-Core-VM)
# The .env and dump pass through private-data/aple26-restore/ (gitignored; kept as the PC copy). Nothing is printed.
param([switch]$Apply)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\mail-vm\common.ps1")
Initialize-Toolchain
$repo = Resolve-RepoRoot
$app = "E:\workspace\projects\products\ap-2026-local-elections"
$rv = Get-VmTarget -RepoRoot $repo -Name "Recovery-VM"
$ac = Get-VmTarget -RepoRoot $repo -Name "Apps-Core-VM"
$ro = @("-i", $rv.SshKey, "-o", "BatchMode=yes", "-o", "ConnectTimeout=20")
$ao = @("-i", $ac.SshKey, "-o", "BatchMode=yes", "-o", "ConnectTimeout=20")
$pc = Join-Path $repo "private-data\aple26-restore"
New-Item -ItemType Directory -Force $pc | Out-Null

# 1. from the archive (Recovery-VM's local export; else the bucket)
if (-not (Test-Path (Join-Path $pc ".env")) -or -not (Test-Path (Join-Path $pc "aple26.dump"))) {
    $t = "/tmp/aple26-restore-$PID"
    $cmd = @"
set -euo pipefail
set -a; . /root/.r2-azure-archive.env; set +a
D=nmc-php-stage-1-osdisk; O=/work/out/`$D; T=/work/tmp/aple26-$PID; mkdir -p `$T; chmod 700 `$T
for f in env.tar.zst.gpg db/var_lib_postgresql_16_main/aple26.dump; do
  [ -s `$O/`$f ] && cp `$O/`$f `$T/ || rclone copyto archive:`$R2_BUCKET/`$D/`$f `$T/`$(basename `$f)
done
gpg --batch --quiet --pinentry-mode loopback --passphrase-fd 3 -d `$T/env.tar.zst.gpg 3< <(printf '%s' "`$ARCHIVE_PASSPHRASE") | zstd -dq | tar -x -C `$T srv/apps/aple26/shared/.env
install -d -m 700 -o ubuntu $t
install -m 600 -o ubuntu `$T/srv/apps/aple26/shared/.env $t/.env
install -m 600 -o ubuntu `$T/aple26.dump $t/aple26.dump
rm -rf `$T
"@
    $f = Join-Path $env:TEMP "aple26-fetch-$PID.sh"
    [IO.File]::WriteAllText($f, ($cmd -replace "`r`n", "`n"), (New-Object Text.UTF8Encoding($false)))
    & scp -q @ro $f "$($rv.Target):/tmp/aple26-fetch.sh" | Out-Null; Remove-Item $f
    & ssh -n @ro $rv.Target "sudo bash /tmp/aple26-fetch.sh; rc=`$?; rm -f /tmp/aple26-fetch.sh; exit `$rc"
    if ($LASTEXITCODE -ne 0) { throw "extract on Recovery-VM failed" }
    foreach ($n in ".env", "aple26.dump") { & scp -q @ro "$($rv.Target):$t/$n" (Join-Path $pc $n) | Out-Null; if ($LASTEXITCODE -ne 0) { throw "download $n failed" } }
    & ssh -n @ro $rv.Target "rm -rf $t" | Out-Null
    Write-Host "Fetched the old .env + aple26.dump into $pc (not printed)"
}

# 2. prepare on Apps-Core-VM (check or apply)
$in = "/tmp/aple26-in-$PID"
& ssh -n @ao $ac.Target "umask 077 && mkdir -p $in" | Out-Null
foreach ($n in ".env", "aple26.dump") { & scp -q @ao (Join-Path $pc $n) "$($ac.Target):$in/$n" | Out-Null; if ($LASTEXITCODE -ne 0) { throw "upload $n failed" } }
$rs = "/tmp/21-aple26-$PID.sh"
& scp -q @ao (Join-Path $PSScriptRoot "21-restore-aple26.sh") "$($ac.Target):$rs" | Out-Null
$mode = if ($Apply) { "apply" } else { "check" }
& ssh -n @ao $ac.Target "sed -i 's/\r$//' $rs && sudo env MODE=$mode IN_DIR=$in bash $rs; rc=`$?; sudo rm -rf $in; rm -f $rs; exit `$rc"
if ($LASTEXITCODE -ne 0) { throw "prepare on Apps-Core-VM failed" }
if (-not $Apply) { return }

# 3. the app's own bootstrap + release, pointed at Apps-Core-VM (Git Bash; deploy.sh runs the app's fast suite first)
$bash = "C:\Program Files\Git\bin\bash.exe"
if (-not (Test-Path $bash)) { throw "Git Bash not found" }
$key = ($ac.SshKey -replace '^([A-Za-z]):', '/$1' -replace '\\', '/').ToLower()
Write-Host "Running the app's deploy.sh --bootstrap against $($ac.Target)..."
$env:DEPLOY_HOST = $ac.Target; $env:DEPLOY_KEY = $key
try {
    Push-Location $app
    # 2026-11-21: with EAP=Stop, the build's stderr line ended this script while bash went on (release 20261121101843
    # was installed anyway); judge by bash's exit code only.
    $ErrorActionPreference = "Continue"
    & $bash -lc "bash scripts/deploy.sh --bootstrap" 2>&1 | ForEach-Object { "$_" }
    if ($LASTEXITCODE -ne 0) { throw "deploy.sh --bootstrap failed" }
} finally {
    Pop-Location
    Remove-Item Env:DEPLOY_HOST, Env:DEPLOY_KEY -ErrorAction SilentlyContinue
}
