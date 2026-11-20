# Set the Lightsail firewall of the Mail VM to only the ports it needs (replaces all existing rules).
# Saves the current rules first (temp/lightsail-ports-<instance>-<ts>.json) so they can be restored with
#   aws lightsail put-instance-public-ports --region ap-south-1 --instance-name <name> --port-infos file://<saved.json>
# Then checks the ports from this PC and the Web-1 -> Mail VM private :25 alert path.
# Needs a working AWS CLI login (aws login). -WhatIf shows the plan without changing anything.
param(
    [string]$Region = "ap-south-1",
    [string]$PublicIp = "52.66.111.138",
    [switch]$WhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")
$repoRoot = Resolve-RepoRoot

# Required public ports (owner decision 2026-11-20). 53 and 8080 closed on purpose:
# ns1/ns2 are on the DNS VM, and Caddy reaches NextDP on localhost:8080.
$rules = @(
    @{ p = 22;  why = "SSH" }
    @{ p = 25;  why = "SMTP inbound (MX) + alerts from Web-1" }
    @{ p = 80;  why = "HTTP -> HTTPS, ACME HTTP-01" }
    @{ p = 443; why = "HTTPS webmail/admin/super-admin/autoconfig/dithim/maintenance" }
    @{ p = 465; why = "SMTPS submission" }
    @{ p = 587; why = "SMTP submission (STARTTLS)" }
    @{ p = 143; why = "IMAP (STARTTLS)" }
    @{ p = 993; why = "IMAPS" }
    @{ p = 110; why = "POP3 (STARTTLS)" }
    @{ p = 995; why = "POP3S" }
)

function Invoke-Aws([string[]]$AwsArgs) {
    $out = & aws @AwsArgs 2>&1
    if ($LASTEXITCODE -ne 0) { throw "aws $($AwsArgs[0..1] -join ' ') failed: $out" }
    return ($out -join "`n")
}

$null = Invoke-Aws @("sts", "get-caller-identity", "--output", "json")
$inst = (Invoke-Aws @("lightsail", "get-instances", "--region", $Region, "--output", "json") | ConvertFrom-Json).instances |
    Where-Object { $_.publicIpAddress -eq $PublicIp }
if (-not $inst) { throw "No Lightsail instance with public IP $PublicIp in $Region" }
$name = $inst.name
Write-Host "Instance: $name ($PublicIp, $Region)"

$current = (Invoke-Aws @("lightsail", "get-instance-port-states", "--region", $Region, "--instance-name", $name, "--output", "json") | ConvertFrom-Json).portStates
Write-Host "Current rules:"
$current | ForEach-Object { "  {0} {1}-{2} {3} {4}" -f $_.protocol, $_.fromPort, $_.toPort, ($_.cidrs -join ','), ($_.ipv6Cidrs -join ',') }

$ts = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
$backup = Join-Path $repoRoot "temp\lightsail-ports-$name-$ts.json"
$restore = @($current | ForEach-Object {
    $o = [ordered]@{ fromPort = $_.fromPort; toPort = $_.toPort; protocol = $_.protocol; cidrs = @($_.cidrs); ipv6Cidrs = @($_.ipv6Cidrs) }
    if ($_.PSObject.Properties.Name -contains "cidrListAliases" -and $_.cidrListAliases) { $o.cidrListAliases = @($_.cidrListAliases) }
    $o
})
New-Item -ItemType Directory -Force -Path (Split-Path $backup) | Out-Null
[IO.File]::WriteAllText($backup, (ConvertTo-Json -InputObject $restore -Depth 5), (New-Object Text.UTF8Encoding($false)))
Write-Host "Saved current rules to $backup"

$new = @($rules | ForEach-Object { [ordered]@{ fromPort = $_.p; toPort = $_.p; protocol = "tcp"; cidrs = @("0.0.0.0/0"); ipv6Cidrs = @("::/0") } })
# HTTP/3 (QUIC) for Caddy: UDP 443. Browsers fall back to TCP without it, but keep it fast.
$new += [ordered]@{ fromPort = 443; toPort = 443; protocol = "udp"; cidrs = @("0.0.0.0/0"); ipv6Cidrs = @("::/0") }
Write-Host "New rules (tcp, any source):"
$rules | ForEach-Object { "  {0,-4} {1}" -f $_.p, $_.why }
Write-Host "  udp 443 HTTP/3 (QUIC)"
if ($WhatIf) { Write-Host "WhatIf: no change made."; return }

$newFile = Join-Path $repoRoot "temp\lightsail-ports-$name-new.json"
[IO.File]::WriteAllText($newFile, (ConvertTo-Json -InputObject $new -Depth 5), (New-Object Text.UTF8Encoding($false)))
$null = Invoke-Aws @("lightsail", "put-instance-public-ports", "--region", $Region, "--instance-name", $name, "--port-infos", "file://$newFile")
Write-Host "Applied."

Start-Sleep 15
Write-Host "=== reachability from this PC ==="
foreach ($port in 22, 25, 80, 443, 465, 587, 143, 993, 110, 995, 53, 8080, 8090, 5432, 6379, 9055) {
    $c = New-Object Net.Sockets.TcpClient
    $open = $false
    try { $ar = $c.BeginConnect($PublicIp, $port, $null, $null); $open = $ar.AsyncWaitHandle.WaitOne(3000) -and $c.Connected } catch {} finally { $c.Close() }
    $want = ($rules.p -contains $port)
    "  {0,-5} {1,-7} {2}" -f $port, $(if ($open) { "open" } else { "closed" }), $(if ($open -eq $want) { "OK" } else { "UNEXPECTED" })
}
Write-Host "=== HTTPS ==="
foreach ($u in "https://mail.nextdp.com/api/health/ready", "https://admin.mail.nextdp.com/", "https://dithim.com/") {
    "  {0,-45} {1}" -f $u, (& curl.exe -s -o NUL -w "%{http_code}" --max-time 15 $u)
}
Write-Host "=== Web-1 -> Mail VM private :25 (backup alert path) ==="
$w = Get-VmTarget -Name "Web-1"
& ssh -i $w.SshKey -o BatchMode=yes $w.Target "timeout 8 bash -c 'exec 3<>/dev/tcp/172.26.3.188/25; IFS= read -r -t 6 l <&3; echo \`"  `$l\`"'" 2>&1
