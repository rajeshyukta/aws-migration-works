# Pull cconsole realm credentials if needed and wire dns-service on DNS-VM (52.66.165.1)
# to Next iDP (https://accounts.cconsole.com), turning on IDP_LOGIN=true and verifying boot.
param(
    [string]$CredsEnvPath = "",
    [switch]$SkipPull
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path (Split-Path -Parent $PSScriptRoot) "mail-vm\common.ps1")
Initialize-Toolchain

$repoRoot = Resolve-RepoRoot
if (-not $SkipPull) {
    & (Join-Path (Split-Path -Parent $PSScriptRoot) "apps-core-vm\pull-cconsole-idp-credentials.ps1")
}

if (-not $CredsEnvPath) {
    $CredsEnvPath = Join-Path $repoRoot "private-data\cconsole-realm.env"
}
if (-not (Test-Path -LiteralPath $CredsEnvPath)) {
    throw "Missing $CredsEnvPath"
}

$vm = Get-VmTarget -RepoRoot $repoRoot -Name "DNS VM"
Write-Host "Target VM: $($vm.Name) ($($vm.Target))"

$remoteTmp = "/tmp/awsmig-dnsidp-$PID.env"
Copy-ToVm -Vm $vm -LocalPath $CredsEnvPath -RemotePath $remoteTmp
Invoke-VmCommand -Vm $vm -Command "chmod 0600 $remoteTmp"

Invoke-VmScript -Vm $vm `
    -LocalScriptPath (Join-Path $PSScriptRoot "06-wire-nextidp-sso.sh") `
    -ScriptArgs $remoteTmp
