#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
# Offline tests of the safety net around rebuild --restore (third real run, 2026-11-03):
#   - the group_vars knobs (one place: ansible/inventory/group_vars/all/restore.yml),
#   - the marker that recover-files.yml --tags verify removes as its very last task,
#   - the skip of snapshots of an EMPTY volume in tasks/recover-restore-one.yml.
# The guard itself (scripts/lab-backup-fresh.py --guard) is tested in backup-fresh-tests.sh and lab-sh-tests.sh.
# The templates under test are the REAL tasks, read from the YAML files and run by ansible-playbook on localhost.
# No cluster, no network, no secret.
# Usage: bash tests/restore-guard-tests.sh [repo root]
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
R=$(cd "${1:-$HERE/..}" && pwd -P)
fail=0
n=0
ok() { n=$((n + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else echo "FAIL $1 (actual '$2', expected '$3')"; fail=$((fail + 1)); fi; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

if ! command -v ansible-playbook > /dev/null 2>&1 || ! python3 -c 'import yaml' 2> /dev/null; then
  echo "SKIP restore-guard-tests: ansible-playbook or PyYAML missing"
  exit 0
fi

echo "-- group_vars: one place for the knobs"
python3 - "$R" << 'PY'
import sys, yaml
R = sys.argv[1]
rs = yaml.safe_load(open(R + "/ansible/inventory/group_vars/all/restore.yml"))
assert rs["restore_plugin_timeout_min"] >= 20, rs["restore_plugin_timeout_min"]
assert rs["restore_plugin_delay"] > 0
assert rs["restore_plugin_nudge_after_min"] < rs["restore_plugin_timeout_min"]
assert rs["restore_plugin_pod_grace_min"] < rs["restore_plugin_timeout_min"]
assert rs["restore_state_file"].endswith("/restore-in-progress.json")
lab = yaml.safe_load(open(R + "/ansible/inventory/group_vars/all/lab.yml"))
assert lab["lab_values"]["restore_state_file"] == "{{ restore_state_file }}"
PY
ok "restore.yml holds the budget and the marker path, lab_values passes the marker path to lab.sh" "$?" 0
ok "the timeout is defined in exactly one place" "$(grep -rn "restore_plugin_timeout_min *:" "$R/ansible" | wc -l | tr -d ' ')" 1

# run_tasks TASKS.json [ansible args]: a playbook with these tasks against localhost; log in $T/log
run_tasks() {
  local tasks=$1
  shift
  python3 - "$T/pb.yml" "$tasks" << 'PY'
import json, sys, yaml
tasks = json.load(open(sys.argv[2]))
yaml.safe_dump([{"hosts": "localhost", "connection": "local", "gather_facts": False, "tasks": tasks}], open(sys.argv[1], "w"))
PY
  (cd "$T" && ANSIBLE_FORCE_COLOR=0 ANSIBLE_LOCALHOST_WARNING=False ANSIBLE_INVENTORY_UNPARSED_WARNING=False \
    ansible-playbook -i localhost, "$T/pb.yml" "$@" > "$T/log" 2>&1)
}

echo "-- the marker goes away with the very last task of the verify play"
python3 - "$R" "$T" << 'PY'
import json, sys, yaml
R, T = sys.argv[1], sys.argv[2]
plays = yaml.safe_load(open(R + "/ansible/recover-files.yml"))
last = plays[-1]
assert "verify" in json.dumps(last.get("tags", [])) or all("verify" in (t.get("tags") or last.get("tags") or []) for t in last["tasks"]), "last play is not the verify play"
task = last["tasks"][-1]
assert task["name"] == "Remove the marker of the unfinished restore", task["name"]
assert task["ansible.builtin.file"]["state"] == "absent"
json.dump([task], open(T + "/marker-task.json", "w"))
PY
ok "the last task of the last (verify) play removes the marker" "$?" 0
printf '{"started": "x"}' > "$T/marker.json"
run_tasks "$T/marker-task.json" -e restore_state_file="$T/marker.json"
ok "the task removes an existing marker" "$([ -e "$T/marker.json" ] && echo present || echo gone)" gone
run_tasks "$T/marker-task.json" -e restore_state_file="$T/marker.json"
ok "the task is idempotent without a marker" "$?" 0
python3 - "$R" << 'PY'
import sys, yaml
plays = yaml.safe_load(open(sys.argv[1] + "/ansible/recover-files.yml"))
# no other play or task of recover-files.yml may touch the marker
n = sum(1 for p in plays for t in p.get("tasks", []) if "restore_state_file" in str(t))
assert n == 1, n
PY
ok "only that one task touches the marker" "$?" 0

echo "-- empty snapshots are no restore source"
python3 - "$R" "$T" << 'PY'
import json, sys, yaml
R, T = sys.argv[1], sys.argv[2]
def walk(x):
    if isinstance(x, dict):
        if x.get("name") == "Skip snapshots of an empty volume":
            yield x
        for v in x.values():
            yield from walk(v)
    elif isinstance(x, list):
        for v in x:
            yield from walk(v)
tasks = list(walk(yaml.safe_load(open(R + "/ansible/tasks/recover-restore-one.yml"))))
assert len(tasks) == 1, len(tasks)
task = dict(tasks[0])
task.pop("when", None)
check = {"name": "Show the kept ids", "ansible.builtin.copy": {
    "dest": T + "/kept.json", "content": "{{ recover_restic_snaps | map(attribute='id') | list | to_json }}"}}
json.dump([task, check], open(T + "/skip-task.json", "w"))
PY
ok "the skip task exists exactly once" "$?" 0
kept() { # kept SNAPSHOT-JSON-LIST -> kept ids
  run_tasks "$T/skip-task.json" -e "{\"recover_restic_all\": $1}" || { echo "ansible-failed"; return; }
  cat "$T/kept.json"
}
ok "a snapshot with files is kept, an empty one is dropped" \
  "$(kept '[{"id":"a","summary":{"total_files_processed":12}},{"id":"b","summary":{"total_files_processed":0}}]')" '["a"]'
ok "a snapshot without summary (old restic) counts as unknown and is kept" \
  "$(kept '[{"id":"old"},{"id":"b","summary":{"total_files_processed":0}}]')" '["old"]'
ok "all empty: nothing is kept" "$(kept '[{"id":"b","summary":{"total_files_processed":0}}]')" '[]'
ok "no snapshot: nothing is kept, no error" "$(kept '[]')" '[]'
ok "order is kept (the newest-first sort comes later)" \
  "$(kept '[{"id":"x","summary":{"total_files_processed":1}},{"id":"y","summary":{"total_files_processed":2}}]')" '["x", "y"]'
ok "a summary without the counter is kept" "$(kept '[{"id":"s","summary":{"files_new":0}}]')" '["s"]'

echo
echo "$n checks, $fail failures"
[ "$fail" = 0 ]
