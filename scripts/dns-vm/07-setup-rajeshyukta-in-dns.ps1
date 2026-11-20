# Claim rajeshyukta.in under the 'nextdp' tenant via dns-service API (matching mrajesh.com -> 3.6.143.66 + MX 0 mx.nextdp.com)
# and verify authoritative answers across BOTH NS-1 (52.66.165.1) and NS-2 (52.66.25.51).
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path (Split-Path -Parent $PSScriptRoot) "mail-vm\common.ps1")
Initialize-Toolchain

$vm = Get-VmTarget -RepoRoot (Resolve-RepoRoot) -Name "DNS VM"
Write-Host "Target VM: $($vm.Name) ($($vm.Target))"
Invoke-VmScript -Vm $vm -LocalScriptPath (Join-Path $PSScriptRoot "07-setup-rajeshyukta-in-dns.sh")
