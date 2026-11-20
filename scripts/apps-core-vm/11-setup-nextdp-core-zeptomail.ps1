# Configure Zoho CPaaS / ZeptoMail (https://cpaas.zoho.in) for NextDP Core (core.nextdp.com)
# on Apps-Core-VM (43.204.42.99) from private-data\zoho-cpass-mail-api-key.txt,
# restart nextdp units, verify live EmailService delivery, and refresh private-data/.
param(
    [string]$KeyFilePath = "",
    [string]$FromAddress = "noreply@nextdp.com",
    [string]$FromName = "NextDP",
    [string]$BaseUrl = "https://cpaas.zoho.in",
    [switch]$SkipPull
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path (Split-Path -Parent $PSScriptRoot) "mail-vm\common.ps1")
Initialize-Toolchain

$repoRoot = Resolve-RepoRoot
if (-not $KeyFilePath) {
    $KeyFilePath = Join-Path $repoRoot "private-data\zoho-cpass-mail-api-key.txt"
}
if (-not (Test-Path -LiteralPath $KeyFilePath)) {
    throw "ZeptoMail key file not found: $KeyFilePath"
}

$vm = Get-VmTarget -RepoRoot $repoRoot -Name "Apps-Core-VM"
Write-Host "Target VM: $($vm.Name) ($($vm.Target))"

$remoteKeyTmp = "/tmp/awsmig-ndpzm-$PID.txt"
Copy-ToVm -Vm $vm -LocalPath $KeyFilePath -RemotePath $remoteKeyTmp
Invoke-VmCommand -Vm $vm -Command "chmod 0600 $remoteKeyTmp"

$envPrefix = "MAIL_API_PROVIDER=zeptomail ZEPTOMAIL_BASE_URL='$BaseUrl' MAIL_FROM_ADDRESS='$FromAddress' MAIL_FROM_NAME='$FromName'"
Invoke-VmScript -Vm $vm `
    -LocalScriptPath (Join-Path $PSScriptRoot "11-setup-nextdp-core-zeptomail.sh") `
    -EnvPrefix $envPrefix `
    -ScriptArgs $remoteKeyTmp

if (-not $SkipPull) {
    & (Join-Path $PSScriptRoot "pull-nextdp-core-credentials.ps1")
}
