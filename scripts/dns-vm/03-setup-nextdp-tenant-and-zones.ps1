# Programmatically configure tenant 'nextdp', super-admin rajesh@nextdp.com, tenant admin nextdp@nextdp.com,
# mint a tenant API key, create all 20 Web-1 apex zones + records (@ A, www A, @ MX 0 mx.nextdp.com, dev* A),
# and persist credentials ONLY inside gitignored private-data/ (never printed to stdout).
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path (Split-Path -Parent $PSScriptRoot) "mail-vm\common.ps1")
Initialize-Toolchain

$repoRoot = Resolve-RepoRoot
$vm = Get-VmTarget -RepoRoot $repoRoot -Name "DNS VM"
$localCreds = Join-Path $repoRoot "private-data\dns-nextdp.env"
$dnsSvcCreds = "E:\workspace\projects\platform\dns-service\private-data\aws-dns-nextdp.env"

function New-SecretToken([int]$Bytes = 18) {
    $buf = New-Object byte[] $Bytes
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($buf)
    } finally {
        $rng.Dispose()
    }
    # Base64url-safe without shell-special chars; length 24 chars, >= min=8
    return ([Convert]::ToBase64String($buf) -replace '\+', 'A' -replace '/', 'B' -replace '=', '')
}

# Read existing local passwords if previously created so re-runs stay idempotent
$existing = @{}
if (Test-Path -LiteralPath $localCreds) {
    foreach ($line in Get-Content -LiteralPath $localCreds) {
        if ($line -match '^\s*([A-Z0-9_]+)=(.+)$') {
            $existing[$Matches[1]] = $Matches[2].Trim()
        }
    }
}
$superPw  = if ($existing.ContainsKey("SUPER_ADMIN_PASSWORD")  -and $existing["SUPER_ADMIN_PASSWORD"])  { $existing["SUPER_ADMIN_PASSWORD"] }  else { New-SecretToken 18 }
$tenantPw = if ($existing.ContainsKey("TENANT_ADMIN_PASSWORD") -and $existing["TENANT_ADMIN_PASSWORD"]) { $existing["TENANT_ADMIN_PASSWORD"] } else { New-SecretToken 18 }

$tmpInLocal = Join-Path $env:TEMP "awsmig-dns-in-$PID.env"
$tmpOutLocal = Join-Path $env:TEMP "awsmig-dns-out-$PID.env"
$remoteIn = "/tmp/awsmig-dns-nextdp-in-$PID.env"
$remoteOut = "/tmp/awsmig-dns-nextdp-out-$PID.env"

try {
    $inBody = @(
        "SUPER_ADMIN_PASSWORD=$superPw"
        "TENANT_ADMIN_PASSWORD=$tenantPw"
        ""
    ) -join "`n"
    [IO.File]::WriteAllText($tmpInLocal, $inBody, [Text.UTF8Encoding]::new($false))

    Copy-ToVm -Vm $vm -LocalPath $tmpInLocal -RemotePath $remoteIn
    Invoke-VmCommand -Vm $vm -Command "chmod 0600 $remoteIn"
    Invoke-VmScript -Vm $vm -LocalScriptPath (Join-Path $PSScriptRoot "03-setup-nextdp-tenant-and-zones.sh") `
        -EnvPrefix "INPUT_ENV=$remoteIn OUTPUT_ENV=$remoteOut"

    # Pull credential file back securely without ever displaying secrets on stdout
    & scp -i $vm.SshKey -o StrictHostKeyChecking=accept-new -o BatchMode=yes "$($vm.Target):$remoteOut" $tmpOutLocal
    if ($LASTEXITCODE -ne 0) { throw "scp download of output env failed" }

    $text = ([IO.File]::ReadAllText($tmpOutLocal)) -replace "`r`n", "`n"
    [IO.File]::WriteAllText($localCreds, $text, [Text.UTF8Encoding]::new($false))
    if (Test-Path -LiteralPath "E:\workspace\projects\platform\dns-service\private-data") {
        [IO.File]::WriteAllText($dnsSvcCreds, $text, [Text.UTF8Encoding]::new($false))
    }
    Write-Host "Credentials stored securely (contents hidden) in:" -ForegroundColor Green
    Write-Host "  - $localCreds"
    if (Test-Path -LiteralPath $dnsSvcCreds) { Write-Host "  - $dnsSvcCreds" }
} finally {
    Invoke-VmCommand -Vm $vm -Command "rm -f $remoteIn $remoteOut"
    foreach ($f in @($tmpInLocal, $tmpOutLocal)) {
        if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force }
    }
}
