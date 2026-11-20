# Install Caddyfile.apps-core-vm and apps-core-tls-ask.service (:8099) on Apps-Core-VM (43.204.42.99)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path (Split-Path -Parent $PSScriptRoot) "mail-vm\common.ps1")
Initialize-Toolchain

$repoRoot = Resolve-RepoRoot
$vm = Get-VmTarget -RepoRoot $repoRoot -Name "Apps-Core-VM"
$remoteStage = "/tmp/apps-core-caddy-$PID"

try {
    Invoke-VmCommand -Vm $vm -Command "mkdir -p $remoteStage"
    Copy-ToVm -Vm $vm -LocalPath (Join-Path $repoRoot "templates\caddy\apps-core-tls-ask.py") -RemotePath "$remoteStage/apps-core-tls-ask.py"
    Copy-ToVm -Vm $vm -LocalPath (Join-Path $repoRoot "templates\Caddyfile.apps-core-vm") -RemotePath "$remoteStage/Caddyfile.apps-core-vm"

    Invoke-VmScript -Vm $vm `
        -LocalScriptPath (Join-Path $PSScriptRoot "02-setup-caddy-and-ask.sh") `
        -EnvPrefix "STAGE_DIR=$remoteStage"
} finally {
    & ssh -i $vm.SshKey -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=10 $vm.Target "rm -rf $remoteStage" 2>$null
}
