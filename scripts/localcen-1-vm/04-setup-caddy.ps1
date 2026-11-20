# Install templates/Caddyfile.localcen-1-vm on LocalCen-1-VM.
#   -Validate (default): only checks that the Caddyfile adapts on the VM.
#   -Apply             : after the 4 console hosts point to 3.111.132.3 - install, reload, certificates, HTTPS checks.
param([switch]$Apply)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\mail-vm\common.ps1")
Initialize-Toolchain
$root = Resolve-RepoRoot
$vm = Get-VmTarget -RepoRoot $root -Name "LocalCen-1-VM"
$remoteStage = "/tmp/lc1-caddy-$PID"
$mode = if ($Apply) { "apply" } else { "validate" }
Invoke-VmCommand -Vm $vm -Command "mkdir -p $remoteStage && chmod 700 $remoteStage"
Copy-ToVm -Vm $vm -LocalPath (Join-Path $root "templates\Caddyfile.localcen-1-vm") -RemotePath "$remoteStage/Caddyfile"
Invoke-VmScript -Vm $vm -LocalScriptPath (Join-Path $PSScriptRoot "04-setup-caddy.sh") -EnvPrefix "MODE=$mode STAGE_DIR=$remoteStage"
