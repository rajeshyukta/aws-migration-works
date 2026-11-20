# Configure ZeptoMail (Zoho CPaaS India) for Next iDP on Apps-Core-VM (43.204.42.99)
# using private-data\zoho-cpass-mail-api-key.txt without echoing raw secret values,
# restart nextidp + nextidp-worker, and refresh pulled credentials in private-data\.
param(
    [string]$KeyFilePath = "",
    [string]$FromAddress = "noreply@nextidp.com",
    [string]$FromName = "Next iDP",
    [string]$ApiBaseUrl = "https://cpaas.zoho.in",
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

$remoteKeyTmp = "/tmp/awsmig-zmkey-$PID.txt"
Copy-ToVm -Vm $vm -LocalPath $KeyFilePath -RemotePath $remoteKeyTmp
Invoke-VmCommand -Vm $vm -Command "chmod 0600 $remoteKeyTmp"

$envPrefix = "MAIL_DRIVER=zeptomail MAIL_FROM_ADDRESS='$FromAddress' MAIL_FROM_NAME='$FromName' MAIL_API_BASE_URL='$ApiBaseUrl' N1_DEV_OUTBOX=false"
Invoke-VmScript -Vm $vm `
    -LocalScriptPath (Join-Path $PSScriptRoot "07-setup-nextidp-zeptomail.sh") `
    -EnvPrefix $envPrefix `
    -ScriptArgs $remoteKeyTmp

if (-not $SkipPull) {
    & (Join-Path $PSScriptRoot "pull-nextidp-credentials.ps1")
}
