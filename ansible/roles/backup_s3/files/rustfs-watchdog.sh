#!/usr/bin/env bash
# Checks the EXTERNAL path to rustfs and restarts the unit on errors.
# Usage (from the systemd user timer, values from group_vars/all/backup_s3.yml):
#   rustfs-watchdog.sh URL UNIT ATTEMPTS PAUSE GRACE MAX_RESTARTS CURL_SECONDS
# Example: http://192.168.122.1:9000/health rustfs.service 3 5 180 5 5
#
# Why: the healthcheck of the quadlet unit runs INSIDE the container against 127.0.0.1.
# On the reboot of the PC on 2026-10-28 rustfs accepted connections from the VM,
# but never answered; the check stayed green, CNPG backups and WAL archive
# failed silently for two days. This script asks like the VM: via the
# address of the bridge on the host. A restart fixed the error back then.
#
# Sequence:
#   1. Unit not active or younger than GRACE seconds: do nothing.
#   2. Address from the URL not on this host (bridge missing): do nothing.
#   3. Up to ATTEMPTS requests at interval PAUSE; one answer 200 is enough.
#   4. Otherwise diagnosis into the journal and systemctl --user restart.
#   5. After MAX_RESTARTS unsuccessful restarts in a row: give up (exit 1),
#      so that no restart storm occurs. The counter lives in XDG_RUNTIME_DIR
#      (gone after the reboot of the PC) and is deleted on success.
set -u

if [ $# -ne 7 ]; then
  echo "Usage: $0 URL UNIT ATTEMPTS PAUSE GRACE MAX_RESTARTS CURL_SECONDS" >&2
  exit 2
fi
url=$1 unit=$2 attempts=$3 pause=$4 grace=$5 max_restarts=$6 curl_s=$7
for n in "$attempts" "$pause" "$grace" "$max_restarts" "$curl_s"; do
  case "$n" in
    ''|*[!0-9]*) echo "rustfs-watchdog: number expected, not '$n'" >&2; exit 2 ;;
  esac
done

host=${url#*://}
host=${host%%/*}
port=${host##*:}
host=${host%%:*}
counter="${XDG_RUNTIME_DIR:-/tmp}/${unit%.service}-watchdog.restarts"

log() { echo "rustfs-watchdog: $*"; }

state=$(systemctl --user show -p ActiveState --value "$unit" 2>/dev/null)
if [ "$state" != active ]; then
  log "$unit is '$state', nothing to check."
  exit 0
fi

# Age of the unit in seconds: monotonic time of the start against the uptime of the host.
start_us=$(systemctl --user show -p ActiveEnterTimestampMonotonic --value "$unit" 2>/dev/null)
age_s=$(awk -v s="${start_us:-0}" 'NR == 1 { printf "%d", $1 - s / 1000000 }' /proc/uptime)
if [ "$age_s" -lt "$grace" ]; then
  log "$unit has only run for $age_s s (grace $grace s), no check yet."
  exit 0
fi

if command -v ip >/dev/null && [ -z "$(ip -4 -o addr show to "$host" 2>/dev/null)" ]; then
  log "Address $host is not on this host (bridge not there yet?), nothing to check."
  exit 0
fi

attempt=1
while true; do
  if curl --noproxy '*' -fsS -o /dev/null --max-time "$curl_s" "$url"; then
    rm -f "$counter"
    log "ok: $url answers (attempt $attempt)."
    exit 0
  fi
  if [ "$attempt" -ge "$attempts" ]; then
    break
  fi
  attempt=$((attempt + 1))
  sleep "$pause"
done

so_far=0
if [ -f "$counter" ]; then
  so_far=$(cat "$counter")
fi
case "$so_far" in
  ''|*[!0-9]*) so_far=0 ;;
esac
if [ "$so_far" -ge "$max_restarts" ]; then
  log "ERROR: $url does not answer, $so_far restarts did not help. Giving up (counter: $counter)."
  exit 1
fi

log "ERROR: $url does not answer ($attempts attempts). Diagnosis:"
ip -4 route show default 2>&1 | sed 's/^/  route: /'
ip -4 -o addr show scope global 2>&1 | sed 's/^/  addr: /'
ss -Hltn "sport = :$port" 2>&1 | sed 's/^/  listen: /'
pgrep -a pasta 2>&1 | sed 's/^/  pasta: /'
echo $((so_far + 1)) > "$counter"
log "restarting $unit (restart $((so_far + 1)) of $max_restarts)."
systemctl --user restart "$unit"
