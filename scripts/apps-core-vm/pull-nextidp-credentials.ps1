# Pull Next iDP master admin credentials and VM env mirror from Apps-Core-VM (43.204.42.99)
# into gitignored private-data/ folders without printing secret values to stdout.
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path (Split-Path -Parent $PSScriptRoot) "mail-vm\common.ps1")
Initialize-Toolchain

$repoRoot = Resolve-RepoRoot
$vm = Get-VmTarget -RepoRoot $repoRoot -Name "Apps-Core-VM"

$awsPrivate = Join-Path $repoRoot "private-data"
$idpPrivate = "E:\workspace\projects\platform\nextidp\private-data"

$remoteTmpDir = "/tmp/awsmig-idppull-$PID"
$localTmpDir  = Join-Path $env:TEMP "awsmig-idppull-$PID"
New-Item -ItemType Directory -Path $localTmpDir -Force | Out-Null

$remoteScript = @'
#!/usr/bin/env bash
set -euo pipefail
mkdir -m 0700 -p "$OUT_DIR"

if sudo test -f /root/.nextidp-admin-secrets.env; then
  sudo cat /root/.nextidp-admin-secrets.env > "$OUT_DIR/nextidp-admin.env"
else
  echo "FATAL: /root/.nextidp-admin-secrets.env not found on Apps-Core-VM" >&2
  exit 1
fi
chmod 0600 "$OUT_DIR/nextidp-admin.env"

if sudo test -f /etc/nextidp/env; then
  sudo cat /etc/nextidp/env > "$OUT_DIR/vm-nextidp.env"
else
  echo "FATAL: /etc/nextidp/env not found on Apps-Core-VM" >&2
  exit 1
fi
chmod 0600 "$OUT_DIR/vm-nextidp.env"

set -a
# shellcheck disable=SC1090
source "$OUT_DIR/nextidp-admin.env"
# shellcheck disable=SC1090
source "$OUT_DIR/vm-nextidp.env"
set +a

cat > "$OUT_DIR/nextidp-accounts.txt" <<EOF
# Next iDP Master Admin & VM Environment — AWS Apps-Core-VM (${NEXTIDP_APPS_CORE_IP})
# Pulled from Apps-Core-VM — KEEP PRIVATE, NEVER COMMIT TO GIT

[Master Console & Endpoints]
Master Console URL   : ${NEXTIDP_MASTER_URL}
Redirect Aliases     : https://www.nextidp.com, https://admin.nextidp.com
Apps-Core-VM IP      : ${NEXTIDP_APPS_CORE_IP}
Local Upstream       : http://127.0.0.1:${APP_PORT}

[Platform Master Admin]
User ID              : ${NEXTIDP_ADMIN_USER_ID:-}
Email                : ${NEXTIDP_ADMIN_EMAIL}
Name                 : ${NEXTIDP_ADMIN_NAME}
Password             : ${NEXTIDP_ADMIN_PASSWORD}
Role                 : ${NEXTIDP_ADMIN_ROLE} (is_super_admin=true, realm_id='')
Must Change Password : ${NEXTIDP_MUST_CHANGE_PASSWORD:-true} (prompted on first browser sign-in)

[Database & Redis (Apps-Core-VM Localhost Only)]
PostgreSQL           : host=${DB_HOST} port=${DB_PORT} db=${DB_NAME} user=${DB_USER} pass=${DB_PASSWORD}
Redis                : addr=${REDIS_ADDR} db=${REDIS_DB} pass=${REDIS_PASSWORD}

[Mail & Runtime Flags]
APP_ENV              : ${APP_ENV}
MAIL_DRIVER          : ${MAIL_DRIVER}
MAIL_FROM_ADDRESS    : ${MAIL_FROM_ADDRESS}
MAIL_FROM_NAME       : ${MAIL_FROM_NAME}
MAIL_API_BASE_URL    : ${MAIL_API_BASE_URL:-}
MAIL_RETENTION_DAYS  : ${MAIL_RETENTION_DAYS}
N1_DEV_OUTBOX        : ${N1_DEV_OUTBOX}
PASSWORD_ALGO        : ${PASSWORD_ALGO}

[Object Storage (AWS S3)]
AVATAR_STORE         : ${AVATAR_STORE:-off}
S3_BUCKET            : ${S3_BUCKET:-}
S3_REGION            : ${S3_REGION:-}
S3_SSE               : ${S3_SSE:-}
N1_ASSETS_BASE_URL   : ${N1_ASSETS_BASE_URL:-}
EOF
chmod 0600 "$OUT_DIR/nextidp-accounts.txt"
'@ -replace "`r`n", "`n"

$localSh = Join-Path $localTmpDir "pull.sh"
[IO.File]::WriteAllText($localSh, $remoteScript, [Text.UTF8Encoding]::new($false))

try {
    $remoteSh = "/tmp/awsmig-idppull-$PID.sh"
    Copy-ToVm -Vm $vm -LocalPath $localSh -RemotePath $remoteSh
    Invoke-VmCommand -Vm $vm -Command "sed -i 's/\r$//' $remoteSh && chmod +x $remoteSh && { OUT_DIR=$remoteTmpDir bash $remoteSh; rc=`$?; rm -f $remoteSh; exit `$rc; }"

    & scp -i $vm.SshKey -o StrictHostKeyChecking=accept-new -o BatchMode=yes `
        "$($vm.Target):$remoteTmpDir/nextidp-admin.env" `
        "$($vm.Target):$remoteTmpDir/nextidp-accounts.txt" `
        "$($vm.Target):$remoteTmpDir/vm-nextidp.env" `
        $localTmpDir
    if ($LASTEXITCODE -ne 0) { throw "scp download failed" }

    foreach ($pair in @(
        @{ Src = (Join-Path $localTmpDir "nextidp-admin.env");    Dst = (Join-Path $awsPrivate "nextidp-admin.env") },
        @{ Src = (Join-Path $localTmpDir "nextidp-accounts.txt"); Dst = (Join-Path $awsPrivate "nextidp-accounts.txt") },
        @{ Src = (Join-Path $localTmpDir "vm-nextidp.env");       Dst = (Join-Path $awsPrivate "aws-vm-nextidp.env") },
        @{ Src = (Join-Path $localTmpDir "nextidp-admin.env");    Dst = (Join-Path $idpPrivate "aws-nextidp-admin.env") },
        @{ Src = (Join-Path $localTmpDir "nextidp-accounts.txt"); Dst = (Join-Path $idpPrivate "aws-nextidp-accounts.txt") },
        @{ Src = (Join-Path $localTmpDir "vm-nextidp.env");       Dst = (Join-Path $idpPrivate "aws-vm-nextidp.env") }
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
