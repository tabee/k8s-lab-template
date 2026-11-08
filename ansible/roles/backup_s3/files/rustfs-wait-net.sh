#!/usr/bin/env bash
# Before rustfs starts, waits until the host has an IPv4 default route and an
# address on its interface (ExecStartPre of the quadlet unit).
# Usage: rustfs-wait-net.sh MAX_SECONDS
# Source: ansible/roles/backup_s3/files/rustfs-wait-net.sh, value:
# backup_s3_wait_net_timeout (ansible/inventory/group_vars/all/backup_s3.yml).
#
# Why: pasta (network of the rootless container) reads addresses and routes of the
# host once at start and observes no change later (passt bug 141).
# If the default route is missing at start, the configuration stays wrong: port
# open, but no answer for connections from outside, while the check
# in the container (127.0.0.1) stays green. A user unit cannot wait for the
# system target network-online.target to wait; podman-user-wait-network-online
# only queries this target, not the route. So this script checks itself.
#
# If the time runs out, rustfs starts anyway (exit 0): a backup target without
# network is better than none, and rustfs-watchdog.sh restarts it as soon as
# the path from outside does not answer.
set -u

max=${1:-}
case "$max" in
  ''|*[!0-9]*) echo "rustfs-wait-net: Usage: $0 MAX_SECONDS" >&2; exit 2 ;;
esac

# Name of the interface of the default route (empty = none). Source as in
# pasta: /proc/net/route, destination 00000000 with mask 00000000.
standard_iface() {
  awk 'NR > 1 && $2 == "00000000" && $8 == "00000000" { print $1; exit }' /proc/net/route
}

# Does the interface have a global IPv4 address? Without "ip" only check the route.
hat_adresse() {
  command -v ip >/dev/null || return 0
  ip -4 -o addr show dev "$1" scope global 2>/dev/null | grep -q 'inet '
}

start=$SECONDS
while true; do
  iface=$(standard_iface)
  if [ -n "$iface" ] && hat_adresse "$iface"; then
    echo "rustfs-wait-net: default route via $iface after $((SECONDS - start)) s."
    exit 0
  fi
  if [ $((SECONDS - start)) -ge "$max" ]; then
    echo "rustfs-wait-net: no default route with address after $max s; starting anyway (the watchdog catches this)." >&2
    exit 0
  fi
  sleep 1
done
