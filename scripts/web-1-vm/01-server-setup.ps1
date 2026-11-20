# Provision Lightsail Web-1 (3.6.143.66): swap, hardening, PG 16, PHP 8.4-FPM, Caddy 2, UFW, fail2ban
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path (Split-Path -Parent $PSScriptRoot) "mail-vm\common.ps1")
Initialize-Toolchain

$repoRoot = Resolve-RepoRoot
$vm = Get-VmTarget -RepoRoot $repoRoot -Name "Web-1"
Write-Host "Target VM: $($vm.Name) ($($vm.Target))"

$caddyLocal = Join-Path $repoRoot "templates\Caddyfile.web-1"
if (-not (Test-Path -LiteralPath $caddyLocal)) {
    throw "Missing template: $caddyLocal"
}
$remoteCaddy = "/tmp/awsmig-Caddyfile-web1-$PID"
Copy-ToVm -Vm $vm -LocalPath $caddyLocal -RemotePath $remoteCaddy
try {
    Invoke-VmCommand -Vm $vm -Command "sed -i 's/\r$//' $remoteCaddy"
    Invoke-VmScript -Vm $vm -LocalScriptPath (Join-Path $PSScriptRoot "01-server-setup.sh") -EnvPrefix "CADDYFILE_SRC=$remoteCaddy"
} finally {
    Invoke-VmCommand -Vm $vm -Command "rm -f $remoteCaddy"
}
