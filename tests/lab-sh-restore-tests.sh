#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
# Restore, source trust and mirror tests for scripts/lab.sh; no live tools or cluster.
# Usage: bash tests/lab-sh-restore-tests.sh [repo root]
# shellcheck disable=SC2016
set -u
R=$(cd "${1:-$(dirname "${BASH_SOURCE[0]}")/..}" && pwd -P)
fail=0
n=0
# shellcheck source=tests/helpers/lab-sh-sandbox.sh
source "$R/tests/helpers/lab-sh-sandbox.sh"

echo "== rebuild --restore: full bucket, double confirmation, git stays initdb (stubs)"
(cd "$T/repo" && git checkout -q -- . && git clean -fd -e infra/envs/local/lab.local.yaml >/dev/null)
git -C "$T/repo" config user.name t
git -C "$T/repo" config user.email t@t
vm running; : > "$S/rustfs_up"; fresh
printf 'x\n' >> "$T/repo/gitops/README.md"
lab rebuild --restore <<< "$SUDO"; ok "restore with a dirty tree: exit 1" "$?" 1
has "dirty tree is refused" "Worktree is not clean" "$T/out"
hasnot "dirty tree did not destroy" "tofu destroy" "$S/calls"
(cd "$T/repo" && git checkout -q -- gitops/README.md)
lab rebuild --restore --no-export < /dev/null; ok "restore --no-export: exit 1" "$?" 1
has "restore --no-export is refused" "--no-export does not apply to rebuild --restore" "$T/out"
hasnot "restore --no-export did not render" "RENDER" "$T/out"
mkdir -p "$H/data/vm-export"
EXP="$H/data/vm-export/k3s-lab-before-drill-test.qcow2"
printf 'qcow2\n' > "$EXP"
printf 'disk k3s-lab-before-drill-test.qcow2\n' > "$EXP.sha256"
printf '<domain/>\n' > "${EXP%.qcow2}.xml"
mkdir -p "$H/data/no-export"
find "$H/data/vm-export" -maxdepth 1 -type f -exec mv {} "$H/data/no-export/" \;
: > "$S/bucket_used"; fresh
lab rebuild --restore <<< "$SUDO"$'restore\nk3s-lab\n'; ok "restore without an export: exit 1" "$?" 1
has "restore without an export names the export" "Run 'bash scripts/lab.sh export' first" "$T/out"
hasnot "restore without an export did not destroy" "tofu destroy" "$S/calls"
mv "$H/data/no-export/"* "$H/data/vm-export/"
rm -f "$S/bucket_used"; fresh
lab rebuild --restore <<< "$SUDO"$'restore\nk3s-lab\n'; ok "restore with an empty bucket: exit 1" "$?" 1
has "empty bucket points at up" "bash scripts/lab.sh up" "$T/out"
hasnot "empty bucket did not destroy" "tofu destroy" "$S/calls"
: > "$S/bucket_used"; fresh
lab rebuild --restore <<< "$SUDO"$'restore\nk3s-lab\n'; ok "restore without a sealed prefix: exit 1" "$?" 1
has "missing prefix is a failure" "No sealed archive" "$T/out"
hasnot "missing prefix did not destroy" "tofu destroy" "$S/calls"
for p in db-lab/pg-lab-r3 gitea/gitea-db-r3 matrix/matrix-db-r3 keycloak/keycloak-db-r3; do
  dir="$H/backups/cnpg-k3s-lab/$p"
  wal=000000010000000000000005
  mkdir -p "$dir/base/20261101T010101" "$dir/wals/${wal:0:16}"
  printf '%s\n' 'end_wal=None' 'status=STARTED' "end_wal=$wal" 'status=DONE' \
    > "$dir/base/20261101T010101/backup.info"
  printf 'seg\n' > "$dir/wals/${wal:0:16}/$wal.gz"
done
fresh
export LAB_RESTORE_GUARD_FORCE=1 # these tests are about the questions; the guard has its own tests below
lab rebuild --restore --yes <<< "$SUDO"; ok "restore --yes without an answer: exit 0" "$?" 0
has "restore --yes still asks" "Aborted (nothing changed)" "$T/out"
hasnot "restore --yes did not destroy" "tofu destroy" "$S/calls"
ok "restore --yes did not rewrite a serverName" "$(grep -c 'serverName: pg-lab-r4' "$T/repo/gitops/workloads/db-lab/cluster.yaml")" 0
lab rebuild --restore <<< "$SUDO"$'nope\nk3s-lab\n'; has "restore wrong word aborts" "Aborted" "$T/out"
lab rebuild --restore <<< "$SUDO"$'restore\nfalsch\n'; has "restore wrong VM name aborts" "Aborted" "$T/out"
hasnot "wrong answers did not destroy" "tofu destroy" "$S/calls"
unset LAB_RESTORE_GUARD_FORCE
ok "wrong answers wrote no restore marker" "$([ -e "$H/restore-in-progress.json" ] && echo present || echo none)" none
write_fresh_api() {
  python3 - "$S" << 'PY'
import json, os, sys
state = sys.argv[1]
def dump(name, obj):
    json.dump(obj, open(os.path.join(state, name), "w"))
clusters, backups, scheduled = [], [], []
for ns, name in (("db-lab", "pg-lab"), ("gitea", "gitea-db"), ("keycloak", "keycloak-db"), ("matrix", "matrix-db")):
    clusters.append({"metadata": {"namespace": ns, "name": name}, "status": {"currentPrimary": name + "-1"}})
    backups.append({
        "metadata": {"namespace": ns, "name": "daily"},
        "spec": {"cluster": {"name": name}},
        "status": {"phase": "completed", "stoppedAt": "2099-01-01T00:00:00Z",
                   "endWal": "000000010000000000000005"},
    })
    scheduled.append({
        "metadata": {"namespace": ns, "name": name + "-daily"},
        "spec": {"cluster": {"name": name}, "method": "plugin",
                 "pluginConfiguration": {"name": "barman-cloud.cloudnative-pg.io"}},
    })
dump("cnpg-clusters.json", {"items": clusters})
dump("cnpg-backups.json", {"items": backups})
dump("cnpg-scheduled.json", {"items": scheduled})
schedules, snapshots = [], []
for ns, claim in (("gitea", "gitea-shared-storage"), ("matrix", "matrix-data")):
    schedules.append({
        "metadata": {"namespace": ns, "name": ns + "-files"},
        "spec": {"podConfigRef": {"name": "k8up-restricted"},
                 "backend": {"repoPasswordSecretRef": {"name": "k8up-repo", "key": "password"}}},
    })
    snapshots.append({
        "metadata": {"namespace": ns, "name": "snap-" + claim},
        "spec": {"id": "id-" + claim, "date": "2099-01-01T00:00:00Z", "paths": ["/data/" + claim]},
    })
dump("k8up-schedules.json", {"items": schedules})
dump("k8up-snapshots.json", {"items": snapshots})
# The running VM is complete for the guard: the three applications sync by themselves (data and pods: see the stubs).
dump("guard-apps.json", {"items": [{"metadata": {"name": n}, "spec": {"syncPolicy": {"automated": {"prune": True}}}} for n in ("root", "gitea", "matrix")]})
PY
}
rm -f "$S"/cnpg-*.json "$S"/k8up-*.json "$S"/guard-* "$S/last-apply.json" "$H/restore-in-progress.json"
MARK="$H/restore-in-progress.json"
: > "$S/applies"
fresh
lab rebuild --restore <<< "$SUDO"$'restore\nk3s-lab\n'; ok "restore without a live cluster: exit 1" "$?" 1
has "restore without a live cluster: the guard names it" "REFUSE: the running VM looks half restored" "$T/out"
has "restore without a live cluster: the missing database" "database cluster db-lab/pg-lab is missing" "$T/out"
hasnot "restore without a live cluster did not destroy" "tofu destroy" "$S/calls"
ok "restore without a live cluster applied nothing" "$(wc -l < "$S/applies" | tr -d ' ')" 0
ok "restore without a live cluster wrote no marker" "$([ -e "$MARK" ] && echo present || echo none)" none
echo "-- with the guard forced the fresh backups still refuse a missing cluster (second line of defence)"
: > "$S/applies"; fresh
LAB_RESTORE_GUARD_FORCE=1 lab rebuild --restore <<< "$SUDO"$'restore\nk3s-lab\n'; ok "restore guard forced, no live cluster: exit 1" "$?" 1
has "forced guard: the fresh backups name the cluster" "FAIL missing cluster db-lab/pg-lab" "$T/out"
hasnot "forced guard: nothing destroyed" "tofu destroy" "$S/calls"
ok "forced guard: no marker" "$([ -e "$MARK" ] && echo present || echo none)" none
write_fresh_api
: > "$S/applies"; fresh
lab export <<< "$SUDO"; ok "export then backup: export is ready" "$?" 0
has "export waits for Ready nodes" "wait --for=condition=Ready nodes --all" "$S/calls"
lab backup < /dev/null; ok "export then backup: backup succeeds immediately" "$?" 0
has "backup waits before creating snapshots" "Cluster ready before backup" "$T/out"
before=$(wc -l < "$S/applies")
lab backup --check < /dev/null; ok "backup --check succeeds" "$?" 0
ok "backup --check creates no backup objects" "$(wc -l < "$S/applies")" "$before"
lab backup --force < /dev/null; ok "backup rejects unknown flags" "$?" 1
: > "$S/applies"
fresh
tip=$(git -C "$T/repo" rev-parse HEAD)
before=$(sha256sum "$T/repo/gitops/workloads/db-lab/cluster.yaml" "$T/repo/gitops/workloads/gitea/manifests/cluster.yaml" "$T/repo/gitops/workloads/keycloak/manifests/cluster.yaml" "$T/repo/gitops/workloads/matrix/manifests/cluster.yaml")
lab rebuild --restore <<< "$SUDO"$'restore\nk3s-lab\n'; ok "restore: exit 0" "$?" 0
has "restore: the guard ran and passed" "OK   guard: the running VM looks complete" "$T/out"
has "restore: the marker was set before the destroy" "RESTORE-MARKER present at tofu destroy" "$S/calls"
ok "restore: the marker is gone after the verify step" "$([ -e "$MARK" ] && echo present || echo none)" none
g=$(grep -n "OK   guard" "$T/out" | head -n 1 | cut -d: -f1); b=$(grep -n "OK   db-lab/pg-lab backup pre-restore-pg-lab-" "$T/out" | head -n 1 | cut -d: -f1)
ok "restore: guard before the fresh backups" "$([ -n "$g" ] && [ -n "$b" ] && [ "$g" -lt "$b" ] && echo yes || echo no)" yes
has "restore took a fresh pg-lab backup" "OK   db-lab/pg-lab backup pre-restore-pg-lab-" "$T/out"
has "restore took a fresh keycloak-db backup" "OK   keycloak/keycloak-db backup pre-restore-keycloak-db-" "$T/out"
has "restore took a fresh matrix snapshot" "OK   matrix/matrix-data snapshot" "$T/out"
ok "restore applied twelve backups (before the destroy and after the restore: four databases, two file volumes each)" "$(grep -c '^apply$' "$S/applies")" 12
has "restore ends with a new pg-lab backup" "OK   db-lab/pg-lab backup post-restore-pg-lab-" "$T/out"
ok "restore ends with four new database backups" "$(grep -c 'OK   .* backup post-restore-' "$T/out")" 4
hasnot "restore log has no repo password ref" "repoPasswordSecretRef" "$T/out"
hasnot "restore did not empty the bucket" "lab-backups-empty.yml" "$S/calls"
ok "bucket still occupied" "$([ -f "$S/bucket_used" ] && echo yes || echo no)" yes
has "restore excludes Cluster resources while Argo CD starts" "ansible-playbook argocd.yml -e lab_cnpg_restore=true" "$S/calls"
has "restore applies the recovery specs" "ansible-playbook restore-clusters.yml" "$S/calls"
has "restore pauses root, Gitea and Matrix" "ansible-playbook recover-files.yml --tags pause" "$S/calls"
has "the pause phase is named after root" "Pause root, Gitea and Matrix" "$T/out"
hasnot "a clean restore does not warn about a paused root" "ATTENTION: Argo CD auto-sync" "$T/out"
has "restore restores the files" "ansible-playbook recover-files.yml --tags restore" "$S/calls"
has "restore resumes sync" "ansible-playbook recover-files.yml --tags resume" "$S/calls"
has "restore runs the doctor" "ansible-playbook recover-files.yml --tags verify" "$S/calls"
d=$(line "tofu destroy"); a=$(line "tofu apply")
ok "restore destroys before it applies" "$([ -n "$d" ] && [ -n "$a" ] && [ "$d" -lt "$a" ] && echo yes || echo no)" yes
ok "restore does not commit" "$(git -C "$T/repo" rev-parse HEAD)" "$tip"
has "plans pg-lab from the sealed prefix" "RENDER pg-lab read pg-lab-r3 write pg-lab-r4" "$T/out"
has "plans gitea-db from the sealed prefix" "RENDER gitea-db read gitea-db-r3 write gitea-db-r4" "$T/out"
has "plans matrix-db from the sealed prefix" "RENDER matrix-db read matrix-db-r3 write matrix-db-r4" "$T/out"
has "plans keycloak-db from the sealed prefix" "RENDER keycloak-db read keycloak-db-r3 write keycloak-db-r4" "$T/out"
after=$(sha256sum "$T/repo/gitops/workloads/db-lab/cluster.yaml" "$T/repo/gitops/workloads/gitea/manifests/cluster.yaml" "$T/repo/gitops/workloads/keycloak/manifests/cluster.yaml" "$T/repo/gitops/workloads/matrix/manifests/cluster.yaml")
ok "git cluster files are unchanged" "$([ "$before" = "$after" ] && echo same || echo changed)" same
ok "git stays on initdb" "$(grep -c 'initdb:' "$T/repo/gitops/workloads/db-lab/cluster.yaml")" 1
ok "VM running again" "$(cat "$S/vm")" running
hasnot "password not in the restore log" "s3kr1t" "$T/out"
d=$(line "recover-files.yml --tags pause"); r=$(line "recover-files.yml --tags restore"); u=$(line "recover-files.yml --tags resume")
ok "order pause < restore < resume" "$([ -n "$d" ] && [ "$d" -lt "$r" ] && [ "$r" -lt "$u" ] && echo yes || echo no)" yes
# #111: idle databases leave the end WAL open. The WAL is sealed before the first plan, and the plan
# runs again after the fresh backups (strict), before anything is destroyed.
ok "restore: plans twice (before and after the fresh backups)" "$(grep -c 'RENDER pg-lab read' "$T/out")" 2
p1=$(grep -n "Seal the WAL of the newest base backups" "$T/out" | head -n 1 | cut -d: -f1); r1=$(grep -n "RENDER pg-lab read" "$T/out" | head -n 1 | cut -d: -f1)
ok "restore: WAL is sealed before the first plan (#111)" "$([ -n "$p1" ] && [ -n "$r1" ] && [ "$p1" -lt "$r1" ] && echo yes || echo no)" yes
has "restore: the re-plan phase ran" "Restore plan reads the fresh backups" "$T/out"
b=$(grep -n "OK   db-lab/pg-lab backup pre-restore-pg-lab-" "$T/out" | head -n 1 | cut -d: -f1); q=$(grep -n "Restore plan reads the fresh backups" "$T/out" | head -n 1 | cut -d: -f1)
ok "restore: re-plan after the fresh backups" "$([ -n "$b" ] && [ -n "$q" ] && [ "$b" -lt "$q" ] && echo yes || echo no)" yes
echo "-- while root is paused, wait_for_argo must not wait for root, gitea and matrix"
printf 'root OutOfSync/Healthy\ngitea OutOfSync/Missing\nmatrix OutOfSync/Progressing\napp1 Synced/Healthy\ndocs Synced/Degraded\nnotes-notes Synced/Degraded\n' > "$S/apps"
: > "$S/applies"; fresh
lab rebuild --restore <<< "$SUDO"$'restore\nk3s-lab\n'; ok "restore with an OutOfSync root while paused: exit 0" "$?" 0
has "the wait before the restore ignores root, gitea and matrix" "Applications: 1, of which not yet Synced/Healthy: 0" "$T/out"
has "optional sites warn during restore" "WARNING: optional sites are not ready" "$T/out"
has "optional sites do not prevent the trust-release phase" "Release the pin (Argo CD follows the branch again)" "$T/out"
rm -f "$S/apps"
echo "-- a failing pause says loudly that root may be off"
: > "$S/fail_recover-files.yml"; : > "$S/applies"; fresh
lab rebuild --restore <<< "$SUDO"$'restore\nk3s-lab\n'; ok "restore with a failing pause: exit 1" "$?" 1
has "failing pause: attention message" "ATTENTION: Argo CD auto-sync of root, gitea and matrix may still be OFF" "$T/out"
has "failing pause: the fix is named" "ansible-playbook recover-files.yml --tags resume" "$T/out"
hasnot "failing pause: no restore ran" "recover-files.yml --tags restore" "$S/calls"
has "failing pause: the exact command continues with the pause" "cd ansible && ansible-playbook recover-files.yml --tags pause,restore,resume,verify" "$T/out"
rm -f "$S/fail_recover-files.yml"
ok "failing pause: the marker stays" "$([ -e "$MARK" ] && echo present || echo none)" present
has "the marker names the command" '"command": "rebuild --restore"' "$MARK"
echo "-- run again: the VM looks fine but the marker says the restore did not finish"
: > "$S/applies"; fresh
lab rebuild --restore <<< "$SUDO"$'restore\nk3s-lab\n'; ok "rerun with a marker: exit 1" "$?" 1
has "rerun: refused because of the marker" "an earlier rebuild --restore did not finish (marker $MARK" "$T/out"
has "rerun: names the way to finish by hand" "cd ansible && ansible-playbook recover-files.yml --tags pause,restore,resume,verify" "$T/out"
has "rerun: names the way to start over" "LAB_RESTORE_START_OVER=1 bash scripts/lab.sh rebuild --restore" "$T/out"
hasnot "rerun: no fresh backup was taken" "OK   db-lab/pg-lab backup pre-restore" "$T/out"
hasnot "rerun: nothing destroyed" "tofu destroy" "$S/calls"
ok "rerun: no backup applied" "$(wc -l < "$S/applies" | tr -d ' ')" 0
LAB_RESTORE_GUARD_FORCE=1 lab rebuild --restore <<< "$SUDO"$'restore\nk3s-lab\n'; ok "rerun: GUARD_FORCE does not override the marker" "$?" 1
hasnot "rerun forced: nothing destroyed" "tofu destroy" "$S/calls"
echo "-- LAB_RESTORE_START_OVER=1: destroy and restore again, without a backup of the broken VM"
: > "$S/applies"; fresh
LAB_RESTORE_START_OVER=1 lab rebuild --restore <<< "$SUDO"$'restore\nk3s-lab\n'; ok "start over: exit 0" "$?" 0
has "start over: says that nothing is backed up" "the running VM is NOT backed up" "$T/out"
hasnot "start over: no fresh backup before the destroy" "pre-restore-" "$T/out"
hasnot "start over: no guard" "Restore guard" "$T/out"
has "start over: the restore ran" "ansible-playbook recover-files.yml --tags verify" "$S/calls"
ok "start over: only the four+two backups after the restore were applied" "$(grep -c '^apply$' "$S/applies")" 6
ok "start over: marker gone after verify" "$([ -e "$MARK" ] && echo present || echo none)" none
echo "-- guard cases of the running VM (marker absent)"
for kind in empty:"the volume holds no data" noready:"has no ready pod"; do
  : > "$S/applies"; fresh; rm -f "$S/guard-empty" "$S/guard-noready"
  : > "$S/guard-${kind%%:*}"
  lab rebuild --restore <<< "$SUDO"$'restore\nk3s-lab\n'; ok "guard ${kind%%:*}: exit 1" "$?" 1
  has "guard ${kind%%:*}: named" "${kind#*:}" "$T/out"
  hasnot "guard ${kind%%:*}: nothing destroyed" "tofu destroy" "$S/calls"
  ok "guard ${kind%%:*}: no backup applied" "$(wc -l < "$S/applies" | tr -d ' ')" 0
  ok "guard ${kind%%:*}: no marker" "$([ -e "$MARK" ] && echo present || echo none)" none
done
rm -f "$S/guard-empty" "$S/guard-noready"
echo "-- a VM that is not running skips the guard (a rerun after a failed teardown)"
vm absent; : > "$S/applies"; fresh
printf '{"started": "x"}' > "$MARK"
lab rebuild --restore <<< "$SUDO"$'restore\nk3s-lab\n'; ok "no VM, stale marker: restore runs: exit 0" "$?" 0
hasnot "no VM: no guard" "Restore guard" "$T/out"
ok "no VM: marker removed again by verify" "$([ -e "$MARK" ] && echo present || echo none)" none
echo "-- a plain rebuild starts an empty lab on purpose and clears a stale marker"
printf '{"started": "x"}' > "$MARK"; vm running; : > "$S/rustfs_up"; : > "$S/bucket_used"; fresh
lab rebuild --yes <<< "$SUDO"; ok "plain rebuild with a stale marker: exit 0" "$?" 0
ok "plain rebuild clears the marker" "$([ -e "$MARK" ] && echo present || echo none)" none
vm running; : > "$S/bucket_used"; fresh
echo "-- a failing restore names the exact command to continue (first real run: PVC stuck in Terminating)"
: > "$S/fail_tag_restore"; : > "$S/applies"; fresh
lab rebuild --restore <<< "$SUDO"$'restore\nk3s-lab\n'; ok "restore with a failing file restore: exit 1" "$?" 1
has "failing restore: attention message" "ATTENTION: Argo CD auto-sync of root, gitea and matrix may still be OFF" "$T/out"
has "failing restore: the exact command starts at the restore" "cd ansible && ansible-playbook recover-files.yml --tags restore,resume,verify" "$T/out"
hasnot "failing restore: the pause is not repeated in the command" "--tags pause,restore" "$T/out"
hasnot "failing restore: no resume ran" "recover-files.yml --tags resume" "$S/calls"
hasnot "failing restore: no trust release ran" "Release the pin (Argo CD follows the branch again)" "$T/out"
ok "failing restore: the marker stays" "$([ -e "$MARK" ] && echo present || echo none)" present
rm -f "$S/fail_tag_restore" "$MARK"
echo "-- a failing resume continues with resume and verify"
: > "$S/fail_tag_resume"; : > "$S/applies"; fresh
lab rebuild --restore <<< "$SUDO"$'restore\nk3s-lab\n'; ok "restore with a failing resume: exit 1" "$?" 1
has "failing resume: the exact command is resume,verify" "cd ansible && ansible-playbook recover-files.yml --tags resume,verify" "$T/out"
ok "failing resume: the marker stays" "$([ -e "$MARK" ] && echo present || echo none)" present
rm -f "$S/fail_tag_resume" "$MARK"
lab rebuild --restore extra <<< "$SUDO"; ok "restore extra argument: exit 1" "$?" 1
lab help < /dev/null; has "usage lists rebuild --restore" "rebuild --restore" "$T/out"

echo "== Source trust (ADR 0023)"
lab trust status < /dev/null; ok "trust status: exit 0" "$?" 0
has "trust status: nothing recorded" "No trusted commit recorded" "$T/out"
lab trust < /dev/null; ok "trust without an action: exit 1" "$?" 1
lab trust bogus < /dev/null; ok "trust with an unknown action: exit 1" "$?" 1
lab trust init < /dev/null; ok "trust init without a commit: exit 1" "$?" 1
lab status --trust-override < /dev/null; ok "--trust-override only for up, rebuild, preflight" "$?" 1
has "--trust-override message" "--trust-override only applies to up, rebuild, preflight and trust release" "$T/out"
echo "source_trust: sometimes" >> "$T/repo/infra/envs/local/lab.local.yaml"
lab status < /dev/null; ok "invalid source_trust: exit 1" "$?" 1
has "invalid source_trust message" "source_trust must be auto, on or off" "$T/out"
sed -i '/^source_trust:/d' "$T/repo/infra/envs/local/lab.local.yaml"
help_has() { lab help < /dev/null; has "usage lists $1" "$1" "$T/out"; }
help_has "lab.sh trust ACTION"
help_has "--trust-override"

touch "$S/git_ssh" "$S/real_keygen"
TKEY=$T/tkey
ssh-keygen -q -t ed25519 -N '' -C trust-test -f "$TKEY"
tcommit() { # tcommit MESSAGE [signed]
  echo "$1" >> "$T/repo/trust.txt"
  git -C "$T/repo" add -A
  if [ "${2:-}" = signed ]; then
    git -C "$T/repo" -c user.name=t -c user.email=t@t -c gpg.format=ssh -c "user.signingkey=$TKEY" -c commit.gpgsign=true commit -q -m "$1"
  else
    git -C "$T/repo" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m "$1"
  fi
  git -C "$T/repo" push -q origin main
}
mkdir -p "$T/repo/.gitea"
printf '* namespaces="git" %s\n' "$(awk '{ print $1, $2 }' "$TKEY.pub")" > "$T/repo/.gitea/allowed_signers"
tcommit "trust anchor"
ANCHOR=$(git -C "$T/repo" rev-parse HEAD)
echo "source_trust: on" >> "$T/repo/infra/envs/local/lab.local.yaml"
STATE_FILE=$H/.config/k8s-lab/trusted-head
rm -f "$STATE_FILE"

echo "-- on, no trusted commit recorded"
lab preflight < /dev/null; ok "no anchor: preflight exit 1" "$?" 1
has "no anchor: message" "no trusted commit is recorded" "$T/out"
has "no anchor: names the next step" "bash scripts/lab.sh trust init COMMIT" "$T/out"
lab trust init "$ANCHOR" <<< "wrong"; ok "trust init with a wrong answer: exit 1" "$?" 1
ok "wrong answer records nothing" "$([ -e "$STATE_FILE" ] && echo yes || echo no)" no
lab trust init "$ANCHOR" <<< "${ANCHOR:0:7}"; ok "trust init: exit 0" "$?" 0
ok "trust init: state file has the anchor" "$(awk '{ print $1 }' "$STATE_FILE")" "$ANCHOR"
ok "trust init: state is outside the repo" "$(git -C "$T/repo" status --porcelain --untracked-files=all | grep -c trusted-head)" 0

echo "-- on, signed descendant"
tcommit "signed change" signed
HEAD1=$(git -C "$T/repo" rev-parse HEAD)
lab preflight < /dev/null; ok "signed descendant: preflight exit 0" "$?" 0
has "signed descendant: trusted" "Source trust: ${HEAD1:0:7} at repo_url is trusted" "$T/out"
ok "the trusted commit advanced" "$(awk '{ print $1 }' "$STATE_FILE")" "$HEAD1"
lab trust check < /dev/null; ok "trust check: exit 0" "$?" 0
has "trust check names the commit" "Commit at repo_url: $HEAD1" "$T/out"
vm absent; rm -f "$S/bucket_used"; fresh
lab up <<< "$SUDO"; ok "up with a trusted source: exit 0" "$?" 0
has "up: re-check at the end" "Source trust: repo_url is still at the verified commit ${HEAD1:0:7}" "$T/out"

ARGO_LINE=$(line "ansible-playbook argocd.yml -e argocd_pin_revision=$HEAD1")
REL_LINE=$(line "ansible-playbook argocd-release-pin.yml")
has "up: Argo CD is pinned to the verified commit" "ansible-playbook argocd.yml -e argocd_pin_revision=$HEAD1" "$S/calls"
has "up: the pin is released" "ansible-playbook argocd-release-pin.yml" "$S/calls"
ok "up: the pin is released after the bootstrap" "$([ "$REL_LINE" -gt "$ARGO_LINE" ] && echo yes || echo no)" yes
has "up: release is announced" "Argo CD follows the branch again" "$T/out"

echo "-- on, a commit arrives while Argo CD syncs (issue 71)"
cat > "$S/on_argocd" <<HOOK
echo "evil" >> "$T/repo/trust.txt"
git -C "$T/repo" add -A
git -C "$T/repo" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m "evil"
git -C "$T/repo" push -q origin main
HOOK
vm absent; rm -f "$S/bucket_used"; fresh
lab up <<< "$SUDO"; ok "up with an unsigned commit arriving: exit 1" "$?" 1
has "arriving commit: Argo CD was pinned to the verified commit" "ansible-playbook argocd.yml -e argocd_pin_revision=$HEAD1" "$S/calls"
hasnot "arriving commit: the pin is NOT released" "argocd-release-pin.yml" "$S/calls"
has "arriving commit: alert names the pin" "Argo CD is pinned to the verified ${HEAD1:0:7}" "$T/out"
has "arriving commit: alert names the release step" "bash scripts/lab.sh trust release" "$T/out"
rm -f "$S/on_argocd"
fresh
lab trust release < /dev/null; ok "trust release with an unsigned head: exit 1" "$?" 1
hasnot "trust release with an unsigned head: the pin stays" "argocd-release-pin.yml" "$S/calls"
has "trust release with an unsigned head: message" "the pin stays on" "$T/out"
git -C "$T/repo" reset -q --hard "$HEAD1"
git -C "$T/repo" push -q -f origin main
fresh
lab trust release < /dev/null; ok "trust release after the check: exit 0" "$?" 0
has "trust release after the check: playbook ran" "ansible-playbook argocd-release-pin.yml" "$S/calls"
lab trust release extra < /dev/null; ok "trust release with an extra argument: exit 1" "$?" 1

echo "-- on, unsigned commit at repo_url"
tcommit "unsigned change"
HEAD2=$(git -C "$T/repo" rev-parse HEAD)
lab preflight < /dev/null; ok "unsigned commit: preflight exit 1" "$?" 1
has "unsigned commit: FAIL line" "FAIL ${HEAD2:0:7} unsigned change" "$T/out"
has "unsigned commit: message" "Source trust FAILED for ${HEAD2:0:7}" "$T/out"
ok "unsigned commit: the trusted commit stays" "$(awk '{ print $1 }' "$STATE_FILE")" "$HEAD1"
vm absent; fresh
lab up <<< "$SUDO"; ok "up with an unsigned source: exit 1" "$?" 1
hasnot "up with an unsigned source: no tofu apply" "tofu apply" "$S/calls"
lab preflight --trust-override < /dev/null; ok "override without an answer: exit 1" "$?" 1
lab preflight --trust-override --yes <<< "nope"; ok "override with a wrong answer (--yes does not skip): exit 1" "$?" 1
has "override asks for the short id" "Type the first 7 characters of the commit (${HEAD2:0:7})" "$T/out"
ok "override refused: the trusted commit stays" "$(awk '{ print $1 }' "$STATE_FILE")" "$HEAD1"
lab preflight --trust-override <<< "${HEAD2:0:7}"; ok "override with the typed id: exit 0" "$?" 0
has "override is a warning" "Source trust OVERRIDDEN for ${HEAD2:0:7}" "$T/out"
ok "override records the commit" "$(awk '{ print $1 }' "$STATE_FILE")" "$HEAD2"
lab status --trust-override < /dev/null; ok "override flag outside up/rebuild/preflight: exit 1" "$?" 1

echo "-- on, checkout differs from repo_url"
git -C "$T/repo" reset -q --hard HEAD~1
lab preflight < /dev/null; ok "checkout behind repo_url: preflight exit 1" "$?" 1
git -C "$T/repo" reset -q --hard "$HEAD2"

echo "-- on, rollback and rewritten history"
git -C "$T/repo" reset -q --hard "$HEAD1"
git -C "$T/repo" push -q -f origin main
lab preflight < /dev/null; ok "rollback: preflight exit 1" "$?" 1
has "rollback: named" "OLDER than the trusted commit" "$T/out"
echo "1111111111111111111111111111111111111111 2026-01-01T00:00:00Z gone" > "$STATE_FILE"
lab preflight < /dev/null; ok "unknown trusted commit: preflight exit 1" "$?" 1
has "unknown trusted commit: named" "is not in this clone" "$T/out"
echo "$HEAD1 2026-01-01T00:00:00Z test" > "$STATE_FILE"

echo "-- auto: on once a trusted commit is recorded, off without"
sed -i '/^source_trust:/d' "$T/repo/infra/envs/local/lab.local.yaml"
lab preflight < /dev/null; ok "auto with a recorded commit: preflight exit 0" "$?" 0
has "auto with a recorded commit: check runs" "Source trust: ${HEAD1:0:7} at repo_url is trusted" "$T/out"
rm -f "$STATE_FILE"
lab preflight < /dev/null; ok "auto without a recorded commit: preflight exit 0" "$?" 0
has "auto without a recorded commit: off" "Source trust check is off" "$T/out"
echo "source_trust: off" >> "$T/repo/infra/envs/local/lab.local.yaml"
lab preflight < /dev/null; ok "off: preflight exit 0" "$?" 0
sed -i '/^source_trust:/d' "$T/repo/infra/envs/local/lab.local.yaml"
echo "== Source: GitHub mirror (ADR 0024)"
git -C "$T/repo" reset -q --hard "$HEAD1"
git -C "$T/repo" push -q -f origin main
export LAB_EGRESS_ADDRS=140.82.121.3
mkdir -p "$(dirname "$STATE_FILE")"
echo "$HEAD1 2026-01-01T00:00:00Z test" > "$STATE_FILE"  # the anchor (the section above removed it)
lab source < /dev/null; ok "source without an action: exit 1" "$?" 1
has "source without an action: usage" "Usage: bash scripts/lab.sh source status | github | gitea" "$T/out"
lab source nonsense < /dev/null; ok "source with an unknown action: exit 1" "$?" 1
lab source status < /dev/null; ok "source status (default): exit 0" "$?" 0
has "source status: gitea" "source: gitea" "$T/out"
GT_URL=$(sed -n 's/^repo_url: //p' "$T/repo/infra/envs/local/lab.yaml" | head -1)  # the Git server of this tree (test address in the public one)
has "source status: gitea reads repo_url" "Argo CD reads: $GT_URL" "$T/out"
has "source status: gitops matches" "gitops/: matches this source." "$T/out"

echo "-- config checks"
LL=$T/repo/infra/envs/local/lab.local.yaml
cp "$LL" "$T/lab.local.before-github"
echo "source: svn" >> "$LL"
lab status < /dev/null; ok "invalid source: exit 1" "$?" 1
has "invalid source: message" "source must be gitea or github (is 'svn')" "$T/out"
sed -i '/^source:/d' "$LL"
printf 'source: github\ngithub_repo_url: ssh://git@git.lab-test.invalid/me/k8s-lab.git\n' >> "$LL"
lab status < /dev/null; ok "github_repo_url on another host: exit 1" "$?" 1
has "github_repo_url on another host: message" "source: github needs github_repo_url = ssh://git@github.com/OWNER/REPO.git" "$T/out"
cp "$T/lab.local.before-github" "$LL"
printf 'source: github\nsource_trust: off\n' >> "$LL"
lab status < /dev/null; ok "github with source_trust off: exit 1" "$?" 1
has "github with source_trust off: refused" "source_trust: off is refused with source: github" "$T/out"
cp "$T/lab.local.before-github" "$LL"
printf 'source: github\nsecrets_repo_url: ssh://git@github.com/test-owner/other.git\n' >> "$LL"
lab status < /dev/null; ok "github with a secrets repo: exit 1" "$?" 1
has "github with a secrets repo: refused" "secrets_repo_url must be empty with source: github" "$T/out"
cp "$T/lab.local.before-github" "$LL"
printf 'source: github\n' >> "$LL"
lab preflight < /dev/null; ok "github before customize: preflight exit 1" "$?" 1
has "github before customize: gitops does not match" "gitops/ does not match lab.yaml" "$T/out"
cp "$T/lab.local.before-github" "$LL"

echo "-- source github"
lab source github < /dev/null; ok "source github without the public deploy key: exit 1" "$?" 1
has "source github without the public deploy key: message" "public deploy key" "$T/out"
ok "source github without the public deploy key: nothing written" "$(grep -c '^source:' "$LL")" 0
: > "$H/.ssh/deploy.pub"
lab source github < /dev/null; ok "source github: exit 0" "$?" 0
has "source github: lab.local.yaml edited" "EDIT: infra/envs/local/lab.local.yaml (source: github)" "$T/out"
has "source github: next steps" "DONE: source is github" "$T/out"
has "source github: names the public key" "$H/.ssh/deploy.pub" "$T/out"
has "source github: the key is in lab.local.yaml" "source: github" "$LL"
ok "source github: mode of lab.local.yaml unchanged" "$(stat -c %a "$LL")" "$(stat -c %a "$T/lab.local.before-github")"
GH_URL=ssh://git@github.com/test-owner/k8s-lab.git
ok "source github: gitops names the GitHub repo" "$(grep -rlF "$GH_URL" "$T/repo/gitops" | wc -l | awk '{ print ($1 > 0) ? "yes" : "no" }')" yes
ok "source github: no gitops file names the old repo" "$(grep -rlF "${GT_URL#ssh://git@}" "$T/repo/gitops" | wc -l)" 0
has "source github: the egress policy allows GitHub's range" "140.82.112.0/20" "$T/repo/gitops/workloads/argocd/networkpolicy.yaml"
hasnot "source github: the egress policy no longer lists the Gitea address" "192.0.2.7/32" "$T/repo/gitops/workloads/argocd/networkpolicy.yaml"
lab source github < /dev/null; ok "source github again: exit 0" "$?" 0
ok "source github again: one source line" "$(grep -c '^source:' "$LL")" 1
lab source status < /dev/null; ok "source status (github): exit 0" "$?" 0
has "source status (github): github" "source: github" "$T/out"
has "source status (github): the repo" "Argo CD reads: $GH_URL" "$T/out"
has "source status (github): trust always on" "Source trust: always on" "$T/out"
has "source status (github): gitops matches" "gitops/: matches this source." "$T/out"

echo "-- trust against the mirror"
tcommit "switch to github" signed
HEAD3=$(git -C "$T/repo" rev-parse HEAD)
rm -rf "$T/mirror.git"
git clone -q --bare "$T/origin.git" "$T/mirror.git"
mirror_sync() { git -C "$T/mirror.git" fetch -q "$T/origin.git" "+refs/heads/main:refs/heads/main"; }
echo "source_trust: off" >> "$LL"
lab preflight < /dev/null; ok "source_trust off stays refused: exit 1" "$?" 1
sed -i '/^source_trust:/d' "$LL"
lab preflight < /dev/null; ok "mirror in sync, signed descendant: preflight exit 0" "$?" 0
has "mirror in sync: names the GitHub source" "Source: GitHub mirror $GH_URL" "$T/out"
has "mirror in sync: trusted" "Source trust: ${HEAD3:0:7} at repo_url is trusted" "$T/out"
has "mirror in sync: github.com resolves into the ranges" "github.com resolves into github_egress_cidrs now" "$T/out"
ok "mirror in sync: the trusted commit advanced" "$(awk '{ print $1 }' "$STATE_FILE")" "$HEAD3"
LAB_EGRESS_ADDRS=198.51.100.1 lab preflight < /dev/null; ok "github.com outside github_egress_cidrs: preflight exit 1" "$?" 1
has "github.com outside github_egress_cidrs: DRIFT named" "DRIFT" "$T/out"
vm absent; rm -f "$S/bucket_used"; fresh
lab up <<< "$SUDO"; ok "up from the mirror: exit 0" "$?" 0
has "up from the mirror: Argo CD is pinned to the verified commit" "ansible-playbook argocd.yml -e argocd_pin_revision=$HEAD3" "$S/calls"
has "up from the mirror: re-check at the end" "repo_url is still at the verified commit ${HEAD3:0:7}" "$T/out"
has "up from the mirror: the pin is released" "ansible-playbook argocd-release-pin.yml" "$S/calls"

echo "-- the mirror is behind the Git server"
tcommit "signed, not yet mirrored" signed
HEAD4=$(git -C "$T/repo" rev-parse HEAD)
lab preflight < /dev/null; ok "mirror behind: preflight exit 1" "$?" 1
has "mirror behind: named" "the mirror is at ${HEAD3:0:7}, BEHIND the Git server's ${HEAD4:0:7}" "$T/out"
vm absent; fresh
lab up <<< "$SUDO"; ok "up with a mirror that is behind: exit 1" "$?" 1
hasnot "up with a mirror that is behind: no tofu apply" "tofu apply" "$S/calls"
mirror_sync
lab preflight < /dev/null; ok "mirror synced: preflight exit 0" "$?" 0

echo "-- the mirror holds a commit the Git server never had"
rm -rf "$T/mclone"
git clone -q "$T/mirror.git" "$T/mclone"
echo fork >> "$T/mclone/trust.txt"
git -C "$T/mclone" add -A
git -C "$T/mclone" -c user.name=t -c user.email=t@t -c gpg.format=ssh -c "user.signingkey=$TKEY" -c commit.gpgsign=true commit -q -m "signed fork"
git -C "$T/mclone" push -q origin main
FORK=$(git -C "$T/mirror.git" rev-parse main)
lab preflight < /dev/null; ok "mirror diverged (signed fork): preflight exit 1" "$?" 1
has "mirror diverged: named" "the mirror is at ${FORK:0:7}, which is NOT the Git server's ${HEAD4:0:7}" "$T/out"
vm absent; fresh
lab up <<< "$SUDO"; ok "up with a diverged mirror: exit 1" "$?" 1
hasnot "up with a diverged mirror: no tofu apply" "tofu apply" "$S/calls"
echo "unsigned" >> "$T/mclone/trust.txt"
git -C "$T/mclone" add -A
git -C "$T/mclone" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m "unsigned on the mirror"
git -C "$T/mclone" push -q origin main
lab preflight < /dev/null; ok "mirror with an unsigned commit: preflight exit 1" "$?" 1
has "mirror with an unsigned commit: trust failed" "Source trust FAILED" "$T/out"
lab preflight --trust-override <<< "nope"; ok "mirror with an unsigned commit: override with a wrong answer: exit 1" "$?" 1
git -C "$T/mirror.git" fetch -q "$T/origin.git" "+refs/heads/main:refs/heads/main"
lab preflight < /dev/null; ok "mirror reset to the Git server: preflight exit 0" "$?" 0
git -C "$T/mirror.git" update-ref -d refs/heads/main
lab preflight < /dev/null; ok "empty mirror: preflight exit 1" "$?" 1
has "empty mirror: cannot fetch main" "cannot fetch main of $T/mirror.git" "$T/out"
mirror_sync

echo "-- the Git server is unreachable (source github)"
GS_URL=$(git -C "$T/repo" remote get-url origin)
git_down() { git -C "$T/repo" remote set-url origin "$T/no-such-git-server.git"; }
git_up() { git -C "$T/repo" remote set-url origin "$GS_URL"; }
lcommit() { # lcommit MESSAGE: a signed commit in the PC clone only (never pushed)
  echo "$1" >> "$T/repo/trust.txt"
  git -C "$T/repo" add -A
  git -C "$T/repo" -c user.name=t -c user.email=t@t -c gpg.format=ssh -c "user.signingkey=$TKEY" -c commit.gpgsign=true commit -q -m "$1"
}
mcommit() { # mcommit MESSAGE [signed]: a commit on top of the mirror's main (fresh clone), pushed to the mirror only
  rm -rf "$T/mclone2"
  git clone -q "$T/mirror.git" "$T/mclone2"
  echo "$1" >> "$T/mclone2/trust.txt"
  git -C "$T/mclone2" add -A
  if [ "${2:-}" = signed ]; then
    git -C "$T/mclone2" -c user.name=t -c user.email=t@t -c gpg.format=ssh -c "user.signingkey=$TKEY" -c commit.gpgsign=true commit -q -m "$1"
  else
    git -C "$T/mclone2" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m "$1"
  fi
  git -C "$T/mclone2" push -q origin main
  git -C "$T/mirror.git" rev-parse main
}
back_to_known() { # PC clone and mirror at the last known state again
  git -C "$T/repo" reset -q --hard "$HEAD4"
  git -C "$T/repo" update-ref refs/remotes/origin/main "$HEAD4"
  git -C "$T/mirror.git" fetch -q "$T/origin.git" "+refs/heads/main:refs/heads/main"
  echo "$HEAD4 2026-01-01T00:00:00Z test" > "$STATE_FILE"
}
git -C "$T/repo" reset -q --hard "$HEAD4"
git -C "$T/repo" fetch -q origin main
echo "$HEAD3 2026-01-01T00:00:00Z test" > "$STATE_FILE"
git_down
lab preflight < /dev/null; ok "unreachable, mirror equals local main: preflight exit 0" "$?" 0
has "unreachable, equal: the warning names the Git server" "Git server (origin) is unreachable" "$T/out"
has "unreachable, equal: the reference is the last locally known state" "the last locally known state, local main ${HEAD4:0:7}" "$T/out"
has "unreachable, equal: origin/main as last fetched" "main == origin/main as last fetched (${HEAD4:0:7})" "$T/out"
has "unreachable, equal: the mirror equals local main" "the mirror equals the last locally known main ${HEAD4:0:7}" "$T/out"
has "unreachable, equal: trusted" "Source trust: ${HEAD4:0:7} at repo_url is trusted" "$T/out"
hasnot "unreachable, equal: no fetch error" "git fetch origin fails" "$T/out"
ok "unreachable, equal: the anchor advanced to the commit this PC knows" "$(awk '{ print $1 }' "$STATE_FILE")" "$HEAD4"
vm absent; rm -f "$S/bucket_used"; fresh
lab up <<< "$SUDO"; ok "up with the Git server unreachable: exit 0" "$?" 0
has "up with the Git server unreachable: Argo CD is pinned to the local main" "ansible-playbook argocd.yml -e argocd_pin_revision=$HEAD4" "$S/calls"
has "up with the Git server unreachable: the pin is released" "ansible-playbook argocd-release-pin.yml" "$S/calls"
lab status < /dev/null; ok "status with the Git server unreachable: exit 0" "$?" 0

echo "echo x" >> "$T/repo/trust.txt"
lab preflight < /dev/null; ok "unreachable, tracked file changed: preflight exit 1" "$?" 1
has "unreachable, tracked file changed: named" "tracked files have uncommitted changes and the Git server is unreachable" "$T/out"
git -C "$T/repo" checkout -q -- trust.txt
git -C "$T/repo" branch -q side
git -C "$T/repo" switch -q side
lab preflight < /dev/null; ok "unreachable, not on main: preflight exit 1" "$?" 1
has "unreachable, not on main: named" "Branch is 'side', expected main" "$T/out"
git -C "$T/repo" switch -q main
git -C "$T/repo" branch -q -D side

lcommit "local only, not known to the Git server"
HEAD5=$(git -C "$T/repo" rev-parse HEAD)
lab preflight < /dev/null; ok "unreachable, local main differs from origin/main as fetched: preflight exit 1" "$?" 1
has "unreachable, local main differs: named" "main (${HEAD5:0:7}) and origin/main as last fetched (${HEAD4:0:7}) differ and the Git server is unreachable" "$T/out"
git -C "$T/repo" update-ref refs/remotes/origin/main "$HEAD5"
lab preflight < /dev/null; ok "unreachable, mirror behind the local main: preflight exit 1" "$?" 1
has "unreachable, behind: named" "the mirror is at ${HEAD4:0:7}, BEHIND the last locally known main ${HEAD5:0:7}" "$T/out"
hasnot "unreachable, behind: not the override message" "never saw from the Git server" "$T/out"
vm absent; fresh
lab up <<< "$SUDO"; ok "up, unreachable and mirror behind: exit 1" "$?" 1
hasnot "up, unreachable and mirror behind: no tofu apply" "tofu apply" "$S/calls"
lab preflight --trust-override < /dev/null; ok "unreachable, behind: the override does not help: exit 1" "$?" 1
back_to_known

AHEAD=$(mcommit "signed, only on the mirror" signed)
lab preflight < /dev/null; ok "unreachable, GitHub ahead: preflight exit 1" "$?" 1
has "unreachable, ahead: GitHub has commits this PC never saw" "GitHub is at ${AHEAD:0:7}, which has commits this PC never saw from the Git server" "$T/out"
has "unreachable, ahead: nothing changed" "Nothing was changed" "$T/out"
has "unreachable, ahead: git log HEAD..r is named" "git log HEAD..${AHEAD:0:7}" "$T/out"
has "unreachable, ahead: the override is named" "--trust-override (typed confirmation)" "$T/out"
ok "unreachable, ahead: the anchor did not move" "$(awk '{ print $1 }' "$STATE_FILE")" "$HEAD4"
ok "unreachable, ahead: git log HEAD..r works in the clone" "$(git -C "$T/repo" log --format=%H HEAD.."${AHEAD:0:7}" | head -n 1)" "$AHEAD"
vm absent; fresh
lab up <<< "$SUDO"; ok "up, unreachable and GitHub ahead: exit 1" "$?" 1
hasnot "up, unreachable and GitHub ahead: no tofu apply" "tofu apply" "$S/calls"
lab preflight --trust-override < /dev/null; ok "unreachable, ahead: override without an answer: exit 1" "$?" 1
lab preflight --trust-override --yes <<< "nope"; ok "unreachable, ahead: override with a wrong answer (--yes does not skip): exit 1" "$?" 1
ok "unreachable, ahead: a wrong answer leaves the anchor" "$(awk '{ print $1 }' "$STATE_FILE")" "$HEAD4"
lab preflight --trust-override <<< "${AHEAD:0:7}"; ok "unreachable, ahead: override with the typed id: exit 0" "$?" 0
has "unreachable, ahead: the typed confirmation names git log" "git log HEAD..${AHEAD:0:7}" "$T/out"
has "unreachable, ahead: accepted by the override" "was never seen from the Git server and is accepted by the typed --trust-override" "$T/out"
ok "unreachable, ahead: the override does not record the anchor" "$(awk '{ print $1 }' "$STATE_FILE")" "$HEAD4"
vm absent; rm -f "$S/bucket_used"; fresh
lab up --trust-override <<< "$SUDO""${AHEAD:0:7}"$'\n'; ok "up, unreachable, GitHub ahead, override: exit 0" "$?" 0
has "up with the override: Argo CD is pinned to the commit GitHub has" "ansible-playbook argocd.yml -e argocd_pin_revision=$AHEAD" "$S/calls"
ok "up with the override: the anchor still did not move" "$(awk '{ print $1 }' "$STATE_FILE")" "$HEAD4"
back_to_known

lcommit "local only, second line"
HEAD6=$(git -C "$T/repo" rev-parse HEAD)
git -C "$T/repo" update-ref refs/remotes/origin/main "$HEAD6"
SIDE=$(mcommit "signed, beside the local main" signed)
lab preflight < /dev/null; ok "unreachable, diverged: preflight exit 1" "$?" 1
has "unreachable, diverged: GitHub has commits this PC never saw" "GitHub is at ${SIDE:0:7}, which has commits this PC never saw from the Git server" "$T/out"
has "unreachable, diverged: last known main is named" "last locally known main: ${HEAD6:0:7}" "$T/out"
lab preflight --trust-override <<< "${SIDE:0:7}"; ok "unreachable, diverged: override with the typed id: exit 0" "$?" 0
ok "unreachable, diverged: the override does not record the anchor" "$(awk '{ print $1 }' "$STATE_FILE")" "$HEAD4"
back_to_known

UNSIGNED=$(mcommit "unsigned, only on the mirror")
lab preflight < /dev/null; ok "unreachable, GitHub ahead with an unsigned commit: preflight exit 1" "$?" 1
has "unreachable, unsigned: trust failed" "Source trust FAILED for ${UNSIGNED:0:7}" "$T/out"
lab preflight --trust-override <<< "${UNSIGNED:0:7}"; ok "unreachable, unsigned: override with the typed id: exit 0 (one question only)" "$?" 0
ok "unreachable, unsigned: the override does not record the anchor" "$(awk '{ print $1 }' "$STATE_FILE")" "$HEAD4"
has "unreachable, unsigned: not recorded" "it is NOT recorded as the trusted commit" "$T/out"
back_to_known

git_up
lab preflight < /dev/null; ok "Git server reachable again: preflight exit 0" "$?" 0
hasnot "Git server reachable again: no unreachable warning" "Git server (origin) is unreachable" "$T/out"
has "Git server reachable again: the live comparison" "main == origin/main (${HEAD4:0:7}), Argo CD sees your state" "$T/out"
AHEAD2=$(mcommit "signed, only on the mirror, server up" signed)
lab preflight --trust-override <<< "${AHEAD2:0:7}"; ok "reachable, GitHub ahead: the override does not apply (as before): exit 1" "$?" 1
has "reachable, GitHub ahead: the old message" "which is NOT the Git server's ${HEAD4:0:7}" "$T/out"
back_to_known

echo "-- origin is the GitHub mirror itself (a clone made from GitHub after a total loss, no Git server)"
# The raw origin URL is the GitHub address; insteadOf sends the traffic to the local bare mirror (and, for the offline case, nowhere).
git -C "$T/repo" remote set-url origin "$GH_URL"
git -C "$T/repo" config "url.$T/mirror.git.insteadOf" "$GH_URL"
git -C "$T/repo" fetch -q origin main
lab preflight < /dev/null; ok "origin is the mirror: preflight exit 0" "$?" 0
has "origin is the mirror: the warning says there is no independent Git server" "origin is the GitHub mirror itself (clone made from GitHub): there is no independent Git server to compare with" "$T/out"
has "origin is the mirror: the protection is named" "the trusted commit (~/.config/k8s-lab/trusted-head" "$T/out"
has "origin is the mirror: main == origin/main" "main == origin/main (${HEAD4:0:7}), Argo CD sees your state" "$T/out"
has "origin is the mirror: trusted" "Source trust: ${HEAD4:0:7} at repo_url is trusted" "$T/out"
hasnot "origin is the mirror: not the Git server wording" "Git server (origin) is unreachable" "$T/out"
mv "$STATE_FILE" "$STATE_FILE.away"
lab preflight < /dev/null; ok "origin is the mirror, no trusted commit: preflight exit 1" "$?" 1
has "origin is the mirror, no trusted commit: trust init is named" "trust init COMMIT" "$T/out"
mv "$STATE_FILE.away" "$STATE_FILE"
cp "$LL" "$LL.bak"
sed -i 's/^source: github$/source: gitea/' "$LL"
lab preflight < /dev/null; ok "origin is the mirror but source is gitea: preflight exit 1" "$?" 1
has "origin is the mirror but source is gitea: named with the way out" "origin of this clone is the GitHub mirror (github_repo_url), but source is gitea" "$T/out"
mv "$LL.bak" "$LL"
git -C "$T/repo" config --unset "url.$T/mirror.git.insteadOf"
git -C "$T/repo" config "url.$T/no-login.git.insteadOf" "$GH_URL"
lab preflight < /dev/null; ok "origin is the mirror, cannot be fetched (no login): preflight exit 0" "$?" 0
has "origin is the mirror, no login: dedicated warning" "origin is the GitHub mirror itself and cannot be fetched with your own login now" "$T/out"
has "origin is the mirror, no login: the fix is named" "gh auth login, then git pull --ff-only" "$T/out"
hasnot "origin is the mirror, no login: not the Git server wording" "Git server (origin) is unreachable" "$T/out"
has "origin is the mirror, no login: main == origin/main as last fetched" "main == origin/main as last fetched (${HEAD4:0:7}); GitHub was not asked with your login now" "$T/out"
has "origin is the mirror, no login: the mirror equals local main" "the mirror equals the last locally known main ${HEAD4:0:7}" "$T/out"
AHEAD3=$(mcommit "signed, newer than the fresh clone" signed)
lab preflight < /dev/null; ok "origin is the mirror, no login, GitHub is ahead: preflight exit 1" "$?" 1
has "origin is the mirror, no login, ahead: pull is named" "git pull --ff-only brings this clone to the same state" "$T/out"
ok "origin is the mirror, no login, ahead: the anchor did not move" "$(awk '{ print $1 }' "$STATE_FILE")" "$HEAD4"
git -C "$T/repo" config --unset "url.$T/no-login.git.insteadOf"
git -C "$T/repo" config "url.$T/mirror.git.insteadOf" "$GH_URL"
lab preflight < /dev/null; ok "origin is the mirror, signed in, clone behind GitHub: preflight exit 1" "$?" 1
has "origin is the mirror, behind: pull first" "main (${HEAD4:0:7}) and origin/main (${AHEAD3:0:7}) differ: push or pull first" "$T/out"
git -C "$T/repo" pull -q --ff-only origin main
lab preflight < /dev/null; ok "origin is the mirror, after git pull: preflight exit 0" "$?" 0
ok "origin is the mirror, after git pull: the anchor advanced to the signed descendant" "$(awk '{ print $1 }' "$STATE_FILE")" "$AHEAD3"
git -C "$T/repo" config --unset "url.$T/mirror.git.insteadOf"
git -C "$T/repo" remote set-url origin "$GS_URL"
back_to_known

echo "-- the way back: source gitea"
lab source gitea < /dev/null; ok "source gitea: exit 0" "$?" 0
has "source gitea: lab.local.yaml edited" "EDIT: infra/envs/local/lab.local.yaml (source: gitea)" "$T/out"
ok "source gitea: no gitops file names the GitHub repo" "$(grep -rlF "$GH_URL" "$T/repo/gitops" | wc -l)" 0
has "source gitea: gitops names the Git server again" "${GT_URL#ssh://git@}" "$T/repo/gitops/values-state.yaml"
has "source gitea: the egress policy holds the Gitea address again" "192.0.2.7/32" "$T/repo/gitops/workloads/argocd/networkpolicy.yaml"
lab source status < /dev/null; has "source status after the way back: gitea" "source: gitea" "$T/out"
has "source status after the way back: gitops matches" "gitops/: matches this source." "$T/out"
tcommit "back on gitea" signed
lab preflight < /dev/null; ok "back on gitea: preflight exit 0" "$?" 0
git_down
lab preflight < /dev/null; ok "gitea mode, Git server unreachable: preflight exit 1 (unchanged)" "$?" 1
has "gitea mode, Git server unreachable: the fetch error" "git fetch origin fails" "$T/out"
hasnot "gitea mode, Git server unreachable: no offline warning" "Git server (origin) is unreachable" "$T/out"
git_up
sed -i '/^source:/d' "$LL"
unset LAB_EGRESS_ADDRS
rm -f "$S/git_ssh" "$S/real_keygen"


echo
echo "$n checks, $fail failures"
[ "$fail" = 0 ]
