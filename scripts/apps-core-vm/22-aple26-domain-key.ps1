# Give aple26 (Apps-Core-VM) the whois API key that the domains app on Web-1 expects (its `api.key`), then restart aple26.
#   .\scripts\apps-core-vm\22-aple26-domain-key.ps1
# The value goes Web-1 -> PC (memory, a 0600 temp file) -> Apps-Core-VM (0600 temp file) and is never printed.
# aple26's .env is backed up first (shared/.env.bak-<ts>). Check: one whois call with the new key (status code only).
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\mail-vm\common.ps1")
Initialize-Toolchain
$repo = Resolve-RepoRoot
$w1 = Get-VmTarget -RepoRoot $repo -Name "Web-1"
$ac = Get-VmTarget -RepoRoot $repo -Name "Apps-Core-VM"
$wo = @("-i", $w1.SshKey, "-o", "BatchMode=yes", "-o", "ConnectTimeout=20")
$ao = @("-i", $ac.SshKey, "-o", "BatchMode=yes", "-o", "ConnectTimeout=20")
$get = "sudo sed -n 's/^[[:space:]]*api\.key[[:space:]]*=[[:space:]]*//p' /srv/phpapps/domains.rajesh.app/.env | tail -1"
$raw = (& ssh -n @wo $w1.Target $get | Out-String).Trim().Trim("'").Trim('"').Trim()
if ($LASTEXITCODE -ne 0 -or $raw.Length -lt 16 -or $raw -match '\s|CHANGE_ME') { throw "could not read a usable api.key on Web-1" }
$tmp = Join-Path $env:TEMP "aple26-key-$PID.txt"
[IO.File]::WriteAllText($tmp, $raw, (New-Object Text.UTF8Encoding($false))); Remove-Variable raw
$remote = "/tmp/.aple26-key-$PID"
try {
    & ssh -n @ao $ac.Target "umask 077 && : > $remote" | Out-Null
    & scp -q @ao $tmp "$($ac.Target):$remote" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "upload failed" }
} finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
$sh = @'
set -euo pipefail
E=/srv/apps/aple26/shared/.env; K=__REMOTE__
trap 'rm -f "$K"' EXIT
TS=$(date -u +%Y%m%dT%H%M%SZ)
cp -a "$E" "$E.bak-$TS"; chmod 0600 "$E.bak-$TS"
python3 - "$E" "$K" <<'PY'
import os, sys
env, keyf = sys.argv[1], sys.argv[2]
key = open(keyf).read().strip()
lines = open(env).read().splitlines()
out, done = [], False
for l in lines:
    if l.startswith("DOMAIN_API_KEY="):
        out.append("DOMAIN_API_KEY=" + key); done = True
    else:
        out.append(l)
if not done:
    out.append("DOMAIN_API_KEY=" + key)
st = os.stat(env)
open(env, "w").write("\n".join(out) + "\n")
os.chown(env, st.st_uid, st.st_gid); os.chmod(env, st.st_mode & 0o7777)
PY
echo "backup: $E.bak-$TS"
set -a; . "$E"; set +a
printf "whois with the new key: "
curl -s -o /dev/null -w "%{http_code}\n" -m 20 -H "X-API-Key: $DOMAIN_API_KEY" -H "Accept: application/json" "$DOMAIN_API_URL?domain=example.com"
systemctl restart aple26
for i in $(seq 1 30); do curl -fsS -m 3 http://127.0.0.1:8097/health/ready >/dev/null 2>&1 && break; sleep 1; done
echo "aple26: $(systemctl is-active aple26), health $(curl -s -m 5 http://127.0.0.1:8097/health)"
'@
$sh = $sh.Replace("__REMOTE__", $remote) -replace "`r`n", "`n"
$f = Join-Path $env:TEMP "aple26-key-$PID.sh"
[IO.File]::WriteAllText($f, $sh, (New-Object Text.UTF8Encoding($false)))
& scp -q @ao $f "$($ac.Target):/tmp/aple26-key-$PID.sh" | Out-Null; Remove-Item $f
& ssh -n @ao $ac.Target "sudo bash /tmp/aple26-key-$PID.sh; rc=`$?; rm -f /tmp/aple26-key-$PID.sh $remote; exit `$rc"
if ($LASTEXITCODE -ne 0) { throw "update on Apps-Core-VM failed" }
