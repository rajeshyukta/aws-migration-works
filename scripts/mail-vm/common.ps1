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
        [string]$RepoRoot = (Resolve-RepoRoot),
        [string]$Name = "Mail VM"
    )
    $vmsFile = Join-Path $RepoRoot "private-data\vms-details.txt"
    if (-not (Test-Path $vmsFile)) {
        throw "Missing VM inventory file: $vmsFile"
    }

    $entries = @{}
    $currentName = ""
    foreach ($rawLine in (Get-Content $vmsFile)) {
        $line = $rawLine.Trim()
        if (-not $line -or $line.StartsWith('#')) { continue }
        if ($line -match '^([a-zA-Z0-9_]+):\s*(.+)$') {
            if (-not $currentName) { $currentName = "default" }
            $k = $Matches[1].ToLowerInvariant()
            $v = $Matches[2].Trim().Trim('"')
            if ($k -eq 'ip') { $entries[$currentName].IP = $v }
            elseif ($k -eq 'user') { $entries[$currentName].User = $v }
            elseif ($k -eq 'ssh_key') { $entries[$currentName].SshKey = $v }
        } else {
            $currentName = $line
            if (-not $entries.ContainsKey($currentName)) {
                $entries[$currentName] = @{ IP = ""; User = "ubuntu"; SshKey = "" }
            }
        }
    }

    if (-not $entries.ContainsKey($Name)) {
        $avail = ($entries.Keys -join ', ')
        throw "VM '$Name' not found in $vmsFile (available: $avail)"
    }
    $sel = $entries[$Name]
    if (-not $sel.IP) { throw "Could not parse 'ip:' for '$Name' in $vmsFile" }
    if (-not $sel.SshKey -or -not (Test-Path $sel.SshKey)) {
        throw "SSH key not found: $($sel.SshKey)"
    }

    return [PSCustomObject]@{
        Name   = $Name
        IP     = $sel.IP
        User   = $sel.User
        Target = "$($sel.User)@$($sel.IP)"
        SshKey = $sel.SshKey
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
    # -n: never read stdin (an idle stdin made ssh hang now and then)
    & ssh -n -i $Vm.SshKey -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=3 $Vm.Target $Command
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
