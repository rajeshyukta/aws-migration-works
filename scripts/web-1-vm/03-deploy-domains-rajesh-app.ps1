# Package and deploy domains-rajesh-app + restore PG dump + configure self-signed (domains.rajesh.in)
# and Caddy Let's Encrypt auto-SSL (domains.rajesh1.com) onto Lightsail Web-1 (3.6.143.66).
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path (Split-Path -Parent $PSScriptRoot) "mail-vm\common.ps1")
Initialize-Toolchain

$repoRoot = Resolve-RepoRoot
$appRoot = "E:\workspace\projects\products\domains-rajesh-app"
$dumpLocal = Join-Path $appRoot "backups\domains_rajesh_20260625-070429.dump"
$caddyLocal = Join-Path $repoRoot "templates\caddy\domains.rajesh.app.caddy"
$credsLocal = Join-Path $repoRoot "private-data\web1-domains-rajesh.env"

foreach ($p in @($appRoot, $dumpLocal, $caddyLocal)) {
    if (-not (Test-Path -LiteralPath $p)) { throw "Missing required input: $p" }
}

$vm = Get-VmTarget -RepoRoot $repoRoot -Name "Web-1"
Write-Host "Target VM: $($vm.Name) ($($vm.Target))"

$ts = [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssZ")
$stage = "/tmp/web1-domains-$ts-$PID"
$remoteOut = "$stage/domains-creds.env"
$localArchive = Join-Path $env:TEMP "domains-app-$ts-$PID.tar.gz"
$localCredsTmp = Join-Path $env:TEMP "domains-creds-$ts-$PID.env"

try {
    Write-Host "=== [1/4] Package domains-rajesh-app (excluding secrets, dumps, git, vendor, writable caches) ===" -ForegroundColor Cyan
    & tar.exe -czf $localArchive -C $appRoot `
        --exclude=.git `
        --exclude=infra `
        --exclude=private-data `
        --exclude=backups `
        --exclude=reference `
        --exclude=vendor `
        --exclude=.env `
        --exclude=temp `
        --exclude=extra-works `
        "--exclude=writable/logs/*.log" `
        "--exclude=writable/cache/*" `
        "--exclude=writable/session/*" `
        "--exclude=writable/debugbar/*" `
        .
    if ($LASTEXITCODE -ne 0) { throw "tar packaging failed." }

    Write-Host "=== [2/4] Upload app archive, PostgreSQL dump & Caddy site ===" -ForegroundColor Cyan
    Invoke-VmCommand -Vm $vm -Command "mkdir -m 0700 -p $stage"
    Copy-ToVm -Vm $vm -LocalPath $localArchive -RemotePath "$stage/domains-app.tar.gz"
    Copy-ToVm -Vm $vm -LocalPath $dumpLocal    -RemotePath "$stage/domains_rajesh.dump"
    Copy-ToVm -Vm $vm -LocalPath $caddyLocal   -RemotePath "$stage/domains.rajesh.app.caddy"
    Invoke-VmCommand -Vm $vm -Command "sed -i 's/\r$//' $stage/domains.rajesh.app.caddy"

    Write-Host "=== [3/4] Install, restore dump, configure certs & verify on Web-1 ===" -ForegroundColor Cyan
    Invoke-VmScript -Vm $vm -LocalScriptPath (Join-Path $PSScriptRoot "03-deploy-domains-rajesh-app.sh") `
        -EnvPrefix "STAGE_DIR=$stage OUTPUT_ENV=$remoteOut"

    Write-Host "=== [4/4] Save credentials securely to private-data ===" -ForegroundColor Cyan
    & scp -i $vm.SshKey -o StrictHostKeyChecking=accept-new -o BatchMode=yes "$($vm.Target):$remoteOut" $localCredsTmp
    if ($LASTEXITCODE -ne 0) { throw "scp download of credentials failed" }
    $text = ([IO.File]::ReadAllText($localCredsTmp)) -replace "`r`n", "`n"
    [IO.File]::WriteAllText($credsLocal, $text, [Text.UTF8Encoding]::new($false))
    Write-Host "Credentials stored (contents hidden) in: $credsLocal" -ForegroundColor Green
} finally {
    Invoke-VmCommand -Vm $vm -Command "rm -rf -- $stage"
    foreach ($f in @($localArchive, $localCredsTmp)) {
        if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force }
    }
}
