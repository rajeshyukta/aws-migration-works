# Set up / update the SMS service (r1sms) on Apps-Core-VM from the sms-service repo + the R2 dump.
#   .\scripts\apps-core-vm\20-setup-sms-service.ps1                 # check (read-only)
#   .\scripts\apps-core-vm\20-setup-sms-service.ps1 -Apply          # build, upload, set up, deploy
#   ... -Apply -SkipBuild    # use the existing backend\bin\r1sms-backend + console\dist
# Code: E:\workspace\projects\platform\sms-service (the checked-out branch; owner 2026-11-20:
# 44_reverse-otp-token-only). DB: D:\nmc-backup\r2\r1sms-fb986270 (fetch-r2-dump.ps1), restored only
# into an empty r1sms database. Owner 2026-11-20: NEW APP_KEY (data sealed with the old Azure key is lost).
param([switch]$Apply, [switch]$SkipBuild, [string]$DumpDir = "D:\nmc-backup\r2\r1sms-fb986270")
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\mail-vm\common.ps1")
Initialize-Toolchain
$vm = Get-VmTarget -Name "Apps-Core-VM"
$o = @("-i", $vm.SshKey, "-o", "BatchMode=yes", "-o", "ConnectTimeout=20")
$repo = "E:\workspace\projects\platform\sms-service"
$rs = "/tmp/20-sms-$PID.sh"
& scp -q @o (Join-Path $PSScriptRoot "20-setup-sms-service.sh") "$($vm.Target):$rs" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "script upload failed" }
if (-not $Apply) {
    & ssh -n @o $vm.Target "sed -i 's/\r$//' $rs && MODE=check bash $rs; echo rc=`$?; rm -f $rs"
    return
}
$dump = Join-Path $DumpDir "r1sms.dump"
if (-not (Test-Path $dump)) { throw "missing $dump (run scripts\r2\fetch-r2-dump.ps1 -Database r1sms -SnapshotId fb986270)" }
$sha = (& git -C $repo rev-parse --short HEAD).Trim()
$branch = (& git -C $repo branch --show-current).Trim()
if (-not $SkipBuild) {
    Push-Location (Join-Path $repo "backend")
    try {
        & go vet ./...; if ($LASTEXITCODE -ne 0) { throw "go vet failed" }
        $env:GOOS = "linux"; $env:GOARCH = "amd64"; $env:CGO_ENABLED = "0"
        & go build -ldflags "-s -w" -o bin/r1sms-backend ./cmd; $b = $LASTEXITCODE
        Remove-Item Env:GOOS, Env:GOARCH, Env:CGO_ENABLED -ErrorAction SilentlyContinue
        if ($b -ne 0) { throw "go build failed" }
    } finally { Pop-Location }
    Push-Location (Join-Path $repo "console")
    try { & pnpm build; if ($LASTEXITCODE -ne 0) { throw "console build failed" } } finally { Pop-Location }
}
$bin = Join-Path $repo "backend\bin\r1sms-backend"
$dist = Join-Path $repo "console\dist"
if (-not (Test-Path $bin) -or -not (Test-Path (Join-Path $dist "index.html"))) { throw "build output missing" }
$release = "r1sms-backend-$sha-$(Get-Date -Format yyyyMMddHHmmss)"
$local = Join-Path $env:TEMP "r1sms-stage-$PID"
New-Item -ItemType Directory -Force $local | Out-Null
try {
    Copy-Item $bin (Join-Path $local "r1sms-backend")
    Copy-Item $dump (Join-Path $local "r1sms.dump")
    & tar -czf (Join-Path $local "console.tgz") -C $dist .
    if ($LASTEXITCODE -ne 0) { throw "tar failed" }
    [IO.File]::WriteAllText((Join-Path $local "RELEASE"), $release, (New-Object Text.UTF8Encoding($false)))
    Write-Host "Uploading $release (branch $branch @ $sha)..."
    $stage = "/tmp/r1sms-stage-$PID"
    & ssh -n @o $vm.Target "umask 077 && mkdir -p $stage"
    foreach ($f in "r1sms-backend", "r1sms.dump", "console.tgz", "RELEASE") {
        & scp -q @o (Join-Path $local $f) "$($vm.Target):$stage/$f" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "upload $f failed" }
    }
    & ssh -n @o $vm.Target "sed -i 's/\r$//' $rs && MODE=apply STAGE=$stage bash $rs; echo rc=`$?; rm -f $rs"
} finally {
    Remove-Item -LiteralPath $local -Recurse -Force -ErrorAction SilentlyContinue
}
