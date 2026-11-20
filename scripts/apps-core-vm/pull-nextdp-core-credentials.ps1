# Pull core.nextdp.com master_admin credentials from Apps-Core-VM (43.204.42.99)
# into gitignored private-data/ folders without echoing secret values to stdout.
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path (Split-Path -Parent $PSScriptRoot) "mail-vm\common.ps1")
Initialize-Toolchain

$repoRoot = Resolve-RepoRoot
$vm = Get-VmTarget -RepoRoot $repoRoot -Name "Apps-Core-VM"

$awsPrivate  = Join-Path $repoRoot "private-data"
$corePrivate = "E:\workspace\projects\platform\nextdp-core\private-data"

$remoteTmpDir = "/tmp/awsmig-corepull-$PID"
$localTmpDir  = Join-Path $env:TEMP "awsmig-corepull-$PID"
New-Item -ItemType Directory -Path $localTmpDir -Force | Out-Null

$remoteScript = @'
#!/usr/bin/env bash
set -euo pipefail
mkdir -m 0700 -p "$OUT_DIR"

if sudo test -f /root/.nextdp-core-admin-secrets.env; then
  sudo cat /root/.nextdp-core-admin-secrets.env > "$OUT_DIR/nextdp-core-admin.env"
else
  echo "FATAL: /root/.nextdp-core-admin-secrets.env not found on Apps-Core-VM" >&2
  exit 1
fi
chmod 0600 "$OUT_DIR/nextdp-core-admin.env"

if sudo test -f /srv/apps/nextdp/shared/.env; then
  sudo cat /srv/apps/nextdp/shared/.env > "$OUT_DIR/vm-nextdp-core.env"
else
  echo "FATAL: /srv/apps/nextdp/shared/.env not found on Apps-Core-VM" >&2
  exit 1
fi
chmod 0600 "$OUT_DIR/vm-nextdp-core.env"

set -a
# shellcheck disable=SC1090
source "$OUT_DIR/nextdp-core-admin.env"
# shellcheck disable=SC1090
source "$OUT_DIR/vm-nextdp-core.env"
set +a

cat > "$OUT_DIR/nextdp-core-accounts.txt" <<EOF
# NextDP Core Platform Admin Account — AWS Apps-Core-VM (${NEXTDP_CORE_VM_IP})
# Pulled from Apps-Core-VM — KEEP PRIVATE, NEVER COMMIT TO GIT

[Core Control Plane]
Core URL             : ${NEXTDP_CORE_URL}
Login URL            : ${NEXTDP_CORE_URL}/login
Apps-Core-VM IP      : ${NEXTDP_CORE_VM_IP}

[Platform Master Admin]
User ID              : ${NEXTDP_CORE_ADMIN_USER_ID:-}
Public ID            : ${NEXTDP_CORE_ADMIN_PUBLIC_ID:-}
Brand ID             : ${NEXTDP_CORE_ADMIN_BRAND_ID:-}
Email                : ${NEXTDP_CORE_ADMIN_EMAIL}
Password             : ${NEXTDP_CORE_ADMIN_PASSWORD}
Shield Group         : ${NEXTDP_CORE_ADMIN_GROUP}

[Mail / ZeptoMail]
MAIL_API_PROVIDER    : ${MAIL_API_PROVIDER:-}
ZEPTOMAIL_BASE_URL   : ${ZEPTOMAIL_BASE_URL:-}
MAIL_FROM_ADDRESS    : ${MAIL_FROM_ADDRESS:-}
MAIL_FROM_NAME       : ${MAIL_FROM_NAME:-}
EOF
chmod 0600 "$OUT_DIR/nextdp-core-accounts.txt"
'@ -replace "`r`n", "`n"

$localSh = Join-Path $localTmpDir "pull.sh"
[IO.File]::WriteAllText($localSh, $remoteScript, [Text.UTF8Encoding]::new($false))

try {
    $remoteSh = "/tmp/awsmig-corepull-$PID.sh"
    Copy-ToVm -Vm $vm -LocalPath $localSh -RemotePath $remoteSh
    Invoke-VmCommand -Vm $vm -Command "sed -i 's/\r$//' $remoteSh && chmod +x $remoteSh && { OUT_DIR=$remoteTmpDir bash $remoteSh; rc=`$?; rm -f $remoteSh; exit `$rc; }"

    & scp -i $vm.SshKey -o StrictHostKeyChecking=accept-new -o BatchMode=yes `
        "$($vm.Target):$remoteTmpDir/nextdp-core-admin.env" `
        "$($vm.Target):$remoteTmpDir/nextdp-core-accounts.txt" `
        "$($vm.Target):$remoteTmpDir/vm-nextdp-core.env" `
        $localTmpDir
    if ($LASTEXITCODE -ne 0) { throw "scp download failed" }

    foreach ($pair in @(
        @{ Src = (Join-Path $localTmpDir "nextdp-core-admin.env");    Dst = (Join-Path $awsPrivate "nextdp-core-admin.env") },
        @{ Src = (Join-Path $localTmpDir "nextdp-core-accounts.txt"); Dst = (Join-Path $awsPrivate "nextdp-core-accounts.txt") },
        @{ Src = (Join-Path $localTmpDir "vm-nextdp-core.env");       Dst = (Join-Path $awsPrivate "aws-vm-nextdp-core.env") },
        @{ Src = (Join-Path $localTmpDir "nextdp-core-admin.env");    Dst = (Join-Path $corePrivate "aws-nextdp-core-admin.env") },
        @{ Src = (Join-Path $localTmpDir "nextdp-core-accounts.txt"); Dst = (Join-Path $corePrivate "aws-nextdp-core-accounts.txt") },
        @{ Src = (Join-Path $localTmpDir "vm-nextdp-core.env");       Dst = (Join-Path $corePrivate "aws-vm-nextdp-core.env") }
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
