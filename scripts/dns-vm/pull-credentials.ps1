# Pull DNS-VM admin, tenant, and API key credentials directly from DNS-VM (52.66.165.1)
# into gitignored private-data/ folders without echoing secret values to stdout.
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path (Split-Path -Parent $PSScriptRoot) "mail-vm\common.ps1")
Initialize-Toolchain

$repoRoot = Resolve-RepoRoot
$vm = Get-VmTarget -RepoRoot $repoRoot -Name "DNS VM"

$awsPrivate = Join-Path $repoRoot "private-data"
$svcPrivate = "E:\workspace\projects\platform\dns-service\private-data"

$remoteTmpDir = "/tmp/awsmig-dnspull-$PID"
$localTmpDir  = Join-Path $env:TEMP "awsmig-dnspull-$PID"
New-Item -ItemType Directory -Path $localTmpDir -Force | Out-Null

$remoteScript = @'
#!/usr/bin/env bash
set -euo pipefail
mkdir -m 0700 -p "$OUT_DIR"

if sudo test -f /root/.dns-nextdp-secrets.env; then
  sudo cat /root/.dns-nextdp-secrets.env > "$OUT_DIR/dns-nextdp.env"
else
  echo "FATAL: /root/.dns-nextdp-secrets.env not found on DNS-VM" >&2
  exit 1
fi
chmod 0600 "$OUT_DIR/dns-nextdp.env"

PRESENCIVE_SEED_KEY=""
if sudo test -f /root/.dns-vm-seed.txt; then
  PRESENCIVE_SEED_KEY=$(sudo grep -oE 'dk_[a-f0-9]+' /root/.dns-vm-seed.txt | tail -n 1 || true)
fi

PDNS_API_KEY=""
PG_PASS_DNS_SVC=""
PG_PASS_PDNS=""
if sudo test -f /root/.dns-vm-secrets.env; then
  set -a
  source <(sudo cat /root/.dns-vm-secrets.env)
  set +a
fi

source "$OUT_DIR/dns-nextdp.env"

cat > "$OUT_DIR/dns-vm-accounts.txt" <<EOF
# DNS Service Accounts & API Keys — AWS DNS-VM (52.66.165.1 / 52.66.25.51)
# Pulled from DNS-VM — KEEP PRIVATE, NEVER COMMIT TO GIT

[Consoles & Endpoints]
Admin Console URL    : ${DNS_ADMIN_CONSOLE_URL}
Tenant Console URL   : ${DNS_TENANT_CONSOLE_URL}
VM Local API Base    : ${DNS_SERVICE_BASE_URL}
NS-1 Public IP       : 52.66.165.1 (ns1.nextdp.com)
NS-2 Public IP       : 52.66.25.51 (ns2.nextdp.com)

[Super Admin (admin.dns.cconsole.com)]
Email                : ${SUPER_ADMIN_EMAIL}
Password             : ${SUPER_ADMIN_PASSWORD}
Role                 : admin

[Tenant: nextdp]
Tenant ID            : ${TENANT_ID}
Slug / Account       : ${TENANT_SLUG} / ${TENANT_ACCOUNT}
Nameservers          : ${DNS_NAMESERVERS}
SOA Contact          : dns-admin@nextdp.com
Tenant Admin Email   : ${TENANT_ADMIN_EMAIL}
Tenant Admin Pass    : ${TENANT_ADMIN_PASSWORD}
API Key Name         : nextdp-web1-dns
API Key (X-API-Key)  : ${NEXTDP_API_KEY}
API Key Prefix       : ${NEXTDP_API_KEY_PREFIX}

[Tenant: presencive (Seeded Default)]
Slug / Account       : presencive / presencive
Nameservers          : ns1.presencive.com,ns2.presencive.com
API Key Name         : seed-dev-key
API Key (X-API-Key)  : ${PRESENCIVE_SEED_KEY}

[Server Internals (DNS-VM Localhost Only)]
PostgreSQL dns_db    : user=dns_u pass=${PG_PASS_DNS_SVC}
PostgreSQL pdns      : user=pdns pass=${PG_PASS_PDNS}
PowerDNS API Key     : ${PDNS_API_KEY}
EOF
chmod 0600 "$OUT_DIR/dns-vm-accounts.txt"
'@ -replace "`r`n", "`n"

$localSh = Join-Path $localTmpDir "pull.sh"
[IO.File]::WriteAllText($localSh, $remoteScript, [Text.UTF8Encoding]::new($false))

try {
    $remoteSh = "/tmp/awsmig-pull-$PID.sh"
    Copy-ToVm -Vm $vm -LocalPath $localSh -RemotePath $remoteSh
    Invoke-VmCommand -Vm $vm -Command "sed -i 's/\r$//' $remoteSh && chmod +x $remoteSh && { OUT_DIR=$remoteTmpDir bash $remoteSh; rc=`$?; rm -f $remoteSh; exit `$rc; }"

    & scp -i $vm.SshKey -o StrictHostKeyChecking=accept-new -o BatchMode=yes `
        "$($vm.Target):$remoteTmpDir/dns-nextdp.env" `
        "$($vm.Target):$remoteTmpDir/dns-vm-accounts.txt" `
        $localTmpDir
    if ($LASTEXITCODE -ne 0) { throw "scp download failed" }

    foreach ($pair in @(
        @{ Src = (Join-Path $localTmpDir "dns-nextdp.env");    Dst = (Join-Path $awsPrivate "dns-nextdp.env") },
        @{ Src = (Join-Path $localTmpDir "dns-vm-accounts.txt"); Dst = (Join-Path $awsPrivate "dns-vm-accounts.txt") },
        @{ Src = (Join-Path $localTmpDir "dns-nextdp.env");    Dst = (Join-Path $svcPrivate "aws-dns-nextdp.env") },
        @{ Src = (Join-Path $localTmpDir "dns-vm-accounts.txt"); Dst = (Join-Path $svcPrivate "aws-dns-vm-accounts.txt") }
    )) {
        if (Test-Path -LiteralPath (Split-Path -Parent $pair.Dst)) {
            $txt = ([IO.File]::ReadAllText($pair.Src)) -replace "`r`n", "`n"
            [IO.File]::WriteAllText($pair.Dst, $txt, [Text.UTF8Encoding]::new($false))
            Write-Host "Saved: $($pair.Dst) ($((Get-Item $pair.Dst).Length) bytes)" -ForegroundColor Green
        }
    }
} finally {
    Invoke-VmCommand -Vm $vm -Command "rm -rf -- $remoteTmpDir"
    if (Test-Path -LiteralPath $localTmpDir) { Remove-Item -LiteralPath $localTmpDir -Recurse -Force }
}
