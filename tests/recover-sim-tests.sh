#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
# Behaviour test of the pause and the PVC delete in ansible/recover-files.yml (issue: first real
# `lab.sh rebuild --restore`, task "Delete the file PVC from the new disk" hung in Terminating because
# the pause ran before the Argo CD sync had created the Deployment). It runs the REAL playbook against
# stub modules (tests/recover-sim/) that model Argo CD, Deployments, pods and pvc-protection in memory.
# No cluster, no network, no secret.
# Usage: bash tests/recover-sim-tests.sh [repo root] [--expect-old]
#   --expect-old: run it against a tree without the fix (the cases that need the fix then FAIL).
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
R=$(cd "${1:-$HERE/..}" && pwd -P)
SIM=$HERE/recover-sim
fail=0
n=0
ok() { n=$((n + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else echo "FAIL $1 (actual '$2', expected '$3')"; fail=$((fail + 1)); fi; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

if ! command -v ansible-playbook > /dev/null 2>&1 || ! python3 -c 'import yaml' 2> /dev/null; then
  echo "SKIP recover-sim-tests: ansible-playbook or PyYAML missing"
  exit 0
fi

# sim SCENARIO TAGS -> exit code in $rc, log in $T/log, state in $T/state.json
sim() {
  python3 "$SIM/engine.py" init "$1" "$T/state.json"
  (
    cd "$R/ansible" || exit 99
    SIM_STATE=$T/state.json SIM_DIR=$SIM ANSIBLE_COLLECTIONS_PATH=$SIM/collections ANSIBLE_FORCE_COLOR=0 \
      ANSIBLE_LOCALHOST_WARNING=False ANSIBLE_INVENTORY_UNPARSED_WARNING=False \
      timeout 300 ansible-playbook recover-files.yml --tags "$2" \
      -e recover_settle=0 -e recover_op_delay=0 -e recover_poll=0 -e recover_op_retries=40 -e recover_pod_retries=10 > "$T/log" 2>&1
  )
  rc=$?
}
events() { python3 "$SIM/engine.py" events "$T/state.json"; }
has() { events | grep -c -- "$1"; }
logs() { grep -c -- "$1" "$T/log"; }
# an event or log line is "present" (1) or "absent" (0)
yes() { [ "$1" -gt 0 ] && echo present || echo absent; }

old=0
[ "${2:-}" = "--expect-old" ] && old=1
check() { # check NAME ACTUAL EXPECTED_NEW EXPECTED_OLD
  if [ $old = 1 ]; then ok "$1 (old tree)" "$2" "${4:-$3}"; else ok "$1" "$2" "$3"; fi
}

# 1. The real run: the first sync of the apps is still running when the pause starts. The Deployment
#    does not exist at that moment, and the sync creates it later with replicas 1.
sim inflight pause,restore
check "inflight: pause and restore reach the end of the simulated part" "$(yes "$(logs 'Module failed: SIM-STOP')")" present absent
check "inflight: the PVC never hangs in Terminating" "$(yes "$(has 'Terminating because')")" absent present
check "inflight: the PVCs were recreated" "$(has 'recreated')" 1 0
check "inflight: no sync created a Deployment after the pause scaled it down" "$(python3 "$SIM/engine.py" get "$T/state.json" deploys | python3 -c 'import json,sys; print(sorted(d["replicas"] for d in json.load(sys.stdin).values()))')" "[0, 0]" "[1, 1]"

# 2. The controller has not started the first sync at all: the pause must sync once by hand,
#    otherwise there is no ObjectStore and the databases never recover.
sim notstarted pause,restore
check "notstarted: one-off sync of gitea and matrix" "$(has 'one-off sync of')" 2 0
check "notstarted: the one-off sync carries prune, options and retry of the app" "$(has '"retry": {"limit": 10}')" 2 0
check "notstarted: restore reaches the simulated end" "$(yes "$(logs 'Module failed: SIM-STOP')")" present present

# 3. Everything is synced and running before the pause: no one-off sync, the workload is scaled down.
sim synced pause,restore
check "synced: no needless one-off sync" "$(yes "$(has 'one-off sync of')")" absent absent
check "synced: restore reaches the simulated end" "$(yes "$(logs 'Module failed: SIM-STOP')")" present present
check "synced: no Terminating PVC" "$(yes "$(has 'Terminating because')")" absent absent

# 4. The state of the first real run: apps already paused, Gitea running and mounting the PVC.
#    The restore alone must still get through (scale to zero, wait, delete).
sim live restore
check "live state: restore scales the workload down and gets through" "$(yes "$(logs 'Module failed: SIM-STOP')")" present absent
check "live state: the PVC delete does not hang" "$(yes "$(has 'Terminating because')")" absent present

# 5. The PVC is already Terminating (an earlier attempt hung): wait for it, then continue.
sim terminating restore
check "terminating PVC: restore waits for it and continues" "$(yes "$(logs 'Module failed: SIM-STOP')")" present absent

# 6. A pod that is not ours mounts the claim: stop and name it.
sim rogue restore
check "rogue pod: restore stops" "$([ $rc -ne 0 ] && echo failed)" failed failed
check "rogue pod: the message names the pod" "$(yes "$(logs 'mounted by .*rogue')")" present absent

# 7. Auto-sync is still on: the restore refuses before it deletes anything.
sim unpaused restore
check "unpaused: restore refuses" "$(yes "$(logs 'Auto-sync is still on for')")" present absent
check "unpaused: nothing was deleted" "$(yes "$(has 'pvc .* gone')")" absent absent

echo "$n checks, $fail failed"
[ $fail -eq 0 ]
