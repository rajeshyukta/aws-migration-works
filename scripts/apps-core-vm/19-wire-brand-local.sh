#!/usr/bin/env bash
# Runs on Apps-Core-VM. Connects a NextDP Core brand to its LocalCen tenant:
#   1. (ENABLE_FEATURE=1) brand feature `local` on, if it is not
#   2. nextdp ops:local-wire-brand (pings LocalCen with the key first, seals key + webhook secret)
#      with LOCAL_API_KEY / LOCAL_WEBHOOK_SECRET from IN_FILE, in the environment of that one process
#   3. restart NextDP Core when the feature changed
#   4. signed test webhook to https://console.<brand>/webhooks/local-2fa (an unknown event: accepted
#      signature = "event ignored" in the log, a bad one = "rejected")
# MODE=check (ops --dry-run, no writes) | apply. Never prints secret values.
set -Eeuo pipefail
exec 2>&1
MODE="${MODE:-check}"; BRAND="${BRAND:?}"; IN_FILE="${IN_FILE:?}"; ENABLE_FEATURE="${ENABLE_FEATURE:-0}"
BASE_URL="${BASE_URL:-https://localcen.cconsole.com/v1}"; SERVICE_IP="${SERVICE_IP:-3.111.132.3}"
NEXTDP_ENV=/srv/apps/nextdp/shared/.env
trap 'sudo rm -f "$IN_FILE"' EXIT
[[ "$MODE" =~ ^(check|apply)$ ]] || { echo "FATAL: MODE must be check or apply"; exit 1; }
[[ "$BRAND" =~ ^[a-z0-9-]+$ ]] || { echo "FATAL: bad brand"; exit 1; }
sudo test -s "$IN_FILE" || { echo "FATAL: $IN_FILE missing"; exit 1; }

q() { sudo -u postgres psql -d nextdp_core -At -v ON_ERROR_STOP=1 -v brand="$BRAND"; }
BID=$(echo "select id from brands where slug = :'brand';" | q)
[ -n "$BID" ] || { echo "FATAL: brand $BRAND not found"; exit 1; }
FEAT=$(echo "select coalesce(bool_or(is_enabled)::text,'none') from brand_features f join brands b on b.id = f.brand_id where b.slug = :'brand' and f.feature_key = 'local';" | q)
echo "brand $BRAND $BID: feature local = $FEAT"
CHANGED=0
if [ "$MODE" = "apply" ]; then
  TS=$(date -u +%Y%m%dT%H%M%SZ); BK=/var/backups/nextdp-core/pre-local-$BRAND-$TS
  sudo mkdir -p "$BK" && sudo chmod 700 "$BK"
  sudo -u postgres pg_dump -Fc -d nextdp_core | sudo tee "$BK/nextdp_core.dump" >/dev/null
  echo "backup: $BK/nextdp_core.dump"
fi
if [ "$FEAT" != "true" ]; then
  if [ "$ENABLE_FEATURE" != "1" ]; then
    echo "NOTE: feature local is off for $BRAND (pass -EnableFeature to turn it on)"
  elif [ "$MODE" = "apply" ]; then
    cat <<'SQL' | q
update brand_features set is_enabled = true, updated_at = now() where brand_id = (select id from brands where slug = :'brand') and feature_key = 'local';
insert into brand_features (brand_id, feature_key, is_enabled, created_at, updated_at)
select id, 'local', true, now(), now() from brands where slug = :'brand'
 and not exists (select 1 from brand_features f where f.brand_id = brands.id and f.feature_key = 'local');
SQL
    echo "feature local -> on"; CHANGED=1
  else
    echo "would turn feature local on"
  fi
fi

DRY=""; [ "$MODE" = "check" ] && DRY="--dry-run"
echo "== ops:local-wire-brand $DRY"
sudo env IN_FILE="$IN_FILE" NEXTDP_ENV="$NEXTDP_ENV" BRAND="$BRAND" BASE_URL="$BASE_URL" SERVICE_IP="$SERVICE_IP" DRY="$DRY" \
  bash -c 'set -a; . "$NEXTDP_ENV"; . "$IN_FILE"; set +a; cd /srv/apps/nextdp/current && ./nextdp ops:local-wire-brand --brand "$BRAND" --base-url "$BASE_URL" --service-ip "$SERVICE_IP" $DRY' \
  > /tmp/.19-ops-$$.log 2>&1 && rc=0 || rc=$?
grep -v -e 'no .env file found' -e 'DB_SSL_MODE' /tmp/.19-ops-$$.log || true
rm -f /tmp/.19-ops-$$.log
echo "ops exit=$rc"
[ "$rc" = "0" ] || { echo "FATAL: ops:local-wire-brand failed"; exit 1; }
[ "$MODE" = "apply" ] || { echo "CHECK DONE (nothing written)"; exit 0; }

if [ "$CHANGED" = "1" ]; then
  sudo systemctl restart nextdp nextdp-worker nextdp-scheduler
  for i in $(seq 1 30); do curl -fsS -m 3 -o /dev/null http://127.0.0.1:8090/ 2>/dev/null && break; sleep 1; done
  echo "nextdp restarted: $(systemctl is-active nextdp nextdp-worker nextdp-scheduler | paste -sd' ')"
fi

echo "== signed test webhook -> https://$CONSOLE_HOST/webhooks/local-2fa"
HOST="${CONSOLE_HOST:?}"
SINCE=$(date -u '+%Y-%m-%d %H:%M:%S')
sudo env IN_FILE="$IN_FILE" HOST="$HOST" python3 - <<'PY'
import hashlib, hmac, json, os, time, urllib.request, urllib.error
d = dict(l.strip().split("=", 1) for l in open(os.environ["IN_FILE"]) if "=" in l and not l.startswith("#"))
body = json.dumps({"type": "setup.ping", "sent_at": int(time.time())}).encode()
ts = str(int(time.time()))
sig = hmac.new(d["LOCAL_WEBHOOK_SECRET"].encode(), ts.encode() + b"." + body, hashlib.sha256).hexdigest()
req = urllib.request.Request(f"https://{os.environ['HOST']}/webhooks/local-2fa", data=body, method="POST",
      headers={"Content-Type": "application/json", "X-Local-Timestamp": ts, "X-Local-Signature": sig})
try:
    with urllib.request.urlopen(req, timeout=15) as r:
        print(f"  {os.environ['HOST']} -> HTTP {r.status} {r.read()[:80]!r}")
except urllib.error.HTTPError as e:
    print(f"  {os.environ['HOST']} -> HTTP {e.code}")
PY
sleep 1
sudo journalctl -u nextdp --since "$SINCE" --no-pager -o cat | grep -E 'local webhook: event ignored|local 2FA webhook rejected' | cut -c1-220 | tail -3
echo "APPLY DONE"
