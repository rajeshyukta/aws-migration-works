# Programmatically create & wire the top-level NextDP Core realm (nextdp-core / id.nextdp.com)
# on Next iDP (Apps-Core-VM 43.204.42.99), wire /srv/apps/nextdp/shared/.env, verify health,
# and pull credentials into gitignored private-data/.
param(
    [string]$SetupKeyFile = "",
    [string]$OperatorEnvFile = "",
    [switch]$EnableCoreLogin,
    [switch]$SkipPull
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path (Split-Path -Parent $PSScriptRoot) "mail-vm\common.ps1")
Initialize-Toolchain

$repoRoot = Resolve-RepoRoot
$vm = Get-VmTarget -RepoRoot $repoRoot -Name "Apps-Core-VM"
Write-Host "Target VM: $($vm.Name) ($($vm.Target))"

if (-not $SetupKeyFile) {
    $candKey = Join-Path $repoRoot "private-data\nextdp-core-setup-key.env"
    if (Test-Path -LiteralPath $candKey) {
        $SetupKeyFile = $candKey
    }
}
if (-not $OperatorEnvFile) {
    $candOp = Join-Path $repoRoot "private-data\nextidp-operator.env"
    if (Test-Path -LiteralPath $candOp) {
        $OperatorEnvFile = $candOp
    }
}

$remoteKeyTmp = ""
$remoteOpTmp = ""
$envPrefix = "ENABLE_CORE_LOGIN=$(if ($EnableCoreLogin) { 'true' } else { 'false' })"
try {
    if ($SetupKeyFile) {
        if (-not (Test-Path -LiteralPath $SetupKeyFile)) {
            throw "Setup API key file not found: $SetupKeyFile"
        }
        $remoteKeyTmp = "/tmp/awsmig-ndp-key-$PID.env"
        Copy-ToVm -Vm $vm -LocalPath $SetupKeyFile -RemotePath $remoteKeyTmp
        Invoke-VmCommand -Vm $vm -Command "sed -i 's/\r$//' $remoteKeyTmp && chmod 0600 $remoteKeyTmp"
        $envPrefix = "$envPrefix SETUP_KEY_FILE=$remoteKeyTmp"
    }
    if ($OperatorEnvFile) {
        if (-not (Test-Path -LiteralPath $OperatorEnvFile)) {
            throw "Operator env file not found: $OperatorEnvFile"
        }
        $remoteOpTmp = "/tmp/awsmig-idp-op-$PID.env"
        Copy-ToVm -Vm $vm -LocalPath $OperatorEnvFile -RemotePath $remoteOpTmp
        Invoke-VmCommand -Vm $vm -Command "sed -i 's/\r$//' $remoteOpTmp && chmod 0600 $remoteOpTmp"
        $envPrefix = "$envPrefix OPERATOR_SECRETS_FILE=$remoteOpTmp"
    }

    Invoke-VmScript -Vm $vm `
        -LocalScriptPath (Join-Path $PSScriptRoot "12-setup-nextdp-core-realm.sh") `
        -EnvPrefix $envPrefix
} finally {
    if ($remoteKeyTmp) {
        Invoke-VmCommand -Vm $vm -Command "rm -f -- $remoteKeyTmp"
    }
    if ($remoteOpTmp) {
        Invoke-VmCommand -Vm $vm -Command "rm -f -- $remoteOpTmp"
    }
}

if (-not $SkipPull) {
    $pullScript = Join-Path $PSScriptRoot "pull-nextdp-idp-credentials.ps1"
    if (Test-Path -LiteralPath $pullScript) {
        & $pullScript
    }
}
