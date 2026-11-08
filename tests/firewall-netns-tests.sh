#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
# Real traffic tests for the nftables table host_filter (role firewall) in network namespaces.
# Renders host_filter.nft.j2 with Ansible (profile default and edge), loads it into a namespace "node"
# and checks with real TCP connections: NodePort/hostPort, 80/443, admin UI, SSH, API, pods.
# Needs root (sudo without password), ip, nft and ansible-playbook. If one is missing: SKIP and exit 0.
# Usage: bash tests/firewall-netns-tests.sh [repo root]
# shellcheck disable=SC2016
set -u
R=$(cd "${1:-$(dirname "${BASH_SOURCE[0]}")/..}" && pwd -P)
mkdir -p "$HOME/.cache/lab-sh-tests"
T=$(mktemp -d -p "$HOME/.cache/lab-sh-tests")
P=fwt$$
SUDO=""
[ "$(id -u)" = 0 ] || SUDO="sudo -n"
for w in ip nft ansible-playbook python3; do
  command -v "$w" > /dev/null 2>&1 || [ -x "/usr/sbin/$w" ] || { echo "SKIP: $w missing"; exit 0; }
done
NFT=$(command -v nft || echo /usr/sbin/nft)
IPB=$(command -v ip || echo /usr/sbin/ip)
if ! $SUDO "$IPB" netns list > /dev/null 2>&1; then echo "SKIP: no root (sudo -n) for namespaces"; rmdir "$T"; exit 0; fi
# Listing works in some containers where creating does not (no CAP_NET_ADMIN): probe with a real namespace.
if ! $SUDO "$IPB" netns add "$P-probe" > /dev/null 2>&1; then echo "SKIP: cannot create network namespaces (no CAP_NET_ADMIN)"; rmdir "$T"; exit 0; fi
$SUDO "$IPB" netns del "$P-probe" > /dev/null 2>&1 || true

NS_K=$P-node
NS_X=$P-outside
NS_P=$P-pod
RENDER=$R/ansible/_fw-render-$P.yml
cleanup() {
  for ns in "$NS_K" "$NS_X" "$NS_P"; do
    # shellcheck disable=SC2086  # $SUDO is deliberately one word per argument ("sudo -n")
    $SUDO "$IPB" netns pids "$ns" 2> /dev/null | xargs -r $SUDO kill 2> /dev/null
    $SUDO "$IPB" netns del "$ns" 2> /dev/null
  done
  rm -f "$RENDER"
  rm -rf "$T"
}
trap cleanup EXIT

fail=0
n=0
ok() { n=$((n + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else echo "FAIL $1 (actual '$2', expected '$3')"; fail=$((fail + 1)); fi; }
nsx() { local ns=$1; shift; $SUDO "$IPB" netns exec "$ns" "$@"; }

# ---------- Render rules (profile default and edge), check beforehand with nft -c
cat > "$RENDER" <<'YML'
- hosts: k3s
  connection: local
  gather_facts: false
  tasks:
    - ansible.builtin.template:
        src: "{{ playbook_dir }}/roles/firewall/templates/host_filter.nft.j2"
        dest: "{{ out }}"
        mode: "0644"
YML
render() {
  (cd "$R/ansible" && ansible-playbook -i inventory "$RENDER" -e "out=$T/$1.nft" "${@:2}" > "$T/render-$1.log" 2>&1)
}
render default; ok "Render rules: default" "$?" 0
render edge -e edge_profile=edge; ok "Render rules: edge" "$?" 0
render nodnat -e firewall_dnat_admin_only=false; ok "Render rules: without DNAT block" "$?" 0
for f in default edge nodnat; do
  $SUDO "$NFT" -c -f "$T/$f.nft" > "$T/c-$f.log" 2>&1; ok "nft -c: $f" "$?" 0
done

# ---------- Topologie
# outside (192.168.122.1 admin, .77 other network member, 10.5.0.9 foreign network, target for pod-to-outside)
#   | veth
# node (192.168.122.50, SSH/API listener, cni0 10.42.0.1, DNAT replica, masquerade)
#   | cni0 (Bridge) + veth
# pod (10.42.0.2)
$SUDO "$IPB" netns add "$NS_K" && $SUDO "$IPB" netns add "$NS_X" && $SUDO "$IPB" netns add "$NS_P"
ok "Namespaces created" "$?" 0
IFA=a$$
IFB=b$$
IFP=p$$
IFQ=q$$
E=0
{
  $SUDO "$IPB" link add "$IFA" type veth peer name "$IFB" &&
    $SUDO "$IPB" link set "$IFA" netns "$NS_X" && $SUDO "$IPB" link set "$IFB" netns "$NS_K" &&
    nsx "$NS_X" "$IPB" link set lo up && nsx "$NS_K" "$IPB" link set lo up &&
    nsx "$NS_X" "$IPB" addr add 192.168.122.1/24 dev "$IFA" &&
    nsx "$NS_X" "$IPB" addr add 192.168.122.77/24 dev "$IFA" &&
    nsx "$NS_X" "$IPB" addr add 10.5.0.9/24 dev "$IFA" &&
    nsx "$NS_X" "$IPB" link set "$IFA" up &&
    nsx "$NS_K" "$IPB" addr add 192.168.122.50/24 dev "$IFB" &&
    nsx "$NS_K" "$IPB" link set "$IFB" up &&
    nsx "$NS_K" "$IPB" route add 10.5.0.0/24 dev "$IFB" &&
    nsx "$NS_K" "$IPB" link add cni0 type bridge &&
    nsx "$NS_K" "$IPB" addr add 10.42.0.1/24 dev cni0 &&
    nsx "$NS_K" "$IPB" link set cni0 up &&
    $SUDO "$IPB" link add "$IFP" type veth peer name "$IFQ" &&
    $SUDO "$IPB" link set "$IFP" netns "$NS_K" && $SUDO "$IPB" link set "$IFQ" netns "$NS_P" &&
    nsx "$NS_K" "$IPB" link set "$IFP" master cni0 && nsx "$NS_K" "$IPB" link set "$IFP" up &&
    nsx "$NS_P" "$IPB" link set lo up &&
    nsx "$NS_P" "$IPB" addr add 10.42.0.2/24 dev "$IFQ" && nsx "$NS_P" "$IPB" link set "$IFQ" up &&
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      nsx "$NS_P" "$IPB" route replace default via 10.42.0.1 2> /dev/null && break
      sleep 0.3
    done
  E=$?
} > "$T/topo.log" 2>&1
ok "Topology is up" "$E" 0; [ "$E" = 0 ] || cat "$T/topo.log"
# A dummy interface is called flannel.1, so that the rule loads and works with both CNI names
nsx "$NS_K" "$IPB" link add flannel.1 type bridge
nsx "$NS_K" sysctl -qw net.ipv4.ip_forward=1
nsx "$NS_K" sysctl -qw net.ipv4.conf.all.rp_filter=0
nsx "$NS_K" "$NFT" -f - <<'NAT' > "$T/nat.log" 2>&1
table ip lab_nat {
  chain pre {
    type nat hook prerouting priority dstnat; policy accept;
    tcp dport 31000 dnat to 10.42.0.2:8080
    tcp dport 8081 dnat to 10.42.0.2:8081
    tcp dport 443 dnat to 10.42.0.2:8443
    tcp dport 80 dnat to 10.42.0.2:8080
    tcp dport 8444 dnat to 10.42.0.2:8444
    ip daddr 10.43.0.10 tcp dport 9100 dnat to 192.168.122.1:9100
  }
  chain post {
    type nat hook postrouting priority srcnat; policy accept;
    oifname "cni0" masquerade
    ip saddr 10.42.0.0/24 oifname != "cni0" masquerade
  }
}
NAT
ok "NAT replica (DNAT like ServiceLB/NodePort) loaded" "$?" 0

# Listeners: node (SSH, API), pod (8080, 8081, 8443, 8444), outside (9100 for pod-to-outside)
LIS='import socket, sys, time
for p in sys.argv[1:]:
    s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("0.0.0.0", int(p))); s.listen(16)
    globals()["s" + p] = s
import select
l = [globals()["s" + p] for p in sys.argv[1:]]
t = time.time()
while time.time() - t < 300:
    r, _, _ = select.select(l, [], [], 1)
    for x in r:
        c, _ = x.accept(); c.close()'
nsx "$NS_K" python3 -c "$LIS" 22 6443 10250 > /dev/null 2>&1 &
nsx "$NS_P" python3 -c "$LIS" 8080 8081 8443 8444 > /dev/null 2>&1 &
nsx "$NS_X" python3 -c "$LIS" 9100 > /dev/null 2>&1 &
sleep 1

CL='import socket, sys
s = socket.socket(); s.settimeout(1.5)
s.bind((sys.argv[1], 0))
try:
    s.connect((sys.argv[2], int(sys.argv[3]))); print("OPEN")
except Exception:
    print("CLOSED")'
# conn NAMESPACE SOURCE TARGET PORT -> OPEN or CLOSED
conn() { nsx "$1" python3 -c "$CL" "$2" "$3" "$4"; }
load_rules() { nsx "$NS_K" "$NFT" -f "$T/$1.nft" > "$T/load-$1.log" 2>&1; }
K=192.168.122.50
ADM=192.168.122.1
LAN=192.168.122.77
FOREIGN=10.5.0.9
POD=10.42.0.2

echo "== Control without rules: everything reachable (otherwise the block tests are worthless)"
ok "without rules: NodePort 31000 open" "$(conn "$NS_X" $LAN $K 31000)" OPEN
ok "without rules: SSH open" "$(conn "$NS_X" $LAN $K 22)" OPEN
ok "without rules: 443 open" "$(conn "$NS_X" $FOREIGN $K 443)" OPEN

echo "== profile default (admin = ingress = VM network)"
load_rules default; ok "default loads into the namespace" "$?" 0
ok "default: admin 22" "$(conn "$NS_X" $ADM $K 22)" OPEN
ok "default: admin 6443" "$(conn "$NS_X" $ADM $K 6443)" OPEN
ok "default: VM network 22 (admin = VM network)" "$(conn "$NS_X" $LAN $K 22)" OPEN
ok "default: foreign network 22 closed" "$(conn "$NS_X" $FOREIGN $K 22)" CLOSED
ok "default: foreign network 6443 closed" "$(conn "$NS_X" $FOREIGN $K 6443)" CLOSED
ok "default: VM network 443 open" "$(conn "$NS_X" $LAN $K 443)" OPEN
ok "default: VM network 80 open" "$(conn "$NS_X" $LAN $K 80)" OPEN
ok "default: foreign network 443 closed" "$(conn "$NS_X" $FOREIGN $K 443)" CLOSED
ok "default: foreign network 80 closed" "$(conn "$NS_X" $FOREIGN $K 80)" CLOSED
ok "default: VM network NodePort 31000 open (admin)" "$(conn "$NS_X" $LAN $K 31000)" OPEN
ok "default: foreign network NodePort 31000 closed" "$(conn "$NS_X" $FOREIGN $K 31000)" CLOSED
ok "default: foreign network hostPort 8081 closed" "$(conn "$NS_X" $FOREIGN $K 8081)" CLOSED
ok "default: VM network admin port 8444 open" "$(conn "$NS_X" $LAN $K 8444)" OPEN
ok "default: foreign network admin port 8444 closed" "$(conn "$NS_X" $FOREIGN $K 8444)" CLOSED

echo "== Profile edge (admin = gateway only, ingress = VM network)"
load_rules edge; ok "edge loads (overlapping sets /24 and /32)" "$?" 0
ok "edge: admin 22" "$(conn "$NS_X" $ADM $K 22)" OPEN
ok "edge: admin 6443" "$(conn "$NS_X" $ADM $K 6443)" OPEN
ok "edge: admin admin port 8444" "$(conn "$NS_X" $ADM $K 8444)" OPEN
ok "edge: admin NodePort 31000" "$(conn "$NS_X" $ADM $K 31000)" OPEN
ok "edge: admin 443" "$(conn "$NS_X" $ADM $K 443)" OPEN
ok "edge: other VM-network address 22 closed" "$(conn "$NS_X" $LAN $K 22)" CLOSED
ok "edge: other VM-network address 6443 closed" "$(conn "$NS_X" $LAN $K 6443)" CLOSED
ok "edge: other VM-network address admin port 8444 closed" "$(conn "$NS_X" $LAN $K 8444)" CLOSED
ok "edge: other VM-network address NodePort 31000 closed" "$(conn "$NS_X" $LAN $K 31000)" CLOSED
ok "edge: other VM-network address hostPort 8081 closed" "$(conn "$NS_X" $LAN $K 8081)" CLOSED
ok "edge: other VM-network address 443 open (released app)" "$(conn "$NS_X" $LAN $K 443)" OPEN
ok "edge: other VM-network address 80 open" "$(conn "$NS_X" $LAN $K 80)" OPEN
ok "edge: foreign network 443 closed" "$(conn "$NS_X" $FOREIGN $K 443)" CLOSED
ok "edge: foreign network 22 closed" "$(conn "$NS_X" $FOREIGN $K 22)" CLOSED

echo "== Pods stay untouched (edge)"
ok "Pod -> API 6443 (node)" "$(conn "$NS_P" $POD 10.42.0.1 6443)" OPEN
ok "Pod -> kubelet 10250" "$(conn "$NS_P" $POD 10.42.0.1 10250)" OPEN
ok "Pod -> node SSH closed" "$(conn "$NS_P" $POD 10.42.0.1 22)" CLOSED
ok "Pod -> outside 9100 (FORWARD, Masquerade)" "$(conn "$NS_P" $POD $ADM 9100)" OPEN
ok "Pod -> Service-IP (DNAT from cni0 to outside) 9100" "$(conn "$NS_P" $POD 10.43.0.10 9100)" OPEN

echo "== Profile default without DNAT block (escape hatch firewall_dnat_admin_only: false)"
load_rules nodnat; ok "nodnat loads" "$?" 0
ok "nodnat: foreign network NodePort 31000 open (block off)" "$(conn "$NS_X" $FOREIGN $K 31000)" OPEN
ok "nodnat: foreign network 22 still closed" "$(conn "$NS_X" $FOREIGN $K 22)" CLOSED

echo "== Reload rules atomically (no flush ruleset)"
nsx "$NS_K" "$NFT" add table ip foreign_test > /dev/null 2>&1
load_rules default; load_rules edge
ok "Reload: foreign table stayed" "$(nsx "$NS_K" "$NFT" list tables | grep -c foreign_test)" 1
ok "Reload: NAT table stayed" "$(nsx "$NS_K" "$NFT" list tables | grep -c lab_nat)" 1
ok "Reload: exactly one table host_filter" "$(nsx "$NS_K" "$NFT" list tables | grep -c host_filter)" 1
ok "Reload: block still applies (edge)" "$(conn "$NS_X" $LAN $K 31000)" CLOSED

echo
echo "$n checks, $fail failures"
[ "$fail" = 0 ]
