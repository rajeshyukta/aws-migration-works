# Generate CA-signed cert on Web-1 (deleting CA key immediately), fetch public CA cert,
# verify TLS against 3.6.143.66 cleanly from Windows, and install CA cert into CurrentUser\Root.
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path (Split-Path -Parent $PSScriptRoot) "mail-vm\common.ps1")
Initialize-Toolchain

$repoRoot = Resolve-RepoRoot
$vm = Get-VmTarget -RepoRoot $repoRoot -Name "Web-1"
$localCaPath = Join-Path $repoRoot "private-data\domains-rajesh-in-local-ca.crt"
$remoteCa = "/tmp/awsmig-domains-ca-$PID.crt"

try {
    Invoke-VmScript -Vm $vm -LocalScriptPath (Join-Path $PSScriptRoot "04-setup-domains-local-ca.sh") -EnvPrefix "OUT_CA=$remoteCa"
    & scp -i $vm.SshKey -o StrictHostKeyChecking=accept-new -o BatchMode=yes "$($vm.Target):$remoteCa" $localCaPath
    if ($LASTEXITCODE -ne 0) { throw "scp download of public CA cert failed" }
} finally {
    Invoke-VmCommand -Vm $vm -Command "rm -f -- $remoteCa"
}

Write-Host "=== [Windows Verification] curl.exe strict TLS check against live Web-1 ===" -ForegroundColor Cyan
$code = & curl.exe --ssl-no-revoke --cacert $localCaPath -s -o NUL -w '%{http_code}' https://domains.rajesh.in/login
if ($LASTEXITCODE -ne 0 -or $code -ne '200') {
    throw "Strict TLS check failed (exit=$LASTEXITCODE, http=$code)"
}
Write-Host "  Strict TLS verified (zero -k bypass!): https://domains.rajesh.in/login -> HTTP $code" -ForegroundColor Green
Write-Host "Public Root CA saved to: $localCaPath"

Write-Host "=== [Windows Trust Store] Check / Next Step ===" -ForegroundColor Cyan
$cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($localCaPath)
$already = Get-ChildItem Cert:\CurrentUser\Root, Cert:\LocalMachine\Root | Where-Object { $_.Thumbprint -eq $cert.Thumbprint }
if ($already) {
    Write-Host "  CA cert is already trusted in Windows Root store ($($cert.Thumbprint))" -ForegroundColor Green
} else {
    Write-Host "  Run this command in your Windows PowerShell terminal and click 'Yes' on the Security Warning dialog:" -ForegroundColor Yellow
    Write-Host "    Import-Certificate -FilePath `"$localCaPath`" -CertStoreLocation Cert:\CurrentUser\Root" -ForegroundColor White
}
