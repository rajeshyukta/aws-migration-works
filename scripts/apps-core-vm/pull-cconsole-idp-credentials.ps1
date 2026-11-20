# Pull cconsole Next iDP realm credentials & dns-service OIDC/webhook/API-key secrets
# from Apps-Core-VM (43.204.42.99) into gitignored private-data/ without echoing secrets.
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path (Split-Path -Parent $PSScriptRoot) "mail-vm\common.ps1")
Initialize-Toolchain

$repoRoot = Resolve-RepoRoot
$vm = Get-VmTarget -RepoRoot $repoRoot -Name "Apps-Core-VM"

$awsPrivate = Join-Path $repoRoot "private-data"
$idpPrivate = "E:\workspace\projects\platform\nextidp\private-data"
$dnsPrivate = "E:\workspace\projects\platform\dns-service\private-data"

$remoteTmpDir = "/tmp/awsmig-ccpull-$PID"
$localTmpDir  = Join-Path $env:TEMP "awsmig-ccpull-$PID"
New-Item -ItemType Directory -Path $localTmpDir -Force | Out-Null

$remoteScript = @'
#!/usr/bin/env bash
set -euo pipefail
mkdir -m 0700 -p "$OUT_DIR"

if sudo test -f /root/.nextidp-cconsole-dns.env; then
  sudo cat /root/.nextidp-cconsole-dns.env > "$OUT_DIR/cconsole-realm.env"
else
  echo "FATAL: /root/.nextidp-cconsole-dns.env not found on Apps-Core-VM" >&2
  exit 1
fi
chmod 0600 "$OUT_DIR/cconsole-realm.env"
'@ -replace "`r`n", "`n"

$localSh = Join-Path $localTmpDir "pull.sh"
[IO.File]::WriteAllText($localSh, $remoteScript, [Text.UTF8Encoding]::new($false))

try {
    $remoteSh = "/tmp/awsmig-ccpull-$PID.sh"
    Copy-ToVm -Vm $vm -LocalPath $localSh -RemotePath $remoteSh
    Invoke-VmCommand -Vm $vm -Command "sed -i 's/\r$//' $remoteSh && chmod +x $remoteSh && { OUT_DIR=$remoteTmpDir bash $remoteSh; rc=`$?; rm -f $remoteSh; exit `$rc; }"

    & scp -i $vm.SshKey -o StrictHostKeyChecking=accept-new -o BatchMode=yes `
        "$($vm.Target):$remoteTmpDir/cconsole-realm.env" `
        $localTmpDir
    if ($LASTEXITCODE -ne 0) { throw "scp download failed" }

    $raw = ([IO.File]::ReadAllText((Join-Path $localTmpDir "cconsole-realm.env"))) -replace "`r`n", "`n"
    foreach ($dst in @(
        (Join-Path $awsPrivate "cconsole-realm.env"),
        (Join-Path $awsPrivate "dns-idp.txt"),
        (Join-Path $idpPrivate "aws-cconsole-realm.env"),
        (Join-Path $dnsPrivate "aws-dns-idp.txt")
    )) {
        if (Test-Path -LiteralPath (Split-Path -Parent $dst)) {
            [IO.File]::WriteAllText($dst, $raw, [Text.UTF8Encoding]::new($false))
            Write-Host "Saved: $dst ($((Get-Item $dst).Length) bytes)" -ForegroundColor Green
        }
    }
} finally {
    Invoke-VmCommand -Vm $vm -Command "rm -rf -- $remoteTmpDir"
    if (Test-Path -LiteralPath $localTmpDir) { Remove-Item -LiteralPath $localTmpDir -Recurse -Force }
}
