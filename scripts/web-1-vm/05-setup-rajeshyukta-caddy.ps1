# Install rajeshyukta.in.caddy onto Web-1 (3.6.143.66), acquire Let's Encrypt SSL certs
# for rajeshyukta.in and www.rajeshyukta.in, and verify strict public HTTPS redirect to mrajesh.com.
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path (Split-Path -Parent $PSScriptRoot) "mail-vm\common.ps1")
Initialize-Toolchain

$repoRoot = Resolve-RepoRoot
$vm = Get-VmTarget -RepoRoot $repoRoot -Name "Web-1"
$caddyTpl = Join-Path $repoRoot "templates\caddy\rajeshyukta.in.caddy"
if (-not (Test-Path -LiteralPath $caddyTpl)) {
    throw "Missing template: $caddyTpl"
}

$remoteStage = "/tmp/awsmig-rajeshyukta-caddy-$PID.caddy"
try {
    Copy-ToVm -Vm $vm -LocalPath $caddyTpl -RemotePath $remoteStage
    Invoke-VmScript -Vm $vm `
        -LocalScriptPath (Join-Path $PSScriptRoot "05-setup-rajeshyukta-caddy.sh") `
        -EnvPrefix "CADDY_STAGE=$remoteStage"
} finally {
    Invoke-VmCommand -Vm $vm -Command "rm -f -- $remoteStage"
}

Write-Host "=== [Windows Public HTTPS Verification] ===" -ForegroundColor Cyan
foreach ($check in @(
    @{ Url = 'https://rajeshyukta.in/';             Expect = '200' },
    @{ Url = 'https://rajeshyukta.in/work';         Expect = '200' },
    @{ Url = 'https://rajeshyukta.in/te/work';      Expect = '200' },
    @{ Url = 'https://rajeshyukta.in/contact';      Expect = '200' },
    @{ Url = 'https://www.rajeshyukta.in/';         Expect = '301' },
    @{ Url = 'https://www.rajeshyukta.in/work';     Expect = '301' }
)) {
    $res = & curl.exe --ssl-no-revoke -s -o NUL -w '%{http_code} %{redirect_url}' --max-time 15 $check.Url
    if ($LASTEXITCODE -ne 0) {
        throw "curl failed for $($check.Url) (exit=$LASTEXITCODE)"
    }
    $code = ($res -split ' ', 2)[0]
    if ($code -ne $check.Expect) {
        throw "Unexpected status for $($check.Url): got '$res', expected HTTP $($check.Expect)"
    }
    Write-Host ("  {0,-34} HTTP {1}" -f $check.Url, $res.Trim()) -ForegroundColor Green
}
