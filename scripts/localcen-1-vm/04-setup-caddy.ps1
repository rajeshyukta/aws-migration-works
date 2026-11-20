# Install templates/Caddyfile.localcen-1-vm on LocalCen-1-VM.
#   -Validate (default): only checks that the Caddyfile adapts on the VM.
#   -Apply             : after the console hosts point to 3.111.132.3 - install, reload, certificates, HTTPS checks.
#   console.localcen.com / admin.localcen.com are NextDP Core brand hosts (Apps-Core-VM), not LocalCen consoles.
param(
    [switch]$Apply,
    [string[]]$Hosts = @("localcen.cconsole.com", "admin.localcen.cconsole.com")
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\mail-vm\common.ps1")
Initialize-Toolchain
$root = Resolve-RepoRoot
$vm = Get-VmTarget -RepoRoot $root -Name "LocalCen-1-VM"
$all = @("localcen.cconsole.com", "admin.localcen.cconsole.com")
foreach ($h in $Hosts) { if ($all -notcontains $h) { throw "Unknown host: $h" } }
if (-not ($Hosts -contains "localcen.cconsole.com" -and $Hosts -contains "admin.localcen.cconsole.com")) { throw "The two cconsole.com hosts are required" }

$text = [IO.File]::ReadAllText((Join-Path $root "templates\Caddyfile.localcen-1-vm"))
$text = $text.Replace("`r`n", "`n")
$tmp = Join-Path $env:TEMP "Caddyfile.lc1-$PID"
[IO.File]::WriteAllText($tmp, $text, (New-Object Text.UTF8Encoding($false)))
$remoteStage = "/tmp/lc1-caddy-$PID"
$mode = if ($Apply) { "apply" } else { "validate" }
try {
    Invoke-VmCommand -Vm $vm -Command "mkdir -p $remoteStage && chmod 700 $remoteStage"
    Copy-ToVm -Vm $vm -LocalPath $tmp -RemotePath "$remoteStage/Caddyfile"
    Invoke-VmScript -Vm $vm -LocalScriptPath (Join-Path $PSScriptRoot "04-setup-caddy.sh") -EnvPrefix "MODE=$mode STAGE_DIR=$remoteStage HOSTS='$($Hosts -join ' ')'"
} finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }