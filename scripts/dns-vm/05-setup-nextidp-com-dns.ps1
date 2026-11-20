# Claim nextidp.com under the 'nextdp' tenant via dns-service API and verify all records
# across BOTH NS-1 (52.66.165.1) and NS-2 (52.66.25.51).
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path (Split-Path -Parent $PSScriptRoot) "mail-vm\common.ps1")
Initialize-Toolchain

$vm = Get-VmTarget -RepoRoot (Resolve-RepoRoot) -Name "DNS VM"
Write-Host "Target VM: $($vm.Name) ($($vm.Target))"
Invoke-VmScript -Vm $vm -LocalScriptPath (Join-Path $PSScriptRoot "05-setup-nextidp-com-dns.sh")
