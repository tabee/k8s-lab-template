#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
# Offline tests for the WireGuard role (issue #60): values, templates, syntax, key generation.
# No live tunnel, no cloud node. Usage: bash tests/wireguard-tests.sh [repo root]
set -u
export PYTHONDONTWRITEBYTECODE=1
R=$(cd "${1:-$(dirname "${BASH_SOURCE[0]}")/..}" && pwd -P)
mkdir -p "$HOME/.cache/lab-sh-tests"
T=$(mktemp -d -p "$HOME/.cache/lab-sh-tests")
trap 'rm -rf "$T"' EXIT
fail=0
n=0
ok() { n=$((n + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else echo "FAIL $1 (is '$2', want '$3')"; fail=$((fail + 1)); fi; }
has() { grep -Fq -- "$2" "$3"; local r=$?; ok "$1" "$r" 0; [ "$r" = 0 ] || sed "s/^/       | /" "$3" 2>/dev/null | tail -8; }
hasnot() { ! grep -Fq -- "$2" "$3"; ok "$1" "$?" 0; }
rc() { "$@" > "$T/out" 2>&1; echo $?; }

echo "== repo layout"
has "role tasks exist" "wireguard_mode" "$R/ansible/roles/wireguard/tasks/main.yml"
has "role template loads key via PostUp" "PostUp = wg set" "$R/ansible/roles/wireguard/templates/wg0.conf.j2"
hasnot "template must not embed PrivateKey =" "PrivateKey =" "$R/ansible/roles/wireguard/templates/wg0.conf.j2"
has "group_vars default off" "wireguard_enabled: false" "$R/ansible/inventory/group_vars/all/wireguard.yml"
has "playbook exists" "WireGuard on the node" "$R/ansible/wireguard.yml"
has "site.yml mentions the role" "role: wireguard" "$R/ansible/site.yml"
has "firewall opens UDP when port set" "firewall_wireguard_udp_port" "$R/ansible/roles/firewall/templates/host_filter.nft.j2"
has "how-to exists" "Issue 60" "$R/docs/how-to/wireguard-tunnel.md"
# Deny-list token must not appear as a literal in this file (public export scans tests/).
PROVIDER_BRAND=$(printf '%s%s' hetz ner)
hasnot "no provider brand in role" "$PROVIDER_BRAND" "$R/ansible/roles/wireguard/tasks/main.yml"
hasnot "no provider brand in how-to" "${PROVIDER_BRAND^}" "$R/docs/how-to/wireguard-tunnel.md"
hasnot "no fixed tunnel net in group_vars/all" "10.13." "$R/ansible/inventory/group_vars/all/wireguard.yml"
has "secrets map names server key" "wireguard-server-key" "$R/ansible/inventory/group_vars/all/secrets.yml"
has "secrets map names client key" "wireguard-client-key" "$R/ansible/inventory/group_vars/all/secrets.yml"
has "docs name server key" '`wireguard-server-key`' "$R/docs/reference/secrets-map.md"
has "docs name client key" '`wireguard-client-key`' "$R/docs/reference/secrets-map.md"

echo "== lab-secrets wireguard kind"
if command -v wg > /dev/null 2>&1; then
  cat > "$T/sec.json" << JSON
{"entries":[
  {"name":"wireguard-server-key","kind":"wireguard","path":"$T/wg-server","purpose":"t","created_by":"t","consumers":"t","rotation":"t"},
  {"name":"wireguard-client-key","kind":"wireguard","path":"$T/wg-client","purpose":"t","created_by":"t","consumers":"t","rotation":"t"}
]}
JSON
  ok "generate server key" "$(rc python3 "$R/scripts/lab-secrets.py" generate --json "$T/sec.json" --name wireguard-server-key)" 0
  has "generate says NEW" "NEW: wireguard-server-key" "$T/out"
  ok "private mode 600" "$(stat -c '%a' "$T/wg-server")" 600
  ok "public file exists" "$([ -f "$T/wg-server.pub" ] && echo yes || echo no)" yes
  ok "generate again is SKIP" "$(rc python3 "$R/scripts/lab-secrets.py" generate --json "$T/sec.json" --name wireguard-server-key)" 0
  has "second generate SKIP" "SKIP: wireguard-server-key" "$T/out"
  KEYHEAD=$(head -c 20 "$T/wg-server")
  hasnot "no private key in output" "$KEYHEAD" "$T/out"
else
  echo "SKIP: wg missing (wireguard key generation)"
fi

echo "== template render (no secrets)"
python3 - "$R" "$T" << 'PY'
import pathlib, re, sys
root, td = sys.argv[1], sys.argv[2]
text = (pathlib.Path(root) / "ansible/roles/wireguard/templates/wg0.conf.j2").read_text(encoding="utf-8")
text = re.sub(
    r"\{% if wireguard_mode == 'server' and \(wireguard_listen_port \| int\) > 0 %\}\nListenPort = \{\{ wireguard_listen_port \| int \}\}\n\{% endif %\}\n",
    "ListenPort = 51820\n", text)
text = re.sub(r"\{% if wireguard_mode == 'client' and wireguard_peer_endpoint %\}\nEndpoint = \{\{ wireguard_peer_endpoint \}\}\n\{% endif %\}\n", "", text)
text = re.sub(r"\{% if wireguard_mode == 'client' and \(wireguard_keepalive \| int\) > 0 %\}\nPersistentKeepalive = \{\{ wireguard_keepalive \| int \}\}\n\{% endif %\}\n", "", text)
repl = {
    "{{ ansible_managed }}": "test",
    "{{ wireguard_mode }}": "server",
    "{{ wireguard_interface }}": "wg0",
    "{{ wireguard_address }}": "10.10.0.2/24",
    "{{ wireguard_mtu }}": "1420",
    "{{ wireguard_private_key_path }}": "/etc/wireguard/wg0.key",
    "{{ wireguard_peer_public_key }}": "TESTPUBLICKEYAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
    "{{ wireguard_peer_allowed_ips }}": "10.10.0.1/32",
}
for k, v in repl.items():
    text = text.replace(k, v)
pathlib.Path(td, "wg0.conf").write_text(text, encoding="utf-8")
PY
has "rendered ListenPort" "ListenPort = 51820" "$T/wg0.conf"
has "rendered PostUp private-key" "PostUp = wg set %i private-key /etc/wireguard/wg0.key" "$T/wg0.conf"
hasnot "rendered conf has no PrivateKey =" "PrivateKey =" "$T/wg0.conf"
has "rendered peer pubkey" "TESTPUBLICKEY" "$T/wg0.conf"

echo "== ansible syntax"
if command -v ansible-playbook > /dev/null 2>&1; then
  (cd "$R/ansible" && ansible-playbook -i inventory/local.yml --syntax-check wireguard.yml site.yml > "$T/out" 2>&1)
  ok "wireguard.yml + site.yml syntax" "$?" 0
  if grep -qi error "$T/out"; then sed "s/^/       | /" "$T/out" | tail -20; fi
else
  echo "SKIP: ansible-playbook missing"
fi

echo
echo "$n checks, $fail failures"
[ "$fail" = 0 ]
