#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
# Tests for the break-glass logic in the Ansible files (issue 11), without a cluster:
#   1. preflight-sops.yml (role argocd_bootstrap): the last recipient must not be in the cluster key file
#   2. verify-ksops.yml, last section: cluster key file vs .sops.yaml recipients, through a fake
#      kubernetes.core.k8s_exec that "execs" grep on a local file (the pod's /sops-age/keys.txt)
# Needs: ansible-playbook, age-keygen. Usage: bash tests/break-glass-ansible-tests.sh [repo root]
set -u
export PYTHONDONTWRITEBYTECODE=1
R=$(cd "${1:-$(dirname "${BASH_SOURCE[0]}")/..}" && pwd -P)
for tool in ansible-playbook age-keygen; do
  command -v "$tool" > /dev/null 2>&1 || { echo "SKIPPED: $tool is missing"; exit 0; }
done
mkdir -p "$HOME/.cache/lab-sh-tests"
T=$(mktemp -d -p "$HOME/.cache/lab-sh-tests")
TMPPB="$R/ansible/.preflight-bg-test.yml $R/ansible/.verify-ksops-bg-test.yml"
# shellcheck disable=SC2064
trap "rm -rf '$T'; rm -f $TMPPB" EXIT
fail=0
n=0
ok() { n=$((n + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else echo "FAIL $1 (is '$2', want '$3')"; fail=$((fail + 1)); fi; }

mkkey() { age-keygen -o "$1" 2> /dev/null; chmod 600 "$1"; }
pub() { age-keygen -y "$1"; }
mkkey "$T/online.txt"
mkkey "$T/other.txt"
mkkey "$T/bg.txt"
ON=$(pub "$T/online.txt")
BG=$(pub "$T/bg.txt")
write_sops() { printf 'creation_rules:\n  - path_regex: ^secrets/.*\\.sops\\.yaml$\n    age: %s\n' "$1" > "$T/sops.yaml"; }

# ---------- 1. preflight
cat > "$R/ansible/.preflight-bg-test.yml" <<YML
- hosts: localhost
  connection: local
  gather_facts: false
  vars:
    argocd_sops_config_path: $T/sops.yaml
  tasks:
    - ansible.builtin.include_tasks: $R/ansible/roles/argocd_bootstrap/tasks/preflight-sops.yml
YML
pre() { # pre KEYFILE ; output in $T/pre.out
  (cd "$R/ansible" && ANSIBLE_LOCALHOST_WARNING=False ANSIBLE_INVENTORY_UNPARSED_WARNING=False ansible-playbook -e "argocd_sops_age_key_path=$1" .preflight-bg-test.yml > "$T/pre.out" 2>&1)
}
echo "-- preflight-sops.yml"
write_sops "$ON"
pre "$T/online.txt"; ok "one recipient, online key: passes" "$?" 0
write_sops "$ON,$BG"
pre "$T/online.txt"; ok "two recipients, online key in the file: passes" "$?" 0
grep -A2 'TASK \[.*Break-glass recipient (last)' "$T/pre.out" | grep -q '^ok:'; ok "two recipients: the break-glass assertion ran and passed" "$?" 0
pre "$T/bg.txt"; ok "two recipients, the file holds the break-glass key: fails" "$?" 2
grep -q 'offline break-glass' "$T/pre.out"; ok "failure names the offline break-glass key" "$?" 0
grep -q 'AGE-SECRET-KEY' "$T/pre.out"; ok "failure output shows no private key" "$?" 1
cat "$T/online.txt" > "$T/both.txt"; grep -v '^#' "$T/bg.txt" >> "$T/both.txt"; chmod 600 "$T/both.txt"
pre "$T/both.txt"; ok "the file holds online and break-glass key: fails" "$?" 2
write_sops "$ON, $BG"
pre "$T/online.txt"; ok "recipients with a space after the comma: passes" "$?" 0
printf 'creation_rules:\n  - path_regex: ^secrets/.*\\.sops\\.yaml$\n    age: >-\n      %s,\n      %s\n' "$ON" "$BG" > "$T/sops.yaml"
pre "$T/online.txt"; ok "folded age: line: passes" "$?" 0
pre "$T/bg.txt"; ok "folded age: line, break-glass key in the file: fails" "$?" 2
write_sops "$ON,$ON"
pre "$T/online.txt"; ok "the same recipient twice counts as one (no break-glass check): passes" "$?" 0

# ---------- 2. verify-ksops.yml, last section
echo "-- verify-ksops.yml (break-glass section, fake k8s_exec)"
C=$T/coll/ansible_collections/kubernetes/core
mkdir -p "$C/plugins/modules" "$C/meta"
cat > "$C/meta/runtime.yml" <<'YML'
---
requires_ansible: ">=2.14"
action_groups:
  k8s:
    - k8s_exec
YML
cat > "$C/plugins/modules/k8s_exec.py" <<'PY'
#!/usr/bin/python
# Test double: runs the grep of the command against the local file in FAKE_POD_KEYS.
import os
import re
import subprocess
from ansible.module_utils.basic import AnsibleModule


def main():
    m = AnsibleModule(argument_spec=dict(namespace=dict(), pod=dict(), container=dict(), command=dict(required=True), kubeconfig=dict()))
    cmd = m.params["command"]
    keys = os.environ["FAKE_POD_KEYS"]
    cmd = re.sub(r"/sops-age/keys\.txt$", keys, cmd)
    r = subprocess.run(["bash", "-c", cmd], capture_output=True, text=True, check=False)
    m.exit_json(changed=False, stdout=r.stdout, stderr=r.stderr, rc=r.returncode, return_code=r.returncode)


main()
PY
cat > "$T/ver-head.py" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
marker = "    # ---------- Break-glass recipient (issue 11, optional) ----------"
assert src.count(marker) == 1
head, tail = src.split(marker)
head = head[: head.index("  tasks:\n") + len("  tasks:\n")]
open(sys.argv[2], "w", encoding="utf-8").write(head + marker + tail)
PY
python3 "$T/ver-head.py" "$R/ansible/verify-ksops.yml" "$R/ansible/.verify-ksops-bg-test.yml"
printf '{"verify_rs_pods": {"resources": [{"metadata": {"name": "argocd-repo-server-test"}}]}}' > "$T/ev.json"
ver() { # ver KEYFILE_IN_THE_POD ; output in $T/ver.out
  (cd "$R/ansible" && FAKE_POD_KEYS=$1 ANSIBLE_COLLECTIONS_PATH=$T/coll ANSIBLE_LOCALHOST_WARNING=False ANSIBLE_INVENTORY_UNPARSED_WARNING=False \
    ansible-playbook -e "argocd_sops_config_path=$T/sops.yaml" -e "@$T/ev.json" .verify-ksops-bg-test.yml > "$T/ver.out" 2>&1)
}
write_sops "$ON"
ver "$T/online.txt"; ok "one recipient: passes" "$?" 0
grep -q 'no break-glass key yet' "$T/ver.out"; ok "one recipient: prints the note" "$?" 0
write_sops "$ON,$BG"
ver "$T/online.txt"; ok "two recipients, pod has only the online key: passes" "$?" 0
grep -q 'cluster secret holds only the online key' "$T/ver.out"; ok "two recipients: success message" "$?" 0
ver "$T/bg.txt"; ok "pod has the break-glass key: fails" "$?" 2
ver "$T/both.txt"; ok "pod has both keys: fails" "$?" 2
ver "$T/other.txt"; ok "pod has a key that is not the first recipient: fails" "$?" 2
printf 'AGE-SECRET-KEY-1NOCOMMENTLINE\n' > "$T/nocomment.txt"
ver "$T/nocomment.txt"; ok "pod key file without the public key comment: fails" "$?" 2
grep -q 'AGE-SECRET-KEY' "$T/ver.out"; ok "the failure output shows no private key" "$?" 1
write_sops "$ON,$(pub "$T/other.txt"),$BG"
ver "$T/online.txt"; ok "three recipients, break-glass last, pod has the online key: passes" "$?" 0
grep -q 'finish the rotation' "$T/ver.out"; ok "three recipients: rotation note" "$?" 0
echo
echo "$n checks, $fail failures"
[ "$fail" -eq 0 ]
