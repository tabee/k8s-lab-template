#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
# Offline readiness regression: no VM or cluster is contacted.
# Variables below are consumed by the extracted production functions.
# shellcheck disable=SC2034
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
python3 - "$R/scripts/lab.sh" "$T/functions" <<'PYCODE'
import re, sys
text = open(sys.argv[1]).read()
names = ["cmd_export", "cluster_ready", "wait_for_argo", "wait_for_db", "argo_status"]
with open(sys.argv[2], "w") as out:
    for name in names:
        match = re.search(r"^" + name + r"\(\).*?^}", text, re.M | re.S)
        assert match, name
        out.write(match.group() + "\n")
assert 'phase "Cluster ready after export" cluster_ready' in text
assert 'phase "Cluster ready (Node, Argo CD, databases)" cluster_ready' in text
PYCODE
# shellcheck disable=SC1091
source "$T/functions"
L_wait_argo=1
POLL=0
ARGO_SKIP=
MODE=success
calls="$T/calls"
kubectl() {
  printf '%s\n' "$*" >> "$calls"
  case "$*" in
    *'get nodes'*)
      if [ "$MODE" = api-fail ]; then return 1; fi
      if [ ! -f "$T/api-seen" ]; then touch "$T/api-seen"; return 1; fi ;;
    *'wait --for=condition=Ready'*) [ "$MODE" != node-fail ] ;;
    *applications.argoproj.io*) printf 'root Synced/Healthy\n' ;;
    *clusters.postgresql.cnpg.io*) printf 'gitea/gitea-db=Cluster in healthy state\n' ;;
    *) return 1 ;;
  esac
}
cluster_ready > "$T/success"
python3 - "$calls" <<'PYCODE'
import sys
calls = open(sys.argv[1]).read().splitlines()
assert sum("get nodes" in x for x in calls) == 2
indices = [next(i for i, x in enumerate(calls) if needle in x) for needle in
           ["wait --for=condition=Ready", "applications.argoproj.io", "clusters.postgresql.cnpg.io"]]
assert indices == sorted(indices)
assert all("--request-timeout=" in x for x in calls)
PYCODE
printf 'OK API retry, Node Ready, Argo CD and CNPG ordering\n'
MODE=node-fail
: > "$calls"
if cluster_ready > "$T/node" 2>&1; then echo 'FAIL node failure accepted'; exit 1; fi
if grep -q applications.argoproj.io "$calls"; then echo 'FAIL continued after node failure'; exit 1; fi
printf 'OK node failure stops readiness\n'
MODE=api-fail
if cluster_ready > "$T/api" 2>&1; then echo 'FAIL API timeout accepted'; exit 1; fi
grep -q 'API server not reachable' "$T/api"
printf 'OK API outage times out with a diagnostic\n'

# Exercise the export restart path with local files and fake virsh.
MODE=success
VM=test-vm
VM_RESTART=0
LIVE=0
L_export_dir="$T/exports"
L_disk_gb=1
VIRSH=(virsh)
log_start() { :; }
cfg_load() { :; }
load_values() { :; }
maintenance_begin() { :; }
wal_ready() { :; }
phase() { shift; "$@"; }
die() { echo "$*" >&2; return 1; }
vm_state() { if [ -f "$T/stopped" ]; then echo 'shut off'; else echo running; fi; }
virsh() {
  case "$1" in
    domblklist) echo "file disk vda $T/disk" ;;
    vol-info) echo 'Allocation: 1' ;;
    shutdown) touch "$T/stopped" ;;
    start) rm "$T/stopped"; echo restart >> "$calls" ;;
    dumpxml) echo '<domain/>' ;;
    *) return 1 ;;
  esac
}
qemu_img_convert() { printf image > "$2"; }
qemu-img() { return 0; }
: > "$calls"
cmd_export > "$T/export"
python3 - "$calls" <<'PYCODE'
import sys
calls = open(sys.argv[1]).read()
assert calls.index("restart") < calls.index("get nodes")
assert "clusters.postgresql.cnpg.io" in calls
PYCODE
[ "$VM_RESTART" = 0 ]
printf 'OK export restarts VM before waiting for cluster readiness\n'
