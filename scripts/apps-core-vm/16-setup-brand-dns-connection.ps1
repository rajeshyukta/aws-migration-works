# Connect a NextDP Core brand to its dns-service tenant (DNS connection + webhook), by script.
#   .\scripts\apps-core-vm\16-setup-brand-dns-connection.ps1 -BrandId 34831870-c4c1-4d8b-bd45-b77672b541d3
# The tenant API key is read from private-data/<KeyFile> (line <KeyName>=...), sent to the VM as a
# 0600 temp file and deleted on exit. Nothing secret is printed.
param(
    [Parameter(Mandatory = $true)][string]$BrandId,
    [string]$KeyFile = "dns-nextdp.env",
    [string]$KeyName = "NEXTDP_API_KEY",
    [string]$DnsBaseUrl = "https://dns.cconsole.com",
    [string]$Nameservers = "ns1.nextdp.com ns2.nextdp.com",
    [switch]$NoWebhook
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if ($BrandId -notmatch '^[0-9a-f-]{36}$') { throw "Invalid -BrandId" }
if ($Nameservers -notmatch '^[a-z0-9. -]+$') { throw "Invalid -Nameservers" }
. (Join-Path $PSScriptRoot "..\mail-vm\common.ps1")
Initialize-Toolchain
$vm = Get-VmTarget -Name "Apps-Core-VM"
$src = Join-Path (Resolve-RepoRoot) "private-data\$KeyFile"
if (-not (Test-Path $src)) { throw "Missing $src" }
$line = Get-Content $src | Where-Object { $_ -match "^$KeyName=" } | Select-Object -First 1
if (-not $line) { throw "$KeyName not found in $KeyFile" }
$tmp = Join-Path (Resolve-RepoRoot) "private-data\.dnskey-$PID.tmp"
$remote = "/tmp/.dnskey-$PID"
try {
    [IO.File]::WriteAllText($tmp, ($line -replace "^$KeyName=", "").Trim().Trim('"'), (New-Object Text.UTF8Encoding($false)))
    Remove-Variable line
    Invoke-VmCommand -Vm $vm -Command "umask 077 && : > $remote"
    Copy-ToVm -Vm $vm -LocalPath $tmp -RemotePath $remote
} finally {
    if (Test-Path $tmp) { Remove-Item -LiteralPath $tmp -Force }
}
$wh = if ($NoWebhook) { "0" } else { "1" }
try {
    Invoke-VmScript -Vm $vm -LocalScriptPath (Join-Path $PSScriptRoot "16-setup-brand-dns-connection.sh") `
        -EnvPrefix "BRAND_ID=$BrandId API_KEY_FILE=$remote DNS_BASE_URL=$DnsBaseUrl NAMESERVERS='$Nameservers' WEBHOOK=$wh" | Out-Host
} finally {
    & ssh -i $vm.SshKey -o BatchMode=yes $vm.Target "rm -f $remote" 2>$null
}
