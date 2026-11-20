#!/usr/bin/env bash
# Runs on LocalCen-1-VM. Puts the Next iDP values (made by apps-core-vm/18-setup-localcen-idp, file IN_FILE)
# into LocalCen's shared/.env, makes the Local apps' client key set (localcen idp:client-keys), restarts,
# health-checks, and restores the previous .env if LocalCen does not come back.
# MODE=check (report only) | apply. Never prints values (key names only).
set -Eeuo pipefail
exec 2>&1
MODE="${MODE:-check}"
IN_FILE="${IN_FILE:?}"
APP=/srv/apps/localcen
ENV_FILE=$APP/shared/.env
TS=$(date -u +%Y%m%dT%H%M%SZ)
trap 'sudo rm -f "$IN_FILE"' EXIT
[[ "$MODE" =~ ^(check|apply)$ ]] || { echo "FATAL: MODE must be check or apply"; exit 1; }
sudo test -f "$ENV_FILE" || { echo "FATAL: $ENV_FILE missing"; exit 1; }
sudo test -s "$IN_FILE" || { echo "FATAL: $IN_FILE missing"; exit 1; }

echo "== keys to set (in .env now? same value?)"
sudo env ENV_FILE="$ENV_FILE" IN_FILE="$IN_FILE" python3 - <<'PY'
import os
def read(p):
    d = {}
    for l in open(p, encoding="utf-8"):
        s = l.strip()
        if s and not s.startswith("#") and "=" in s:
            k, v = s.split("=", 1); d[k.strip()] = v.strip()
    return d
cur, new = read(os.environ["ENV_FILE"]), read(os.environ["IN_FILE"])
for k in sorted(new):
    state = "missing" if k not in cur else ("same" if cur[k] == new[k] else "changes")
    print(f"  {k}: {state}")
PY

if [ "$MODE" = "check" ]; then
  echo "CHECK DONE (nothing written)"
  exit 0
fi

echo "== backup"
BK=/var/backups/localcen/pre-idp-env-$TS
sudo mkdir -p "$BK" && sudo chmod 700 "$BK"
sudo cp -a "$ENV_FILE" "$BK/.env"
echo "backup: $BK/.env"

echo "== merge into $ENV_FILE (owner and mode kept)"
sudo env ENV_FILE="$ENV_FILE" IN_FILE="$IN_FILE" python3 - <<'PY'
import os
envf, inf = os.environ["ENV_FILE"], os.environ["IN_FILE"]
new = {}
for l in open(inf, encoding="utf-8"):
    s = l.strip()
    if s and not s.startswith("#") and "=" in s:
        k, v = s.split("=", 1); new[k.strip()] = v.strip()
lines, seen = [], set()
for l in open(envf, encoding="utf-8").read().splitlines():
    k = l.split("=", 1)[0].strip() if "=" in l and not l.lstrip().startswith("#") else None
    if k in new:
        lines.append(f"{k}={new[k]}"); seen.add(k)
    else:
        lines.append(l)
add = [k for k in new if k not in seen]
if add:
    lines += ["", "# Next iDP (apps-core-vm/18-setup-localcen-idp, localcen-1-vm/05-wire-localcen-idp)"]
    lines += [f"{k}={new[k]}" for k in add]
st = os.stat(envf)
with open(envf, "w", encoding="utf-8") as fh:
    fh.write("\n".join(lines) + "\n")
os.chown(envf, st.st_uid, st.st_gid); os.chmod(envf, st.st_mode & 0o7777)
print(f"  replaced {len(seen)}, added {len(add)}")
PY

echo "== client key set (localcen idp:client-keys, as webapps)"
KEYS=$(sudo sed -n 's/^IDP_PEOPLE_CLIENT_KEYS_FILE=//p' "$ENV_FILE" | tail -1)
sudo install -d -o webapps -g webapps -m 0700 "$(dirname "$KEYS")"
(cd "$APP/current" && sudo -u webapps bash -c "set -a; . '$ENV_FILE'; set +a; ./localcen idp:client-keys")

echo "== restart + health"
sudo systemctl restart localcen.service localcen-worker.service
ok=""
for i in $(seq 1 30); do
  if curl -fsS -m 3 http://127.0.0.1:8092/healthz >/dev/null 2>&1; then ok=1; break; fi
  sleep 1
done
if [ -z "$ok" ]; then
  echo "!! health failed; restoring the previous .env"
  sudo journalctl -u localcen -n 30 --no-pager || true
  sudo cp -a "$BK/.env" "$ENV_FILE"
  sudo systemctl restart localcen.service localcen-worker.service
  exit 1
fi
echo "healthy; $(systemctl is-active localcen localcen-worker | paste -sd' ')"
echo "== sign-in redirects (expect 302 to the IdP)"
for h in localcen.cconsole.com admin.localcen.cconsole.com; do
  loc=$(curl -s -o /dev/null -m 10 -w '%{http_code} %{redirect_url}' -H "Host: $h" -H 'X-Forwarded-Proto: https' http://127.0.0.1:8092/auth/login)
  echo "  $h /auth/login -> ${loc%%\?*}"
done
echo "APPLY DONE"
