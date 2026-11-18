# Common PowerShell helpers for AWS Mail VM scripts

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-RepoRoot {
    return (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
}

function Initialize-Toolchain {
    $candidates = @(
        "C:\Program Files\Go\bin",
        "E:\DEV\SOFTS\toolchains\go\bin",
        "E:\DEV\SOFTS\toolchains\node-v22.14.0-win-x64",
        "C:\Program Files\nodejs"
    )
    foreach ($dir in $candidates) {
        if ((Test-Path $dir) -and ($env:Path -notlike "*$dir*")) {
            $env:Path = "$dir;$env:Path"
        }
    }
    foreach ($tool in @("ssh", "scp", "tar")) {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
            throw "Required tool '$tool' not found on PATH."
        }
    }
}

function Get-VmTarget {
    param(
        [string]$RepoRoot = (Resolve-RepoRoot)
    )
    $vmsFile = Join-Path $RepoRoot "private-data\vms-details.txt"
    if (-not (Test-Path $vmsFile)) {
        throw "Missing VM inventory file: $vmsFile"
    }

    $ip = ""
    $user = "ubuntu"
    $sshKey = ""

    foreach ($rawLine in (Get-Content $vmsFile)) {
        $line = $rawLine.Trim()
        if ($line -match '^ip:\s*(.+)$') {
            $ip = $Matches[1].Trim().Trim('"')
        } elseif ($line -match '^user:\s*(.+)$') {
            $user = $Matches[1].Trim().Trim('"')
        } elseif ($line -match '^ssh_key:\s*(.+)$') {
            $sshKey = $Matches[1].Trim().Trim('"')
        }
    }

    if (-not $ip) { throw "Could not parse 'ip:' from $vmsFile" }
    if (-not $sshKey -or -not (Test-Path $sshKey)) {
        throw "SSH key not found: $sshKey"
    }

    return [PSCustomObject]@{
        IP     = $ip
        User   = $user
        Target = "$user@$ip"
        SshKey = $sshKey
    }
}

function Copy-ToVm {
    param(
        [Parameter(Mandatory = $true)][psobject]$Vm,
        [Parameter(Mandatory = $true)][string]$LocalPath,
        [Parameter(Mandatory = $true)][string]$RemotePath
    )
    & scp -i $Vm.SshKey -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=3 $LocalPath "$($Vm.Target):$RemotePath"
    if ($LASTEXITCODE -ne 0) {
        throw "scp failed: $LocalPath -> $($Vm.Target):$RemotePath"
    }
}

function Invoke-VmCommand {
    param(
        [Parameter(Mandatory = $true)][psobject]$Vm,
        [Parameter(Mandatory = $true)][string]$Command
    )
    & ssh -i $Vm.SshKey -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=3 $Vm.Target $Command
    if ($LASTEXITCODE -ne 0) {
        throw "ssh command failed (exit $LASTEXITCODE): $Command"
    }
}

function Invoke-VmScript {
    param(
        [Parameter(Mandatory = $true)][psobject]$Vm,
        [Parameter(Mandatory = $true)][string]$LocalScriptPath,
        [string]$EnvPrefix = "",
        [string]$ScriptArgs = "",
        [switch]$UseSudo
    )
    if (-not (Test-Path $LocalScriptPath)) {
        throw "Script not found: $LocalScriptPath"
    }
    $name = [System.IO.Path]::GetFileNameWithoutExtension($LocalScriptPath)
    $remotePath = "/tmp/awsmig-$name-$PID.sh"
    Copy-ToVm -Vm $Vm -LocalPath $LocalScriptPath -RemotePath $remotePath

    $runner = if ($UseSudo) { "sudo $EnvPrefix bash $remotePath $ScriptArgs" } else { "$EnvPrefix bash $remotePath $ScriptArgs" }
    $cmd = "sed -i 's/\r$//' $remotePath && chmod +x $remotePath && { $runner; rc=`$?; rm -f $remotePath; exit `$rc; }"
    Invoke-VmCommand -Vm $Vm -Command $cmd
}
