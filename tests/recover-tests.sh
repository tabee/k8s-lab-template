#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
# scripts/lab-restore-render.py: recovery specs outside the repo, Git stays initdb.
# No cluster, no bucket, no secret. Usage: bash tests/recover-tests.sh [repo root]
set -u
R=$(cd "${1:-$(dirname "${BASH_SOURCE[0]}")/..}" && pwd -P)
PY=$R/scripts/lab-restore-render.py
fail=0
n=0
ok() { n=$((n + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else echo "FAIL $1 (actual '$2', expected '$3')"; fail=$((fail + 1)); fi; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

write_cluster() { # write_cluster REL NAME BASE PREFIX
  local rel=$1 name=$2 base=$3 prefix=$4 dir
  dir=$(dirname "$rel")
  mkdir -p "$T/repo/$dir"
  cat > "$T/repo/$rel" <<YAML
# The bare name ${base} must survive. This file is never rewritten.
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: $name
  namespace: $prefix
spec:
  bootstrap:
    initdb:
      database: app
      owner: app
  plugins:
    - name: barman-cloud.cloudnative-pg.io
      enabled: true
      isWALArchiver: true
      parameters:
        barmanObjectName: $name
        serverName: $base
YAML
  cat > "$T/repo/$dir/objectstore.yaml" <<YAML
spec:
  configuration:
    destinationPath: s3://cnpg-k3s-lab/$prefix
YAML
}

write_cluster gitops/workloads/db-lab/cluster.yaml pg-lab pg-lab db-lab
write_cluster gitops/workloads/gitea/manifests/cluster.yaml gitea-db gitea-db gitea
write_cluster gitops/workloads/matrix/manifests/cluster.yaml matrix-db matrix-db matrix
write_cluster gitops/workloads/keycloak/manifests/cluster.yaml keycloak-db keycloak-db keycloak

run() { python3 "$PY" --repo "$T/repo" --data-dir "$T/data" --out "$T/out-yaml" > "$T/out" 2> "$T/err"; }

rm -rf "$T/out-yaml"
run; ok "no archive: exit 1" "$?" 1
grep -q 'no replayable base backup' "$T/err"; ok "no archive explains itself" "$?" 0
ok "failed run writes nothing" "$([ -d "$T/out-yaml" ] && echo present || echo absent)" absent

WAL=000000010000000000000005
# seal ROOT PREFIX SERVER [meta]
# A plain backup.info, or backup.info/xl.meta when the fourth arg is meta.
# STARTED (end_wal=None) is written first and must not win over DONE.
seal() {
  local root=$1 prefix=$2 server=$3 kind=${4:-file}
  local dir="$root/cnpg-k3s-lab/$prefix/$server" info
  mkdir -p "$dir/base/20261101T010101" "$dir/wals/${WAL:0:16}"
  if [ "$kind" = meta ]; then
    info=$dir/base/20261101T010101/backup.info/xl.meta
    mkdir -p "$dir/base/20261101T010101/backup.info" "$dir/wals/${WAL:0:16}/$WAL.gz"
    printf 'seg\n' > "$dir/wals/${WAL:0:16}/$WAL.gz/xl.meta"
  else
    info=$dir/base/20261101T010101/backup.info
    printf 'seg\n' > "$dir/wals/${WAL:0:16}/$WAL.gz"
  fi
  printf '%s\n' 'end_wal=None' 'status=STARTED' "end_wal=$WAL" 'status=DONE' > "$info"
}

mkdir -p "$T/data/cnpg-k3s-lab/db-lab/pg-lab-r3"
printf 'wal\n' > "$T/data/cnpg-k3s-lab/db-lab/pg-lab-r3/only-wal"
seal "$T/data" gitea gitea-db-r3
seal "$T/data" matrix matrix-db-r3 meta
seal "$T/data" keycloak keycloak-db-r3
run; ok "wal without a base backup: exit 1" "$?" 1
grep -q 'db-lab/cluster.yaml' "$T/err"; ok "the cluster without a base backup is named" "$?" 0

seal "$T/data" db-lab pg-lab-r3
before=$(cat "$T/repo/gitops/workloads/matrix/manifests/cluster.yaml")
run; ok "sealed r3 archives: exit 0" "$?" 0
grep -qx 'RENDER pg-lab read pg-lab-r3 write pg-lab-r4' "$T/out"; ok "pg-lab reads r3 and writes r4" "$?" 0
grep -qx 'RENDER gitea-db read gitea-db-r3 write gitea-db-r4' "$T/out"; ok "gitea reads r3" "$?" 0
grep -qx 'RENDER matrix-db read matrix-db-r3 write matrix-db-r4' "$T/out"; ok "matrix reads r3" "$?" 0
grep -qx 'RENDER keycloak-db read keycloak-db-r3 write keycloak-db-r4' "$T/out"; ok "keycloak reads r3" "$?" 0

# A plain "info" file is not a completed backup.
rm -rf "$T/data/cnpg-k3s-lab/db-lab/pg-lab-r3"
mkdir -p "$T/data/cnpg-k3s-lab/db-lab/pg-lab-r3/base"
printf 'info\n' > "$T/data/cnpg-k3s-lab/db-lab/pg-lab-r3/base/backup.info"
rm -rf "$T/out-yaml"
run; ok "plain info without end WAL: exit 1" "$?" 1
grep -q 'db-lab/cluster.yaml' "$T/err"; ok "plain info names the cluster" "$?" 0
seal "$T/data" db-lab pg-lab-r3

# Newest DONE id has no segment. An older DONE id in that generation must not
# hide it. A .backup history file is not a segment. The lower generation's
# write name is that prefix, so the run aborts and names it.
rm -rf "$T/data/cnpg-k3s-lab/gitea"
seal "$T/data" gitea gitea-db-r2
mkdir -p "$T/data/cnpg-k3s-lab/gitea/gitea-db-r3/base/20261101T010101" \
  "$T/data/cnpg-k3s-lab/gitea/gitea-db-r3/wals/${WAL:0:16}"
printf '%s\n' "end_wal=$WAL" 'status=DONE' \
  > "$T/data/cnpg-k3s-lab/gitea/gitea-db-r3/base/20261101T010101/backup.info"
printf 'seg\n' > "$T/data/cnpg-k3s-lab/gitea/gitea-db-r3/wals/${WAL:0:16}/$WAL.gz"
mkdir -p "$T/data/cnpg-k3s-lab/gitea/gitea-db-r3/base/20261101T0303"
printf '%s\n' 'end_wal=000000010000000000000009' 'status=DONE' \
  > "$T/data/cnpg-k3s-lab/gitea/gitea-db-r3/base/20261101T0303/backup.info"
printf 'hist\n' > "$T/data/cnpg-k3s-lab/gitea/gitea-db-r3/wals/${WAL:0:16}/000000010000000000000009.00000028.backup.gz"
rm -rf "$T/out-yaml"
run; ok "unreplayable write prefix: exit 1" "$?" 1
grep -q 'write prefix gitea-db-r3 already has files' "$T/err"; ok "the blocked write prefix is named" "$?" 0
grep -q "the newest generation is not sealed" "$T/err"; ok "blocked write prefix points at the unsealed generation (#111)" "$?" 0
grep -q "pg_switch_wal" "$T/err"; ok "blocked write prefix suggests the WAL switch (#111)" "$?" 0
rm -rf "$T/data/cnpg-k3s-lab/gitea"
seal "$T/data" gitea gitea-db-r3

# Highest generation has no segment. A lower generation whose write name is free wins.
rm -rf "$T/data/cnpg-k3s-lab/matrix/matrix-db-r3/wals"
mkdir -p "$T/data/cnpg-k3s-lab/matrix/matrix-db-r3/wals/${WAL:0:16}"
printf 'hist\n' > "$T/data/cnpg-k3s-lab/matrix/matrix-db-r3/wals/${WAL:0:16}/$WAL.00000028.backup.gz"
seal "$T/data" matrix matrix-db
rm -rf "$T/out-yaml"
run; ok "fallback to the lower generation: exit 0" "$?" 0
grep -qx 'RENDER matrix-db read matrix-db write matrix-db-r2' "$T/out"; ok "matrix falls back to the bare name" "$?" 0
grep -qx 'RENDER pg-lab read pg-lab-r3 write pg-lab-r4' "$T/out"; ok "pg-lab still reads r3" "$?" 0

# Back to three replayable r3 archives for the rendered-spec check.
rm -rf "$T/data/cnpg-k3s-lab/matrix/matrix-db" "$T/data/cnpg-k3s-lab/matrix/matrix-db-r3"
seal "$T/data" matrix matrix-db-r3 meta
rm -rf "$T/data/cnpg-k3s-lab/gitea"
seal "$T/data" gitea gitea-db-r3
rm -rf "$T/out-yaml"
run; ok "sealed r3 archives again: exit 0" "$?" 0

# keycloak-db goes through the same end WAL checks as the other three clusters.
# 1. plain info without a DONE end WAL is not a backup.
KC="$T/data/cnpg-k3s-lab/keycloak"
KB="$KC/keycloak-db-r3/base"
rm -rf "$KC"
mkdir -p "$KC/keycloak-db-r3/base"
printf 'info\n' > "$KC/keycloak-db-r3/base/backup.info"
rm -rf "$T/out-yaml"
run; ok "keycloak: plain info without end WAL: exit 1" "$?" 1
grep -q 'keycloak/manifests/cluster.yaml' "$T/err"; ok "keycloak: plain info names the cluster" "$?" 0
ok "keycloak: failed run writes nothing" "$([ -d "$T/out-yaml" ] && echo present || echo absent)" absent
# 2. r3 has a DONE end WAL whose segment is missing (only a .backup history file), r2 is complete:
#    r2 is read and the write name is r3, which already has files, so the run aborts and names it.
rm -rf "$KC"
seal "$T/data" keycloak keycloak-db-r2
mkdir -p "$KB/20261101T0303" \
  "$KC/keycloak-db-r3/wals/${WAL:0:16}"
printf '%s\n' 'end_wal=000000010000000000000009' 'status=DONE' \
  > "$KB/20261101T0303/backup.info"
printf 'hist\n' > "$KC/keycloak-db-r3/wals/${WAL:0:16}/000000010000000000000009.00000028.backup.gz"
rm -rf "$T/out-yaml"
run; ok "keycloak: unreplayable write prefix: exit 1" "$?" 1
grep -q 'write prefix keycloak-db-r3 already has files' "$T/err"; ok "keycloak: the blocked write prefix is named" "$?" 0
ok "keycloak: aborted run writes nothing" "$([ -d "$T/out-yaml" ] && echo present || echo absent)" absent
# 3. the highest generation has no segment and the lower one has a free write name: it wins.
rm -rf "$KC"
mkdir -p "$KB/20261101T0303" \
  "$KC/keycloak-db-r3/wals/${WAL:0:16}"
printf '%s\n' "end_wal=$WAL" 'status=DONE' \
  > "$KB/20261101T0303/backup.info"
seal "$T/data" keycloak keycloak-db
rm -rf "$T/out-yaml"
run; ok "keycloak: fallback to the lower generation: exit 0" "$?" 0
grep -qx 'RENDER keycloak-db read keycloak-db write keycloak-db-r2' "$T/out"; ok "keycloak: falls back to the bare name" "$?" 0
# 4. an rustfs xl.meta backup.info directory is read like a plain file.
rm -rf "$KC"
seal "$T/data" keycloak keycloak-db-r3 meta
rm -rf "$T/out-yaml"
run; ok "keycloak: xl.meta archive: exit 0" "$?" 0
grep -qx 'RENDER keycloak-db read keycloak-db-r3 write keycloak-db-r4' "$T/out"; ok "keycloak: xl.meta archive reads r3" "$?" 0

after=$(cat "$T/repo/gitops/workloads/matrix/manifests/cluster.yaml")
ok "source file is not rewritten" "$([ "$before" = "$after" ] && echo same || echo changed)" same
grep -q 'serverName: matrix-db$' "$T/repo/gitops/workloads/matrix/manifests/cluster.yaml"
ok "git serverName stays the original" "$?" 0
python3 - <<PY
import pathlib, yaml
p = pathlib.Path("$T/out-yaml/matrix-matrix-db.yaml")
doc = yaml.safe_load(p.read_text())
boot = doc["spec"]["bootstrap"]
plugin = doc["spec"]["plugins"][0]["parameters"]["serverName"]
origin = doc["spec"]["externalClusters"][0]["plugin"]
assert "initdb" not in boot and "recovery" in boot, boot
assert plugin == "matrix-db-r4", plugin
assert origin["parameters"]["serverName"] == "matrix-db-r3"
assert origin["isWALArchiver"] is False
assert "The bare name matrix-db must survive" not in p.read_text()
PY
ok "rendered matrix spec is recovery into r4" "$?" 0

python3 "$PY" --repo "$T/repo" --data-dir "$T/data" --out "$T/repo/gitops" > "$T/out" 2> "$T/err"
ok "refuses to write inside the repo" "$?" 1
grep -q 'outside the repo' "$T/err"; ok "inside-repo refusal is named" "$?" 0
ok "repo write did not create a rendered file" "$([ -f "$T/repo/gitops/matrix-matrix-db.yaml" ] && echo present || echo absent)" absent

python3 - <<PY
import pathlib
p = pathlib.Path("$T/repo/gitops/workloads/db-lab/cluster.yaml")
t = p.read_text().replace("initdb:", "recovery:", 1)
p.write_text(t)
PY
rm -rf "$T/out-yaml"
run; ok "recovery in git: exit 1" "$?" 1
grep -q 'bootstrap.initdb' "$T/err"; ok "git must stay on initdb" "$?" 0

for rel in gitops/workloads/db-lab/cluster.yaml gitops/workloads/gitea/manifests/cluster.yaml gitops/workloads/matrix/manifests/cluster.yaml gitops/workloads/keycloak/manifests/cluster.yaml; do
  grep -q 'initdb:' "$R/$rel"; ok "$rel is initdb" "$?" 0
  grep -q 'recovery:' "$R/$rel"; ok "$rel has no recovery" "$?" 1
done
for app in gitops/apps/db-lab.yaml gitops/apps/gitea.yaml gitops/apps/matrix.yaml gitops/apps/keycloak.yaml; do
  grep -q 'RespectIgnoreDifferences=true' "$R/$app"; ok "$app respects ignored fields" "$?" 0
  grep -q '.spec.bootstrap' "$R/$app"; ok "$app ignores bootstrap" "$?" 0
  grep -q '.spec.externalClusters' "$R/$app"; ok "$app ignores externalClusters" "$?" 0
  grep -q '.spec.plugins\[\].parameters.serverName' "$R/$app"; ok "$app ignores the write serverName" "$?" 0
done
grep -q 'lab_cnpg_restore' "$R/ansible/roles/argocd_bootstrap/templates/values.yaml.j2"
ok "Argo CD values exclude Clusters only for the restore run" "$?" 0
grep -q 'postgresql.cnpg.io' "$R/ansible/roles/argocd_bootstrap/templates/values.yaml.j2"
ok "the exclusion names the CNPG group" "$?" 0
grep -q 'restore-clusters.yml' "$R/scripts/lab.sh"; ok "lab.sh applies the rendered specs" "$?" 0
grep -q 'cmd_recover' "$R/scripts/lab.sh"; ok "the old recover command is gone" "$?" 1

REST=$R/ansible/tasks/recover-restore-one.yml
LOAD=$R/ansible/tasks/recover-load.yml
grep -Fq 'take a K8up backup first' "$REST"; ok "a missing snapshot says to take a K8up backup first" "$?" 0
grep -Fq "('/data/' ~ target.claim) in item.spec.paths" "$REST"
ok "a snapshot matches only when the PVC path is a list entry" "$?" 0
grep -F 'selectattr' "$REST" | grep -F 'spec.paths' >/dev/null
ok "paths are not filtered with selectattr" "$?" 1
grep -Fq 'is not string' "$REST"; ok "a string paths field is rejected" "$?" 0
grep -Fq 'metadata.name' "$REST"; ok "the pin does not use the short snapshot name" "$?" 1
grep -Fq 'runAsUser: 1000' "$REST"; ok "the checker does not hardcode the gitea uid" "$?" 1
grep -Fq 'runAsUser: 991' "$REST"; ok "the checker does not hardcode the synapse uid" "$?" 1
grep -Fq 'sha256:' "$REST"; ok "the checker does not copy the image digest" "$?" 1
python3 - <<PY
import pathlib, yaml
rest = pathlib.Path("$REST")
load = pathlib.Path("$LOAD")
tasks = yaml.safe_load(rest.read_text())
flat = []
def walk(nodes):
    for task in nodes or []:
        flat.append(task)
        for key in ("block", "rescue", "always"):
            if key in task:
                walk(task[key])
walk(tasks)
restores = []
pods = []
for task in flat:
    body = task.get("kubernetes.core.k8s") or {}
    if not isinstance(body, dict):
        continue
    defin = body.get("definition")
    if isinstance(defin, dict) and defin.get("kind") == "Restore":
        restores.append(defin)
    if isinstance(defin, dict) and defin.get("kind") == "Pod":
        pods.append((task, defin))
assert len(restores) == 1, len(restores)
spec = restores[0]["spec"]
assert spec["snapshot"] == "{{ recover_snapshot_id }}", spec.get("snapshot")
assert spec["paths"] == ["/data/{{ target.claim }}"], spec.get("paths")
assert "tags" not in spec
names = [task.get("name", "") for task in flat]
assert names.index("Wait until the file restore has succeeded") < names.index("Check that the restored volume has the expected files")
assert names.index("Pin the newest snapshot id of this PVC") < names.index("Restore the pinned K8up snapshot into the empty PVC")
check = [d for _, d in pods if d["metadata"]["name"] == "recover-check"][0]
ctr = check["spec"]["containers"][0]
assert ctr["securityContext"]["readOnlyRootFilesystem"] is True
assert ctr["securityContext"]["allowPrivilegeEscalation"] is False
assert ctr["securityContext"]["capabilities"]["drop"] == ["ALL"]
assert check["spec"]["securityContext"] == "{{ recover_pod_sc }}"
assert "recover_k8up_values.image.tag" in ctr["image"]
assert ctr["command"] == ["/bin/bash", "-c"]
assert "target.content_test" in ctr["args"][0]
always = [task for task in tasks if task.get("name") == "Check the restored files and drop the checker afterwards"]
assert len(always) == 1 and any(step.get("name") == "Remove the content-check pod" for step in always[0]["always"])
# A new VM has no Snapshot objects. Then restic lists the snapshots in a
# one-off, read-only pod that the K8up egress policy lets reach S3.
lister = [d for _, d in pods if d["metadata"]["name"] == "recover-snapshots"]
assert len(lister) == 1, len(lister)
lst = lister[0]
assert lst["metadata"]["labels"]["k8upjob"] == "true"
lctr = lst["spec"]["containers"][0]
assert lctr["command"] == ["/usr/local/bin/restic"]
assert lctr["args"][:2] == ["snapshots", "--json"]
assert "--no-lock" in lctr["args"]
assert lctr["args"][-2:] == ["--path", "/data/{{ target.claim }}"]
assert lctr["securityContext"]["readOnlyRootFilesystem"] is True
assert lctr["securityContext"]["allowPrivilegeEscalation"] is False
assert lctr["securityContext"]["capabilities"]["drop"] == ["ALL"]
assert lst["spec"]["securityContext"] == "{{ recover_pod_sc }}"
assert lst["spec"]["automountServiceAccountToken"] is False
env = {e["name"] for e in lctr["env"]}
assert env == {"RESTIC_REPOSITORY", "RESTIC_PASSWORD", "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY"}, env
assert all("secretKeyRef" in e["valueFrom"] for e in lctr["env"] if "valueFrom" in e)
assert names.index("Ask the restic repository for the snapshots of this PVC") < names.index("Abort when this PVC has no snapshot, in the cluster or in restic")
assert names.index("Abort when this PVC has no snapshot, in the cluster or in restic") < names.index("Pin the newest snapshot id of this PVC")
ask = [t for t in flat if t.get("name") == "Ask the restic repository for the snapshots of this PVC"]
assert len(ask) == 1 and "recover_pvc_snaps | length == 0" in ask[0]["when"]
assert any(t.get("name") == "Remove the snapshot-list pod" for t in ask[0]["always"])
facts = yaml.safe_load(load.read_text())
targets = facts[1]["ansible.builtin.set_fact"]["recover_targets"]
by_ns = {item["namespace"]: item["content_test"] for item in targets}
assert "test -d /data/git/gitea-repositories" in by_ns["gitea"]
assert "find /data/git/gitea-repositories -mindepth 1 -print -quit" in by_ns["gitea"]
assert "grep -q ." in by_ns["gitea"]
assert by_ns["matrix"] == "test -s /data/signing.key"
joined = facts[0]["ansible.builtin.set_fact"]["recover_k8up_values"]
assert "gitops/platform/k8up/values.yaml" in joined
PY
ok "the restore spec pins spec.id and the checker runs after it" "$?" 0
grep -Fq "select('match', '^[[]')" "$REST"; ok "only the JSON array line of the restic output is parsed" "$?" 0
grep -Fq 'signing_key_path: /data/signing.key' "$R/gitops/charts/matrix/templates/configmap-homeserver.yaml"
ok "the matrix check uses the chart signing key path" "$?" 0
grep -Fq 'runAsUser: 1000' "$R/gitops/workloads/gitea/manifests/k8up-podconfig.yaml"
ok "the gitea PodConfig still runs as uid 1000" "$?" 0
grep -Fq 'runAsNonRoot: true' "$R/gitops/workloads/gitea/manifests/k8up-podconfig.yaml"
ok "the gitea PodConfig stays non-root" "$?" 0
grep -Fq 'type: RuntimeDefault' "$R/gitops/workloads/gitea/manifests/k8up-podconfig.yaml"
ok "the gitea PodConfig keeps RuntimeDefault" "$?" 0
grep -Fq 'runAsUser: 991' "$R/gitops/workloads/matrix/manifests/k8up-podconfig.yaml"
ok "the matrix PodConfig still runs as uid 991" "$?" 0
grep -Fq 'runAsNonRoot: true' "$R/gitops/workloads/matrix/manifests/k8up-podconfig.yaml"
ok "the matrix PodConfig stays non-root" "$?" 0
grep -Fq 'type: RuntimeDefault' "$R/gitops/workloads/matrix/manifests/k8up-podconfig.yaml"
ok "the matrix PodConfig keeps RuntimeDefault" "$?" 0
grep -Fq 'gitea-repositories' "$R/ansible/verify-gitea.yml"
ok "verify-gitea still reads gitea-repositories" "$?" 0

echo "-- first real run (2026-11-02): webhook race and root self-heal"
RC="$R/ansible/restore-clusters.yml"
RF="$R/ansible/recover-files.yml"
python3 - "$RC" << 'PY'
import sys, yaml
play = yaml.safe_load(open(sys.argv[1]))[0]
def flat(ts):
    for x in ts:
        yield x
        for k in ("block", "rescue", "always"):
            yield from flat(x.get(k, []))
tasks = list(flat(play["tasks"]))
names = [x.get("name", "") for x in tasks]
def idx(prefix):
    return next(i for i, n in enumerate(names) if n.startswith(prefix))
dep, svc, apply_ = idx("Wait until the CNPG operator Deployment"), idx("Wait until the CNPG webhook Service"), idx("Apply one rendered")
crd = next(i for i, n in enumerate(names) if "CRD" in n)
assert crd < dep < svc < apply_, names
d = tasks[dep]
assert d["kubernetes.core.k8s_info"]["kind"] == "Deployment"
assert d["retries"] >= 30 and d["delay"] >= 5 and "until" in d
assert "Available" in d["until"]
s = tasks[svc]
assert s["kubernetes.core.k8s_info"]["kind"] == "EndpointSlice"
assert s["kubernetes.core.k8s_info"]["api_version"] == "discovery.k8s.io/v1"
assert "kubernetes.io/service-name" in str(s["kubernetes.core.k8s_info"]["label_selectors"])
assert "restore_webhook_svc" in str(s["kubernetes.core.k8s_info"]["label_selectors"])
assert s["retries"] >= 30 and "ready" in s["until"]
assert play["vars"]["restore_webhook_svc"] == "cnpg-webhook-service"
a = tasks[apply_]
assert a["retries"] >= 5 and a["delay"] >= 5 and "register" in a
assert "restore_transient" in a["until"] and "is succeeded" in a["until"]
assert "webhook" in play["vars"]["restore_transient"]
PY
ok "restore-clusters waits for operator and webhook endpoints, and retries the apply" "$?" 0
python3 - "$RC" << 'PY'
import os, re, sys, yaml
play = yaml.safe_load(open(sys.argv[1]))[0]
def flat(ts):
    for x in ts:
        yield x
        for k in ("block", "rescue", "always"):
            yield from flat(x.get(k, []))
tasks = list(flat(play["tasks"]))
names = [x.get("name", "") for x in tasks]
def idx(prefix):
    return next(i for i, n in enumerate(names) if n.startswith(prefix))
whook, pdep, psvc, render, apply_ = (idx("Wait until the CNPG webhook Service"), idx("Wait until the barman-cloud plugin is ready"),
    idx("Wait until the barman-cloud plugin Service"), idx("Render the recovery specs"), idx("Apply one rendered"))
assert whook < pdep < psvc < render < apply_, names
d, s = tasks[pdep], tasks[psvc]
assert d["ansible.builtin.include_tasks"] == "tasks/restore-plugin-ready.yml", d
assert s["kubernetes.core.k8s_info"]["kind"] == "EndpointSlice" and "ready" in s["until"]
assert "restore_plugin_svc" in str(s["kubernetes.core.k8s_info"]["label_selectors"])
assert s["retries"] >= 30 and s["delay"] >= 5
# The old plain Deployment wait (60 x 10 s, third real run) must not come back next to the chain.
assert not any(n.startswith("Wait until the barman-cloud plugin Deployment") for n in names), names
v = play["vars"]
assert v["restore_plugin_certs"] == ["barman-cloud-client", "barman-cloud-server"]
assert v["restore_plugin_secrets"] == ["barman-cloud-client-tls", "barman-cloud-server-tls"]
assert "gitops/apps/cert-manager.yaml" in v["restore_cm_app"] and "destination.namespace" in v["restore_cm_ns"]
# The chain: cert-manager, then Certificates, then Deployment, with one failure path at each step.
T = os.path.dirname(sys.argv[1]) + "/tasks/"
def tl(f):
    return list(flat(yaml.safe_load(open(T + f))))
ready = tl("restore-plugin-ready.yml")
rn = [x.get("name", "") for x in ready]
ri = lambda prefix: next(i for i, n in enumerate(rn) if n.startswith(prefix))
assert ri("Wait until cert-manager is running") < ri("Stop when cert-manager") < ri("Wait for the plugin Certificates") \
    < ri("Stop when the plugin Certificates") < ri("Look up the TLS secrets") < ri("Wait for the barman-cloud plugin Deployment") \
    < ri("Stop when the plugin Deployment"), rn
# One budget place: the poll counts come from group_vars/all/restore.yml, not from literals.
txt = "".join(open(T + f).read() for f in ("restore-plugin-ready.yml", "restore-plugin-certs.yml", "restore-plugin-deploy.yml"))
for var in ("restore_plugin_timeout_min", "restore_plugin_delay", "restore_plugin_nudge_after_min", "restore_plugin_pod_grace_min"):
    assert var in txt, var
assert not re.search(r"retries:\s*\d", txt), "a literal retries count in the plugin chain"
g = yaml.safe_load(open(os.path.dirname(sys.argv[1]) + "/inventory/group_vars/all/restore.yml"))
assert g["restore_plugin_timeout_min"] >= 20, g
assert 0 < g["restore_plugin_nudge_after_min"] < g["restore_plugin_timeout_min"] and 0 < g["restore_plugin_pod_grace_min"] < g["restore_plugin_timeout_min"]
assert not [k for k in v if k in g], "a budget variable defined twice"
# The failure message names the recovery command.
fail = open(T + "restore-plugin-fail.yml").read()
assert "ansible-playbook restore-clusters.yml" in fail and "recover-files.yml --tags restore,resume,verify" in fail
# Only the plugin pod is ever deleted, once (round 2 of the Deployment wait only), and the sync by hand only in round 2.
dep = open(T + "restore-plugin-deploy.yml").read()
assert dep.count("state: absent") == 1 and "restore_plugin_name" in dep and "restore_pl_round | int == 2" in dep
cert = open(T + "restore-plugin-certs.yml").read()
assert cert.count("state: patched") == 1 and "restore_pl_round | int == 2" in cert and "'Failed', 'Error'" in cert
PY
ok "restore-clusters waits for the barman-cloud plugin before it applies recovery specs" "$?" 0
# The names the wait uses must be the ones the chart really creates (helm template of the pinned chart, if cached).
python3 - "$R" "$T" << 'PY'
import glob, os, re, shutil, subprocess, sys, tempfile, yaml
R, T = sys.argv[1], sys.argv[2]
play = yaml.safe_load(open(R + "/ansible/restore-clusters.yml"))[0]
name, svc = play["vars"]["restore_plugin_name"], play["vars"]["restore_plugin_svc"]
app = yaml.safe_load(open(R + "/gitops/apps/cnpg.yaml"))
ver = next(s["targetRevision"] for s in app["spec"]["sources"] if s.get("chart") == "plugin-barman-cloud")
cands = glob.glob("/tmp/hh/c/plugin-barman-cloud-%s.tgz" % ver) + glob.glob(os.path.expanduser("~/.cache/helm/repository/plugin-barman-cloud-%s.tgz" % ver))
if not cands or not shutil.which("helm"):
    print("SKIP no cached chart or no helm; names checked against the Git files only")
    sys.exit(0)
d = tempfile.mkdtemp(dir=T)
subprocess.run(["tar", "xzf", cands[0], "-C", d], check=True)
out = subprocess.run(["helm", "template", "x", d + "/plugin-barman-cloud", "-n", "cnpg-system", "-f", R + "/gitops/platform/cnpg/values-plugin.yaml"],
                     check=True, capture_output=True, text=True).stdout
docs = [x for x in yaml.safe_load_all(out) if x]
dep = [x for x in docs if x["kind"] == "Deployment"]
sv = [x for x in docs if x["kind"] == "Service"]
assert len(dep) == 1 and dep[0]["metadata"]["labels"]["app.kubernetes.io/name"] == name, "deployment label"
assert dep[0]["spec"]["selector"]["matchLabels"]["app.kubernetes.io/name"] == name
assert len(sv) == 1 and sv[0]["metadata"]["name"] == svc, "service name"
certs = {x["metadata"]["name"]: x["spec"]["secretName"] for x in docs if x["kind"] == "Certificate"}
assert certs == dict(zip(play["vars"]["restore_plugin_certs"], play["vars"]["restore_plugin_secrets"])), certs
mounted = {v["secret"]["secretName"] for v in dep[0]["spec"]["template"]["spec"]["volumes"] if "secret" in v}
assert set(certs.values()) <= mounted, ("the pod mounts", mounted)
assert [x["spec"]["selfSigned"] for x in docs if x["kind"] == "Issuer"] == [{}], "the plugin issuer is self-signed (no lab CA needed)"
assert sv[0]["metadata"]["labels"]["cnpg.io/pluginName"] == "barman-cloud.cloudnative-pg.io"
print("OK   chart %s: Deployment label %s, Service %s" % (ver, name, svc))
PY
ok "plugin Deployment label and Service name match the pinned chart" "$?" 0
grep -Fq "Endpoints" "$RC" && grep -Eq 'kind: Endpoints$' "$RC"; ok "the wait does not use the deprecated Endpoints v1" "$?" 1
python3 - "$R" << 'PY'
import sys, yaml
R = sys.argv[1]
app = yaml.safe_load(open(R + "/gitops/apps/cnpg.yaml"))
ns = app["spec"]["destination"]["namespace"]
rc = open(R + "/ansible/restore-clusters.yml").read()
assert "gitops/apps/cnpg.yaml" in rc and "restore_op_ns" in rc, "the namespace must come from the Application, not be hardcoded"
assert "cnpg-system" not in rc.replace("# ", "") or ns == "cnpg-system"
PY
ok "the operator namespace is read from gitops/apps/cnpg.yaml" "$?" 0
python3 - "$RF" << 'PY'
import sys, yaml
plays = yaml.safe_load(open(sys.argv[1]))
pause = next(p for p in plays if "pause" in (p.get("tags") or []))
resume = next(p for p in plays if "resume" in (p.get("tags") or []))
def flat(tasks):
    for x in tasks:
        yield x
        for k in ("block", "rescue", "always"):
            for y in flat(x.get(k, [])):
                yield y
ptxt = yaml.dump(pause["tasks"])
assert ptxt.index("recover-root-pause.yml") < ptxt.index("recover-pause-one.yml"), "root must be paused before the children"
blk = next(x for x in pause["tasks"] if "block" in x)
assert "block" in blk and "rescue" in blk, "pause is a block with a rescue"
assert "--tags resume" in yaml.dump(blk["rescue"]) and "OFF" in yaml.dump(blk["rescue"])
assert "wait" in yaml.dump(blk["block"]).lower() or any("Application" in str(x) for x in blk["block"])
rtxt = yaml.dump(resume["tasks"])
rb = next(x for x in resume["tasks"] if "block" in x)
assert "block" in rb and "always" in rb, "resume is a block with an always"
assert "recover-root-resume.yml" in yaml.dump(rb["always"]), "root is restored in always"
assert "recover-root-resume.yml" not in yaml.dump(rb["block"]), "children first, then root"
PY
ok "pause: root first, children second, loud rescue; resume: children, then root in always" "$?" 0
python3 - "$R" << 'PY'
import sys, yaml
R = sys.argv[1]
pause = open(R + "/ansible/tasks/recover-root-pause.yml").read()
resume = open(R + "/ansible/tasks/recover-root-resume.yml").read()
yaml.safe_load(pause); yaml.safe_load(resume)
assert "/spec/syncPolicy/automated" in pause and "op: remove" in pause
assert "is defined" in pause, "only pause when automated is set (idempotent)"
assert "argocd_root_automated" in resume and "state: patched" in resume
assert "when:" in resume and "!=" in resume, "only patch when the live value differs"
g = open(R + "/ansible/inventory/group_vars/all/argocd.yml").read()
assert "argocd_root_automated:" in g
boot = open(R + "/ansible/roles/argocd_bootstrap/tasks/gitops.yml").read()
assert "automated: \"{{ argocd_root_automated }}\"" in boot, "root is created from the same variable"
assert "selfHeal: true" not in boot, "no second hardcoded copy of the root policy"
v = yaml.safe_load(g)["argocd_root_automated"]
assert v == {"prune": True, "selfHeal": True}, v
PY
ok "root's desired automated policy has one definition (group_vars) used by bootstrap and resume" "$?" 0
grep -Fq "ARGO_SKIP='^(root|gitea|matrix) '" "$R/scripts/lab.sh"; ok "lab.sh ignores root while it is paused" "$?" 0
grep -Fq 'tags resume' "$R/scripts/lab.sh" && grep -Fq 'ROOT_PAUSED=0' "$R/scripts/lab.sh"; ok "lab.sh resets the paused flag only after the resume" "$?" 0
for d in "$R/docs/how-to/rebuild.md" "$R/docs/concepts/decisions/0018-recover-from-backup.md"; do
  grep -Fq 'cnpg-webhook-service' "$d" && grep -Fq -- '--tags resume' "$d"; ok "docs name both pitfalls: $(basename "$d")" "$?" 0
done
(cd "$R/ansible" && ansible-playbook --syntax-check restore-clusters.yml recover-files.yml > "$T/syntax.out" 2>&1); ok "restore-clusters.yml and recover-files.yml pass --syntax-check" "$?" 0

echo
echo "$n checks, $fail failures"
[ "$fail" = 0 ]
