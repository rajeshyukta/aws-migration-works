#!/usr/bin/env bash
# READ-ONLY inventory of one VM for docs/vms-setup-and-services-and-all-info.md (section 11). Prints no secret values.
set -uo pipefail
exec 2>&1
cd /tmp
echo "## host"
echo "hostname=$(hostname) os=$(. /etc/os-release; echo "$PRETTY_NAME") kernel=$(uname -r) tz=$(timedatectl show -p Timezone --value)"
echo "cpu=$(nproc) ram_mb=$(free -m | awk 'NR==2{print $2}') swap_mb=$(free -m | awk 'NR==3{print $2}') disk=$(df -h / | awk 'NR==2{print $2" used "$3" ("$5")"}')"
echo "private_ips=$(ip -4 -o addr show scope global | awk '{print $4}' | paste -sd' ')"
tok=$(curl -s -m 2 -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' 2>/dev/null)
if [ -n "$tok" ]; then
  md() { curl -s -m 2 -H "X-aws-ec2-metadata-token: $tok" "http://169.254.169.254/latest/meta-data/$1" 2>/dev/null; }
  echo "aws: type=$(md instance-type) az=$(md placement/availability-zone) id=$(md instance-id) public_ipv4=$(md public-ipv4 | paste -sd' ')"
fi
echo "uptime=$(uptime -p)"
echo "## listening (tcp/udp, public-facing marked)"
ss -H -ltnu | awk '{print $1, $5}' | sed -E 's/%[a-z0-9]+//' | sort -u | awk '{a=$2; sub(/.*:/,"",a); print $1":"a" on "$2}' | sort -t: -k2 -n -u | paste -sd';'
echo "## firewall"
sudo ufw status 2>/dev/null | grep -E 'ALLOW|Status' | sed 's/  */ /g' | paste -sd';'
echo "## custom services (active)"
systemctl list-units --type=service --state=running --no-legend --plain | awk '{print $1}' | grep -vE '^(systemd-|dbus|cron|getty|serial-getty|ssh|rsyslog|polkit|snapd|unattended|multipathd|networkd|ModemManager|udisks|chrony|irqbalance|user@|packagekit|fwupd|cloud|amazon-ssm|acpid|atd|lvm|qemu|vmtoolsd|open-vm|iscsid|fail2ban|apport|php8.4-fpm|polkit)' | sed 's/\.service$//' | paste -sd' '
echo "fail2ban=$(systemctl is-active fail2ban 2>/dev/null) php-fpm=$(systemctl is-active php8.4-fpm 2>/dev/null) caddy=$(systemctl is-active caddy 2>/dev/null) redis=$(systemctl is-active redis-server 2>/dev/null) postgres=$(systemctl is-active postgresql 2>/dev/null)"
echo "## versions"
echo "caddy=$(caddy version 2>/dev/null | cut -d' ' -f1) php=$(php -r 'echo PHP_VERSION;' 2>/dev/null) psql=$(psql --version 2>/dev/null | awk '{print $3}') redis=$(redis-server --version 2>/dev/null | sed -E 's/.*v=([0-9.]+).*/\1/') restic=$(restic version 2>/dev/null | awk '{print $2}') go_bins=$(ls /opt/*/bin /srv/apps/*/current 2>/dev/null | head -0)"
echo "## timers (custom)"
systemctl list-timers --all --no-pager --no-legend | awk '{for(i=1;i<=NF;i++) if($i ~ /\.timer$/) print $i}' | grep -vE '^(apt-|dpkg-|e2scrub|fstrim|fwupd|logrotate|man-db|motd-news|sysstat|systemd-|snapd|update-notifier|ua-|apport)' | paste -sd' '
echo "## cron.d (custom)"
ls /etc/cron.d 2>/dev/null | grep -vE '^(e2scrub_all|php|sysstat|\.placeholder|popularity-contest)$' | paste -sd' '
for u in $(ls /var/spool/cron/crontabs 2>/dev/null); do echo "crontab:$u"; done
echo "## caddy hostnames"
if command -v caddy >/dev/null && [ -f /etc/caddy/Caddyfile ]; then
  sudo -u caddy caddy adapt --config /etc/caddy/Caddyfile --adapter caddyfile 2>/dev/null | python3 -c '
import json,sys
cfg=json.load(sys.stdin); hosts=set(); od=False
for s in cfg.get("apps",{}).get("http",{}).get("servers",{}).values():
    for r in s.get("routes",[]):
        for m in r.get("match",[]):
            for h in m.get("host",[]): hosts.add(h)
pol=cfg.get("apps",{}).get("tls",{}).get("automation",{}).get("policies",[])
od=any(p.get("on_demand") for p in pol)
print(" ".join(sorted(hosts))); print("on_demand_tls="+str(od))'
  echo "site_files=$(ls /etc/caddy/sites-enabled 2>/dev/null | wc -l)"
fi
echo "## postgres"
pg_lsclusters --no-header 2>/dev/null | awk '{print "cluster "$1"/"$2" port="$3" "$4}'
for port in $(pg_lsclusters --no-header 2>/dev/null | awk '$4=="online"{print $3}'); do
  sudo -u postgres psql -p "$port" -XAt -c "SELECT 'db '||datname||' owner='||pg_get_userbyid(datdba)||' size='||pg_size_pretty(pg_database_size(datname)) FROM pg_database WHERE NOT datistemplate AND datname<>'postgres' ORDER BY 1" 2>/dev/null | sed "s/^/  [port $port] /"
done
echo "listen_addresses=$(sudo -u postgres psql -XAt -c 'SHOW listen_addresses' 2>/dev/null)"
echo "## php pools"
ls /etc/php/8.4/fpm/pool.d 2>/dev/null | grep -v disabled | sed 's/\.conf$//' | paste -sd' '
echo "## app dirs"
for d in /opt/* /srv/apps/* /srv/phpapps/* /srv/static/*; do [ -d "$d" ] && printf '%s ' "$d"; done; echo
for d in /srv/apps/*; do [ -L "$d/current" ] && echo "  $d/current -> $(readlink "$d/current" | sed 's#.*/releases/##')"; done
echo "## systemd unit files of apps (names)"
ls /etc/systemd/system/*.service 2>/dev/null | xargs -n1 basename | grep -vE '^(dbus-|sshd|snap|cloud|syslog|vmtoolsd|iscsi|chronyd|redis)' | paste -sd' '
echo "## backups"
if sudo test -x /usr/local/sbin/nextdp-offsite-backup; then
  sudo /usr/local/sbin/nextdp-offsite-backup status 2>/dev/null | grep -E '^(VM|last)'
  systemctl list-timers 'nextdp-offsite-*' --no-pager --no-legend | awk '{print $1" "$2" "$3" "$4" -> "$NF}'
else echo "offsite backup: NOT INSTALLED"; fi
echo "## secrets files (paths only)"
sudo find /root /etc/nextdp-backup /opt -maxdepth 3 \( -name '.env' -o -name '*.env' -o -name '*-pass' -o -name '*secrets*' -o -name '*.key' \) 2>/dev/null | grep -vE '/(node_modules|vendor)/' | sort | head -30 | paste -sd' '
sudo find /srv -maxdepth 4 -name '.env' 2>/dev/null | sort | paste -sd' '
echo "## end"
