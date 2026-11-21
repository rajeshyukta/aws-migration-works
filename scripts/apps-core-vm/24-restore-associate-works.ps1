# Bring back Associate Works (associate.works, admin.associate.works) on Apps-Core-VM with its old data:
# /etc/aw (backend.env + GeoIP) from the Azure archive of nmc-apps-1-osdisk, the database from nmc-db-1-osdisk,
# storage on the new AWS bucket (23-provision-aw-s3). Old files on the interim MinIO are not brought back (owner).
#   .\scripts\apps-core-vm\24-restore-associate-works.ps1             # fetch + check (nothing written on Apps-Core)
#   .\scripts\apps-core-vm\24-restore-associate-works.ps1 -Apply      # backups, user, /etc/aw, DB restore, deploy
#   .\scripts\apps-core-vm\24-restore-associate-works.ps1 -DeployOnly # redeploy code only (later releases)
# Deploy = the app's own devops/deploy-backend.ps1 + deploy-frontend.ps1 steps (go test gate, release dir, migrate,
# units, health; SPA swap), pointed at Apps-Core-VM; backend on :8093 (Next iDP has :8080 here); Caddy site from
# devops/Caddyfile with that port. Secrets pass through private-data/aw-restore/ (gitignored) and are never printed.
param([switch]$Apply, [switch]$DeployOnly, [int]$Port = 8093)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\mail-vm\common.ps1")
Initialize-Toolchain
$repo = Resolve-RepoRoot
$app = "E:\workspace\projects\products\associate-works"
$rv = Get-VmTarget -RepoRoot $repo -Name "Recovery-VM"
$ac = Get-VmTarget -RepoRoot $repo -Name "Apps-Core-VM"
$ro = @("-i", $rv.SshKey, "-o", "BatchMode=yes", "-o", "ConnectTimeout=20")
$ao = @("-i", $ac.SshKey, "-o", "BatchMode=yes", "-o", "ConnectTimeout=20", "-o", "ServerAliveInterval=30")
$pc = Join-Path $repo "private-data\aw-restore"
$s3 = Join-Path $repo "private-data\associate-works-s3.env"
function Send-Script([string]$text, [string]$name) {
    $f = Join-Path $env:TEMP "$name-$PID.sh"
    [IO.File]::WriteAllText($f, ($text -replace "`r`n", "`n"), (New-Object Text.UTF8Encoding($false)))
    & scp -q @ao $f "$($ac.Target):/tmp/$name-$PID.sh" | Out-Null; Remove-Item $f
    if ($LASTEXITCODE -ne 0) { throw "upload $name failed" }
    return "/tmp/$name-$PID.sh"
}

if (-not $DeployOnly) {
    if (-not (Test-Path $s3)) { throw "missing $s3 (run 23-provision-aw-s3.ps1)" }
    # 1. from the archive (Recovery-VM local export; else the bucket)
    if (-not (Test-Path (Join-Path $pc "backend.env")) -or -not (Test-Path (Join-Path $pc "associate_works.dump"))) {
        New-Item -ItemType Directory -Force (Join-Path $pc "geoip") | Out-Null
        $t = "/tmp/aw-restore-$PID"
        $fetch = @"
set -euo pipefail
set -a; . /root/.r2-azure-archive.env; set +a
T=/work/tmp/aw-$PID; mkdir -p `$T; chmod 700 `$T; trap 'rm -rf `$T' EXIT
get() { [ -s /work/out/`$1 ] && cp /work/out/`$1 `$T/`$2 || rclone copyto archive:`$R2_BUCKET/`$1 `$T/`$2; }
get nmc-apps-1-osdisk/env.tar.zst.gpg env.gpg
D=`$(ls -d /work/out/nmc-db-1-osdisk/db/*/ 2>/dev/null | head -1)
if [ -n "`$D" ] && [ -s "`$D/associate_works.dump" ]; then cp "`$D/associate_works.dump" `$T/; else
  rclone copyto "archive:`$R2_BUCKET/nmc-db-1-osdisk/db/`$(rclone lsf archive:`$R2_BUCKET/nmc-db-1-osdisk/db/ | head -1)associate_works.dump" `$T/associate_works.dump; fi
gpg --batch --quiet --pinentry-mode loopback --passphrase-fd 3 -d `$T/env.gpg 3< <(printf '%s' "`$ARCHIVE_PASSPHRASE") | zstd -dq | tar -x -C `$T etc/aw/backend.env etc/aw/geoip
install -d -m 700 -o ubuntu $t $t/geoip
install -m 600 -o ubuntu `$T/etc/aw/backend.env $t/backend.env
install -m 600 -o ubuntu `$T/associate_works.dump $t/associate_works.dump
for m in `$T/etc/aw/geoip/*.mmdb; do install -m 600 -o ubuntu `$m $t/geoip/; done
"@
        $f = Join-Path $env:TEMP "aw-fetch-$PID.sh"
        [IO.File]::WriteAllText($f, ($fetch -replace "`r`n", "`n"), (New-Object Text.UTF8Encoding($false)))
        & scp -q @ro $f "$($rv.Target):/tmp/aw-fetch.sh" | Out-Null; Remove-Item $f
        & ssh -n @ro $rv.Target "sudo bash /tmp/aw-fetch.sh; rc=`$?; rm -f /tmp/aw-fetch.sh; exit `$rc"
        if ($LASTEXITCODE -ne 0) { throw "extract on Recovery-VM failed" }
        & scp -q -r @ro "$($rv.Target):$t/*" $pc | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "download failed" }
        & ssh -n @ro $rv.Target "rm -rf $t" | Out-Null
        Write-Host "Fetched the old /etc/aw (backend.env + GeoIP) and associate_works.dump into $pc (not printed)"
    }
    # 2. prepare on Apps-Core-VM
    $in = "/tmp/aw-in-$PID"
    & ssh -n @ao $ac.Target "umask 077 && mkdir -p $in/geoip" | Out-Null
    foreach ($n in "backend.env", "associate_works.dump") { & scp -q @ao (Join-Path $pc $n) "$($ac.Target):$in/$n" | Out-Null; if ($LASTEXITCODE -ne 0) { throw "upload $n failed" } }
    Get-ChildItem (Join-Path $pc "geoip") -Filter *.mmdb | ForEach-Object { & scp -q @ao $_.FullName "$($ac.Target):$in/geoip/" | Out-Null }
    & scp -q @ao $s3 "$($ac.Target):$in/s3.env" | Out-Null
    $rs = "/tmp/24-aw-$PID.sh"
    & scp -q @ao (Join-Path $PSScriptRoot "24-restore-associate-works.sh") "$($ac.Target):$rs" | Out-Null
    $mode = if ($Apply) { "apply" } else { "check" }
    & ssh -n @ao $ac.Target "sed -i 's/\r$//' $rs && sudo env MODE=$mode IN_DIR=$in PORT=$Port bash $rs; rc=`$?; sudo rm -rf $in; rm -f $rs; exit `$rc"
    if ($LASTEXITCODE -ne 0) { throw "prepare on Apps-Core-VM failed" }
    if (-not $Apply) { return }
}

# 3. build (the app's deploy gate: go test ./...), upload, activate — mirrors devops/deploy-backend.ps1 + deploy-frontend.ps1
$eap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
Push-Location (Join-Path $app "backend")
try {
    Write-Host "== go test ./... (the app's deploy gate)"
    & go test ./... 2>&1 | Select-String -NotMatch '^ok |no test files|^go: downloading' | ForEach-Object { "$_" }
    if ($LASTEXITCODE -ne 0) { throw "tests failed - deploy aborted" }
    $sha = (& git rev-parse --short HEAD).Trim()
    $env:GOOS = "linux"; $env:GOARCH = "amd64"; $env:CGO_ENABLED = "0"
    & go build -ldflags "-s -w" -o bin/aw-backend ./cmd; $b = $LASTEXITCODE
    Remove-Item Env:GOOS, Env:GOARCH, Env:CGO_ENABLED -ErrorAction SilentlyContinue
    if ($b -ne 0) { throw "go build failed" }
} finally { Pop-Location }
Push-Location (Join-Path $app "frontend")
try {
    if (-not (Test-Path node_modules)) { $env:CI = "true"; & npm ci --no-fund --no-audit --loglevel=error 2>&1 | Select-Object -Last 3; if ($LASTEXITCODE -ne 0) { throw "npm ci failed" } }
    $env:Path = "$app\frontend\node_modules\.bin;" + $env:Path
    & npm run build 2>&1 | Select-Object -Last 4 | ForEach-Object { "$_" }
    if ($LASTEXITCODE -ne 0) { throw "frontend build failed" }
} finally { Pop-Location }
$ErrorActionPreference = $eap
$stage = Join-Path $env:TEMP "aw-stage-$PID"; New-Item -ItemType Directory -Force $stage | Out-Null
try {
    $release = "aw-backend-$sha-$(Get-Date -Format yyyyMMddHHmmss)"
    Copy-Item (Join-Path $app "backend\bin\aw-backend") (Join-Path $stage "aw-backend")
    foreach ($n in "tenant", "admin") { & tar -czf (Join-Path $stage "$n-dist.tar.gz") -C (Join-Path $app "frontend\apps\$n\dist") .; if ($LASTEXITCODE -ne 0) { throw "tar $n failed" } }
    & tar -czf (Join-Path $stage "home-dist.tar.gz") -C (Join-Path $app "frontend\apps\home") .
    Copy-Item (Join-Path $app "devops\aw-backend.service"), (Join-Path $app "devops\aw-scheduler.service") $stage
    $caddy = [IO.File]::ReadAllText((Join-Path $app "devops\Caddyfile")).Replace("localhost:8080", "localhost:$Port")
    [IO.File]::WriteAllText((Join-Path $stage "associate-works.caddy"), ("# From associate-works devops/Caddyfile, backend port $Port (aws-setup-and-migrations 24-restore-associate-works)`n" + ($caddy -replace "`r`n", "`n")), (New-Object Text.UTF8Encoding($false)))
    $up = "/tmp/aw-up-$PID"
    & ssh -n @ao $ac.Target "mkdir -p $up" | Out-Null
    Get-ChildItem $stage -File | ForEach-Object { & scp -q @ao $_.FullName "$($ac.Target):$up/" | Out-Null; if ($LASTEXITCODE -ne 0) { throw "upload $($_.Name) failed" } }
    Write-Host "Uploaded $release + SPAs + units + Caddy site"
    $act = @"
set -euo pipefail
exec 2>&1
U=$up; APP=aw; BIN=aw-backend; R=$release; PORT=$Port
trap 'rm -rf `$U' EXIT
grep -q "^APP_PORT=`$PORT`$" /etc/aw/backend.env || { echo "FATAL: /etc/aw/backend.env APP_PORT is not `$PORT"; exit 1; }
PREV=`$(readlink -f /opt/`$APP/bin/`$BIN 2>/dev/null || true)
install -o `$APP -g `$APP -m 0755 `$U/aw-backend /opt/`$APP/releases/`$R
ln -sfn /opt/`$APP/releases/`$R /opt/`$APP/bin/`$BIN; chown -h `$APP:`$APP /opt/`$APP/bin/`$BIN
echo "-- backup + migrate --"
TS=`$(date -u +%Y%m%dT%H%M%SZ); DB=`$(sed -n 's/^DB_NAME=//p' /etc/aw/backend.env | tail -1)
mkdir -p /var/backups/associate-works && chmod 700 /var/backups/associate-works
sudo -u postgres pg_dump -Fc -d "`$DB" > /var/backups/associate-works/pre-`$R.dump && echo "  backup /var/backups/associate-works/pre-`$R.dump"
ls -1t /var/backups/associate-works/pre-*.dump | tail -n +8 | xargs -r rm -f
sudo -u `$APP bash -c 'set -a; . /etc/aw/backend.env; set +a; cd /opt/aw && /opt/aw/bin/aw-backend migrate' 2>&1 | grep -vE 'DB_SSL_MODE|no .env file' | tail -5
echo "-- units --"
install -m 0644 `$U/aw-backend.service /etc/systemd/system/`$BIN.service
install -m 0644 `$U/aw-scheduler.service /etc/systemd/system/aw-scheduler.service
systemctl daemon-reload; systemctl enable -q `$BIN aw-scheduler
systemctl restart `$BIN aw-scheduler
ok=""; for i in `$(seq 1 40); do curl -fsS -m 3 http://127.0.0.1:`$PORT/health >/dev/null 2>&1 && { ok=1; break; }; sleep 1; done
if [ -z "`$ok" ]; then
  echo "!! health failed"; journalctl -u `$BIN -n 30 --no-pager | grep -v DB_SSL_MODE | cut -c1-220
  if [ -n "`$PREV" ] && [ -f "`$PREV" ]; then ln -sfn "`$PREV" /opt/`$APP/bin/`$BIN; systemctl restart `$BIN aw-scheduler; echo "rolled back to `$PREV"; fi
  exit 1
fi
echo "  healthy: `$(curl -fsS -m 3 http://127.0.0.1:`$PORT/health | head -c 160) | scheduler `$(systemctl is-active aw-scheduler)"
cd /opt/`$APP/releases && ls -t | tail -n +6 | xargs -r rm -f --
echo "-- SPAs --"
for n in tenant admin home; do
  rm -rf /opt/`$APP/web/`$n.new; mkdir -p /opt/`$APP/web/`$n.new; tar -xzf `$U/`$n-dist.tar.gz -C /opt/`$APP/web/`$n.new
  [ -d /opt/`$APP/web/`$n.new/assets ] && ls -1 /opt/`$APP/web/`$n.new/assets > /opt/`$APP/web/`$n.new/.own-assets
  if [ -d /opt/`$APP/web/`$n/assets ] && [ -d /opt/`$APP/web/`$n.new/assets ]; then
    for f in `$(cat /opt/`$APP/web/`$n/.own-assets 2>/dev/null || ls -1 /opt/`$APP/web/`$n/assets); do
      [ -f /opt/`$APP/web/`$n/assets/`$f ] && [ ! -e /opt/`$APP/web/`$n.new/assets/`$f ] && cp -p /opt/`$APP/web/`$n/assets/`$f /opt/`$APP/web/`$n.new/assets/ || true
    done
  fi
  chown -R `$APP:`$APP /opt/`$APP/web/`$n.new; chmod -R o+rX /opt/`$APP/web/`$n.new
  rm -rf /opt/`$APP/web/`$n.old; [ -d /opt/`$APP/web/`$n ] && mv /opt/`$APP/web/`$n /opt/`$APP/web/`$n.old
  mv /opt/`$APP/web/`$n.new /opt/`$APP/web/`$n
  echo "  `$n: index `$([ -f /opt/`$APP/web/`$n/index.html ] && echo ok || echo -), `$(ls -1 /opt/`$APP/web/`$n/assets 2>/dev/null | wc -l) assets"
done
chmod o+x /opt /opt/`$APP /opt/`$APP/web
echo "-- caddy --"
SITE=/etc/caddy/sites-enabled/associate-works.caddy; BAK=""
[ -f `$SITE ] && BAK=`$(mktemp) && cp `$SITE `$BAK
install -m 0644 `$U/associate-works.caddy `$SITE
if caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/tmp/.aw-caddy.log 2>&1 && systemctl reload caddy; then
  echo "  site installed, caddy reloaded (`$(systemctl is-active caddy))"
else
  tail -5 /tmp/.aw-caddy.log; if [ -n "`$BAK" ]; then cp `$BAK `$SITE; else rm -f `$SITE; fi; systemctl reload caddy || true
  echo "FATAL: caddy refused the site (restored)"; exit 1
fi
rm -f /tmp/.aw-caddy.log `$BAK
echo "DEPLOY OK: `$R"
"@
    $rs = Send-Script $act "aw-activate"
    & ssh -n @ao $ac.Target "sudo bash $rs; rc=`$?; rm -f $rs; exit `$rc"
    if ($LASTEXITCODE -ne 0) { throw "activation on Apps-Core-VM failed" }
} finally { Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue }
