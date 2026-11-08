#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
# Structure of the pause and the PVC delete in ansible/recover-files.yml (first real runs of rebuild --restore).
# The behaviour is tested in tests/recover-sim-tests.sh. No cluster, no secret.
# Usage: bash tests/recover-pause-tests.sh [repo root]
set -u
R=$(cd "${1:-$(dirname "${BASH_SOURCE[0]}")/..}" && pwd -P)
fail=0
n=0
ok() { n=$((n + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else echo "FAIL $1 (actual '$2', expected '$3')"; fail=$((fail + 1)); fi; }

python3 - "$R" << 'PY'
import sys, yaml
R = sys.argv[1]
T = R + "/ansible/tasks/"
def load(n):
    return yaml.safe_load(open(T + n))
def flat(tasks):
    for x in tasks:
        yield x
        for k in ("block", "rescue", "always"):
            for y in flat(x.get(k, [])):
                yield y
def text(tasks):
    return yaml.dump(tasks)
for n in ("recover-pause-one.yml", "recover-quiesce-one.yml", "recover-free-pvc-one.yml", "recover-wait-op.yml", "recover-assert-paused.yml", "recover-restore-one.yml"):
    assert isinstance(load(n), list), n
# pause: automated off, then wait for the operation, then a one-off sync, then quiesce, in this order
p = load("recover-pause-one.yml")
t = text(p)
i = [t.index(s) for s in ("/spec/syncPolicy/automated", "recover-wait-op.yml", "operation:", "recover-quiesce-one.yml")]
assert i == sorted(i), "pause order: automated off, wait for the operation, one-off sync, quiesce: %s" % i
assert "Succeeded" in t, "the one-off sync only runs when no sync has succeeded"
assert "k8s_scale" not in t, "scaling lives in recover-quiesce-one.yml, so the pause cannot scale before the sync"
# quiesce: scale, wait for no pod on the claim, name the pods, wait for the workload pods
q = text(load("recover-quiesce-one.yml"))
assert "k8s_scale" in q and "replicas: 0" in q
assert "persistentVolumeClaim" in q and "target.claim" in q, "no pod may mount THE CLAIM (not only the label)"
assert "is still mounted by" in q and "metadata.name" in q, "the pods are named"
# free the PVC: quiesce, wait for Terminating, delete
f = text(load("recover-free-pvc-one.yml"))
j = [f.index(s) for s in ("recover-quiesce-one.yml", "deletionTimestamp", "state: absent")]
assert j == sorted(j), "free-pvc order: quiesce, wait for Terminating, delete: %s" % j
r = text(load("recover-restore-one.yml"))
assert "recover-free-pvc-one.yml" in r and "state: absent\n    api_version: v1\n    kind: PersistentVolumeClaim" not in r.replace("- ", "  "), "restore does not delete the PVC itself"
assert r.index("recover-free-pvc-one.yml") < r.index("Recreate the PVC"), "free before recreate"
# the restore play refuses while auto-sync is on, before the loop
plays = yaml.safe_load(open(R + "/ansible/recover-files.yml"))
rp = next(x for x in plays if "restore" in (x.get("tags") or []))
names = [x.get("ansible.builtin.include_tasks") for x in rp["tasks"]]
assert "tasks/recover-assert-paused.yml" in names and names.index("tasks/recover-assert-paused.yml") < names.index("tasks/recover-restore-one.yml")
a = text(load("recover-assert-paused.yml"))
assert "argocd_root_app_name" in a and "recover_targets" in a and "--tags pause" in a
PY
ok "pause: automated off, operation wait, one-off sync, quiesce; restore: guard, quiesce, Terminating wait, delete" "$?" 0

python3 - "$R" << 'PY'
import re, sys
R = sys.argv[1]
s = open(R + "/scripts/lab.sh").read()
assert "RECOVER_NEXT=pause,restore,resume,verify" in s
assert re.search(r'RECOVER_NEXT=restore,resume,verify\n\s+ARGO_SKIP=', s), "after the pause the next part is the restore"
assert re.search(r'ans recover-files.yml --tags restore\n\s+RECOVER_NEXT=resume,verify', s), "after the restore the next part is the resume"
assert "--tags $RECOVER_NEXT" in s, "cleanup prints the exact command"
PY
ok "lab.sh names the exact recovery command for the stage where it stopped" "$?" 0

for d in "$R/docs/how-to/rebuild.md" "$R/docs/how-to/troubleshooting.md" "$R/docs/concepts/decisions/0018-recover-from-backup.md"; do
  grep -Fq 'pvc-protection' "$d" && grep -Fq -- '--tags' "$d"; ok "docs describe the PVC in Terminating: $(basename "$d")" "$?" 0
done
grep -Fq -- '--tags restore,resume,verify' "$R/docs/how-to/rebuild.md"; ok "rebuild.md names the exact command after a failed restore" "$?" 0
(cd "$R/ansible" && ansible-playbook --syntax-check recover-files.yml > /dev/null 2>&1); ok "recover-files.yml passes --syntax-check" "$?" 0

echo
echo "$n checks, $fail failures"
[ "$fail" = 0 ]
