#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
# Offline tests for scripts/lab-backup-fresh.py. No cluster: kubectl is a stub.
#   1. age and snapshot-path self-test
#   2. --check passes only when every backup and snapshot is fresh
#   3. --force-all creates six backups (four databases, two volumes) and waits; a failure does not continue
#   4. lab.sh calls it once, before the VM is destroyed, with no skip flag
#   5. --prefix post-restore: the first backups after rebuild --restore (CNPG shows no completed backup otherwise)
#   6. --guard: the running VM must look complete before the fresh backups (marker, clusters, auto-sync, data)
# Usage: bash tests/backup-fresh-tests.sh [repo root]
set -u
export PYTHONDONTWRITEBYTECODE=1
R=$(cd "${1:-$(dirname "${BASH_SOURCE[0]}")/..}" && pwd -P)
mkdir -p "$HOME/.cache/lab-sh-tests"
T=$(mktemp -d -p "$HOME/.cache/lab-sh-tests")
cleanup() { rm -rf "$T"; }
trap cleanup EXIT
fail=0
n=0
ok() { n=$((n + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else echo "FAIL $1 (is '$2', want '$3')"; fail=$((fail + 1)); fi; }
has() { grep -Fq -- "$2" "$3"; local r=$?; ok "$1" "$r" 0; }
S="$R/scripts/lab-backup-fresh.py"
NOW="2026-11-01T12:00:00Z"

mkdir -p "$T/bin" "$T/fake/applied" "$T/fake/snaps"
cat > "$T/bin/kubectl" << 'PY'
#!/usr/bin/env python3
import json, os, sys
fake = os.environ["FAKE_DIR"]
args = sys.argv[1:]
with open(os.path.join(fake, "calls"), "a", encoding="utf-8") as handle:
    handle.write(" ".join(args) + "\n")
mode = open(os.path.join(fake, "mode"), encoding="utf-8").read().strip()
if mode == "down":
    sys.stderr.write("connection refused\n")
    sys.exit(1)
def jsonfile(name, default):
    path = os.path.join(fake, name)
    return json.load(open(path, encoding="utf-8")) if os.path.isfile(path) else default
if args[:1] == ["exec"]:
    ns = args[args.index("-n") + 1]
    path = os.path.join(fake, "exec-" + ns)
    res = open(path, encoding="utf-8").read().strip() if os.path.isfile(path) else "data"
    if res == "empty":
        sys.exit(1)
    if res == "broken":
        sys.stderr.write("error: unable to upgrade connection: container not found\n")
        sys.exit(1)
    sys.exit(0)
if args[:2] == ["get", "applications.argoproj.io"]:
    json.dump(jsonfile("apps.json", {"items": []}), sys.stdout)
    sys.exit(0)
if args[:2] == ["get", "deployment"]:
    key = args[3] + "/" + args[4]
    deps = jsonfile("deployments.json", {})
    if key not in deps:
        sys.stderr.write("Error from server (NotFound): deployments.apps not found\n")
        sys.exit(1)
    json.dump({"status": {"readyReplicas": deps[key]}}, sys.stdout)
    sys.exit(0)
if args[:1] == ["apply"]:
    doc = json.load(sys.stdin)
    name = doc["metadata"]["name"]
    ns = doc["metadata"]["namespace"]
    with open(os.path.join(fake, "applies"), "a", encoding="utf-8") as handle:
        handle.write(name + "\n")
    if str(doc.get("apiVersion", "")).startswith("postgresql"):
        if mode == "fail":
            doc["status"] = {"phase": "failed", "error": "stub failed"}
        elif mode == "hang":
            doc["status"] = {"phase": "running"}
        else:
            doc["status"] = {
                "phase": "completed",
                "stoppedAt": "2026-11-01T12:00:00Z",
                "endWal": "000000010000000000000005",
            }
    else:
        if mode == "fail":
            doc["status"] = {"conditions": [{"type": "Completed", "status": "True", "reason": "Failed", "message": "stub failed"}]}
        elif mode == "hang":
            doc["status"] = {}
        else:
            doc["status"] = {"finished": True, "conditions": [{"type": "Completed", "status": "True", "reason": "Succeeded"}]}
            claim = "gitea-shared-storage" if ns == "gitea" else "matrix-data"
            snap = {
                "metadata": {"namespace": ns, "name": "snap-" + name},
                "spec": {"id": "id-" + name, "date": "2026-11-01T12:00:00Z", "paths": ["/data/" + claim]},
            }
            with open(os.path.join(fake, "snaps", name + ".json"), "w", encoding="utf-8") as handle:
                json.dump(snap, handle)
    with open(os.path.join(fake, "applied", name + ".json"), "w", encoding="utf-8") as handle:
        json.dump(doc, handle)
    sys.exit(0)
if args[:1] != ["get"]:
    sys.stderr.write("unexpected kubectl\n")
    sys.exit(1)
kind = args[1]
if "-n" in args:
    name = args[args.index("-n") + 2]
    path = os.path.join(fake, "applied", name + ".json")
    if not os.path.isfile(path):
        sys.stderr.write("missing %s\n" % name)
        sys.exit(1)
    sys.stdout.write(open(path, encoding="utf-8").read())
    sys.exit(0)
files = {
    "clusters.postgresql.cnpg.io": "clusters.json",
    "scheduledbackups.postgresql.cnpg.io": "scheduled.json",
    "backups.postgresql.cnpg.io": "backups.json",
    "schedules.k8up.io": "schedules.json",
    "snapshots.k8up.io": "snapshots.json",
}
path = os.path.join(fake, files.get(kind, ""))
doc = {"items": []}
if path and os.path.isfile(path):
    doc = json.load(open(path, encoding="utf-8"))
if kind == "snapshots.k8up.io":
    for extra in sorted(os.listdir(os.path.join(fake, "snaps"))):
        doc.setdefault("items", []).append(json.load(open(os.path.join(fake, "snaps", extra), encoding="utf-8")))
json.dump(doc, sys.stdout)
PY
chmod +x "$T/bin/kubectl"

write_world() { # write_world [stale|nosnap|nobackup|nokcbackup|nokcsched|nocluster|nosched]
  python3 - "$T/fake" "${1:-fresh}" << 'PY'
import json, os, sys
fake, kind = sys.argv[1], sys.argv[2]
def dump(name, obj):
    json.dump(obj, open(os.path.join(fake, name), "w"))
clusters, backups, scheduled = [], [], []
stopped = "2026-10-30T12:00:00Z" if kind == "stale" else "2026-11-01T10:00:00Z"
for ns, name in (("db-lab", "pg-lab"), ("gitea", "gitea-db"), ("matrix", "matrix-db"), ("keycloak", "keycloak-db")):
    if not (kind == "nocluster" and name == "pg-lab"):
        clusters.append({"metadata": {"namespace": ns, "name": name}, "status": {"currentPrimary": name + "-1"}})
    if kind != "nobackup" and not (kind == "nokcbackup" and name == "keycloak-db"):
        backups.append({
            "metadata": {"namespace": ns, "name": "daily"},
            "spec": {"cluster": {"name": name}},
            "status": {"phase": "completed", "stoppedAt": stopped, "endWal": "000000010000000000000005"},
        })
    if kind == "nokcsched" and name == "keycloak-db":
        continue
    scheduled.append({
        "metadata": {"namespace": ns, "name": name + "-daily"},
        "spec": {"cluster": {"name": name}, "method": "plugin",
                 "pluginConfiguration": {"name": "barman-cloud.cloudnative-pg.io"}},
    })
schedules, snapshots = [], []
for ns, claim in (("gitea", "gitea-shared-storage"), ("matrix", "matrix-data")):
    if not (kind == "nosched" and ns == "gitea"):
        schedules.append({
            "metadata": {"namespace": ns, "name": ns + "-files"},
            "spec": {"podConfigRef": {"name": "k8up-restricted"},
                     "backend": {"repoPasswordSecretRef": {"name": "k8up-repo", "key": "password"}}},
        })
    if kind != "nosnap":
        snapshots.append({
            "metadata": {"namespace": ns, "name": "snap"},
            "spec": {"id": "abc", "date": stopped, "paths": ["/data/" + claim]},
        })
dump("clusters.json", {"items": clusters})
dump("backups.json", {"items": backups})
dump("scheduled.json", {"items": scheduled})
dump("schedules.json", {"items": schedules})
dump("snapshots.json", {"items": snapshots})
PY
}

run_py() {
  rm -rf "$T/fake/applied" "$T/fake/snaps"
  mkdir -p "$T/fake/applied" "$T/fake/snaps"
  : > "$T/fake/applies"
  : > "$T/fake/calls"
  FAKE_DIR="$T/fake" PATH="$T/bin:$PATH" python3 "$S" --max-age-h 30 --attempts 2 --interval 0 --now "$NOW" "$@" > "$T/out" 2> "$T/err"
}

python3 "$S" --self-test > "$T/out" 2> "$T/err"
ok "self-test exit 0" "$?" 0
has "self-test says OK" "OK   self-test" "$T/out"

echo ok > "$T/fake/mode"
write_world fresh
run_py --check
ok "fresh check: exit 0" "$?" 0
has "fresh check names pg-lab" "OK   db-lab/pg-lab backup" "$T/out"
ok "fresh check does not apply" "$(wc -l < "$T/fake/applies" | tr -d ' ')" 0

write_world stale
run_py --check
ok "stale check: exit 1" "$?" 1
has "stale check names the age" "backup is 48h old (allowed 30h)" "$T/out"
ok "stale check does not apply" "$(wc -l < "$T/fake/applies" | tr -d ' ')" 0

write_world nobackup
run_py --check
ok "no backup: exit 1" "$?" 1
has "no backup names the cluster" "FAIL gitea/gitea-db no completed backup" "$T/out"

write_world nokcbackup
run_py --check
ok "keycloak without a backup: exit 1" "$?" 1
has "keycloak without a backup is named" "FAIL keycloak/keycloak-db no completed backup" "$T/out"

write_world nokcsched
run_py --force-all
ok "keycloak without a ScheduledBackup: exit 1" "$?" 1
has "keycloak without a ScheduledBackup is named" "FAIL keycloak/keycloak-db needs exactly one ScheduledBackup (found 0)" "$T/out"
ok "keycloak without a ScheduledBackup applies nothing" "$(wc -l < "$T/fake/applies" | tr -d ' ')" 0

write_world nosnap
run_py --check
ok "no snapshot: exit 1" "$?" 1
has "no snapshot names the claim" "FAIL matrix/matrix-data no snapshot" "$T/out"

write_world nocluster
run_py --force-all
ok "missing cluster: exit 1" "$?" 1
has "missing cluster is named" "FAIL missing cluster db-lab/pg-lab" "$T/out"
ok "missing cluster applies nothing" "$(wc -l < "$T/fake/applies" | tr -d ' ')" 0

write_world nosched
run_py --force-all
ok "missing schedule: exit 1" "$?" 1
has "missing schedule is named" "FAIL missing schedule gitea" "$T/out"
ok "missing schedule applies nothing" "$(wc -l < "$T/fake/applies" | tr -d ' ')" 0

write_world fresh
run_py --force-all
ok "force: exit 0" "$?" 0
ok "force applies six backups (keycloak-db has no file backup)" "$(wc -l < "$T/fake/applies" | tr -d ' ')" 6
has "force names the keycloak backup" "OK   keycloak/keycloak-db backup pre-restore-keycloak-db-" "$T/out"
if grep -q 'keycloak.*snapshot' "$T/out"; then
  ok "keycloak has no K8up snapshot step" 1 0
else
  ok "keycloak has no K8up snapshot step" 0 0
fi
has "force names the pg-lab backup" "OK   db-lab/pg-lab backup pre-restore-pg-lab-" "$T/out"
has "force names the matrix snapshot" "OK   matrix/matrix-data snapshot" "$T/out"
if grep -q 'repoPasswordSecretRef' "$T/out" "$T/err"; then
  ok "force output has no secret ref" 1 0
else
  ok "force output has no secret ref" 0 0
fi

echo "-- after rebuild --restore: backups named post-restore"
write_world fresh
run_py --force-all --prefix post-restore
ok "prefix: exit 0" "$?" 0
ok "prefix: six backups" "$(wc -l < "$T/fake/applies" | tr -d ' ')" 6
has "prefix names the matrix-db backup" "OK   matrix/matrix-db backup post-restore-matrix-db-" "$T/out"
has "prefix names the keycloak-db backup" "OK   keycloak/keycloak-db backup post-restore-keycloak-db-" "$T/out"
ok "prefix names the K8up backups too" "$(grep -c '^post-restore-gitea-shared-storage-\|^post-restore-matrix-data-' "$T/fake/applies")" 2
ok "prefix: no pre-restore name is used" "$(grep -c '^pre-restore-' "$T/fake/applies")" 0
run_py --force-all
ok "no prefix: default name stays pre-restore" "$(grep -c '^pre-restore-' "$T/fake/applies")" 6
run_py --force-all --prefix 'Bad_Name'
ok "bad prefix: exit 2" "$?" 2
ok "bad prefix applies nothing" "$(wc -l < "$T/fake/applies" | tr -d ' ')" 0

echo fail > "$T/fake/mode"
write_world fresh
run_py --force-all
ok "failed backup: exit 1" "$?" 1
has "failed backup says why" "stub failed" "$T/out"
ok "failed backup stops after the first" "$(wc -l < "$T/fake/applies" | tr -d ' ')" 1

echo hang > "$T/fake/mode"
write_world fresh
run_py --force-all
ok "backup that never finishes: exit 1" "$?" 1
has "backup that never finishes times out" "timed out" "$T/out"

echo down > "$T/fake/mode"
run_py --check
ok "kubectl down: exit 1" "$?" 1
has "kubectl down: FAIL" "FAIL kubectl" "$T/err"

gitea_claim=$(python3 -c 'import re,sys; t=open(sys.argv[1],encoding="utf-8").read(); print(re.search(r"^  claimName: (\S+)", t, re.M).group(1))' "$R/gitops/workloads/gitea/values-gitea.yaml")
matrix_claim=$(python3 -c 'import re,sys; t=open(sys.argv[1],encoding="utf-8").read(); print(re.search(r"^  name: (\S+)", t, re.M).group(1))' "$R/gitops/workloads/matrix/manifests/pvc.yaml")
grep -Fq "(\"gitea\", \"$gitea_claim\")" "$S"; ok "script uses the gitea claim from the chart" "$?" 0
grep -Fq "(\"matrix\", \"$matrix_claim\")" "$S"; ok "script uses the matrix claim from the PVC" "$?" 0

python3 - "$R" "$S" << 'PY'
import glob, os, re, sys
repo, script = sys.argv[1], sys.argv[2]
want = set()
for path in glob.glob(os.path.join(repo, "gitops/workloads/**/cluster.yaml"), recursive=True):
    text = open(path, encoding="utf-8").read()
    if re.search(r"^kind: Cluster$", text, re.M) and "postgresql.cnpg.io" in text:
        ns = re.search(r"^  namespace: (\S+)", text, re.M).group(1)
        name = re.search(r"^  name: (\S+)", text, re.M).group(1)
        want.add((ns, name))
src = open(script, encoding="utf-8").read()
block = src[src.index("CLUSTERS = ("):src.index(")\n", src.index("CLUSTERS = ("))]
have = set(re.findall(r'\("([^"]+)", "([^"]+)"\)', block))
print("manifests:", sorted(want))
sys.exit(0 if want == have and len(want) == 4 else 1)
PY
ok "script lists exactly the four Cluster manifests from Git" "$?" 0

ok "only rebuild --restore forces a fresh backup" "$(grep -c 'backup_fresh --force-all' "$R/scripts/lab.sh")" 1
python3 - "$R/scripts/lab.sh" << 'PY'
import sys
text = open(sys.argv[1], encoding="utf-8").read()
body = text[text.index("rebuild_restore()"):text.index("\ncmd_rebuild()")]
fresh = body.index("backup_fresh --force-all")
wal = body.index("wal_ready")
tear = body.index("vm_teardown")
assert fresh < wal < tear
sys.exit(0)
PY
ok "fresh backup runs before the WAL check and the destroy" "$?" 0
python3 - "$R/scripts/lab.sh" << 'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
bp = text[text.index("build_phases()"):text.index("\nup_flow()")]
# runs only on the restore path, after the files are back and verified
rec = bp[bp.index('if [ "$RECOVER_FILES" = 1 ]; then\n    phase "Restore Gitea'):]
assert "post_restore_backups" in rec, "post-restore backups are not in the restore block"
assert rec.index("--tags verify") < rec.index("post_restore_backups")
assert "post_restore_backups" not in bp[:bp.index(rec)]
assert "backup_fresh --post-restore" in text
assert text.count("post_restore_backups") == 2, text.count("post_restore_backups")  # definition and phase
PY
ok "lab.sh takes the post-restore backups only in the restore block, after the verify phase" "$?" 0
# The function itself: a failing backup is a loud warning, not an abort of a finished restore.
python3 - "$R/scripts/lab.sh" "$T/prb.sh" << 'PY'
import sys
text = open(sys.argv[1], encoding="utf-8").read()
start = text.index("post_restore_backups() {")
end = text.index("\n}\n", start) + 3
open(sys.argv[2], "w", encoding="utf-8").write("W_backup_max_age_h=30\n" + text[start:end] + "\n")
PY
bash -c 'source "$1"; backup_fresh() { echo "called: $*"; return 1; }; post_restore_backups; echo "rc=$?"' _ "$T/prb.sh" > "$T/prb.out" 2> "$T/prb.err"
has "failing post-restore backup: the function still returns 0" "rc=0" "$T/prb.out"
has "failing post-restore backup: uses the post-restore mode" "called: --post-restore" "$T/prb.out"
has "failing post-restore backup: loud warning" "WARNING: the lab is restored" "$T/prb.err"
has "failing post-restore backup: gives the command to run again" "lab-backup-fresh.py --force-all --prefix post-restore --max-age-h 30" "$T/prb.err"
bash -c 'source "$1"; backup_fresh() { echo "called: $*"; return 0; }; post_restore_backups; echo "rc=$?"' _ "$T/prb.sh" > "$T/prb.out" 2> "$T/prb.err"
ok "working post-restore backup: no warning" "$(wc -c < "$T/prb.err" | tr -d ' ')" 0
if grep -n 'backup_fresh\|lab-backup-fresh' "$R/scripts/lab.sh" | grep -E -q -- '--skip|SKIP_WAL|no-wal'; then
  ok "lab.sh has no skip flag for the fresh backup" 1 0
else
  ok "lab.sh has no skip flag for the fresh backup" 0 0
fi

echo "-- --guard: is the running VM complete?"
write_guard_world() { # write_guard_world [complete|nogitea|nomatrixdb|autooff|scaled|empty-gitea|empty-matrix|broken-exec]
  python3 - "$T/fake" "${1:-complete}" << 'PY'
import json, os, sys
fake, kind = sys.argv[1], sys.argv[2]
def dump(name, obj):
    json.dump(obj, open(os.path.join(fake, name), "w"))
for name in ("exec-gitea", "exec-matrix"):
    if os.path.exists(os.path.join(fake, name)):
        os.remove(os.path.join(fake, name))
clusters = []
for ns, name in (("db-lab", "pg-lab"), ("gitea", "gitea-db"), ("matrix", "matrix-db"), ("keycloak", "keycloak-db")):
    if kind == "nomatrixdb" and name == "matrix-db":
        continue
    clusters.append({"metadata": {"namespace": ns, "name": name}})
dump("clusters.json", {"items": clusters})
apps = []
for name in ("root", "gitea", "matrix", "cnpg"):
    sync = {} if (kind == "autooff" and name == "gitea") else {"automated": {"prune": True}}
    apps.append({"metadata": {"name": name}, "spec": {"syncPolicy": sync}})
dump("apps.json", {"items": apps})
deps = {"gitea/gitea": 1, "matrix/synapse": 1}
if kind == "scaled":
    deps["gitea/gitea"] = 0
if kind == "nogitea":
    del deps["gitea/gitea"]
dump("deployments.json", deps)
if kind == "empty-gitea":
    open(os.path.join(fake, "exec-gitea"), "w").write("empty")
if kind == "empty-matrix":
    open(os.path.join(fake, "exec-matrix"), "w").write("empty")
if kind == "broken-exec":
    open(os.path.join(fake, "exec-matrix"), "w").write("broken")
PY
}
guard_py() { # guard_py [marker path]
  rm -f "$T/fake/calls"
  : > "$T/fake/calls"
  FAKE_DIR="$T/fake" PATH="$T/bin:$PATH" python3 "$S" --guard --marker "${1:-$T/marker.json}" > "$T/out" 2> "$T/err"
}
echo ok > "$T/fake/mode"
rm -f "$T/marker.json"
write_guard_world complete
guard_py
ok "guard: a complete VM without marker passes" "$?" 0
has "guard: says OK" "OK   guard: the running VM looks complete" "$T/out"
ok "guard: it backed nothing up" "$(grep -c '^apply' "$T/fake/calls")" 0

for kind in nogitea:"gitea/gitea-shared-storage: Deployment gitea does not exist" nomatrixdb:"database cluster matrix/matrix-db is missing" \
  autooff:"auto-sync of the Argo CD application gitea is off" scaled:"gitea/gitea-shared-storage: Deployment gitea has no ready pod" \
  empty-gitea:"gitea/gitea-shared-storage: the volume holds no data" empty-matrix:"matrix/matrix-data: the volume holds no data" \
  broken-exec:"matrix/matrix-data: could not look into the volume"; do
  write_guard_world "${kind%%:*}"
  guard_py
  ok "guard ${kind%%:*}: exit 1" "$?" 1
  has "guard ${kind%%:*}: names the problem" "${kind#*:}" "$T/out"
  has "guard ${kind%%:*}: says nothing was touched" "No fresh backups were taken, the VM was not touched." "$T/out"
  has "guard ${kind%%:*}: gives the start-over command" "LAB_RESTORE_START_OVER=1 bash scripts/lab.sh rebuild --restore" "$T/out"
  has "guard ${kind%%:*}: explains the empty snapshot" "snapshot EMPTY volumes" "$T/out"
done

write_guard_world complete
printf '{"started": "2026-11-03T15:28:20+01:00", "log": "/x/lab-rebuild.log"}' > "$T/marker.json"
guard_py
ok "guard: a marker refuses even a complete-looking VM" "$?" 1
has "guard marker: names the marker and the start time" "did not finish (marker $T/marker.json, started 2026-11-03T15:28:20+01:00, log /x/lab-rebuild.log)" "$T/out"
has "guard marker: names the finish command" "recover-files.yml --tags pause,restore,resume,verify" "$T/out"
has "guard marker: says how the marker goes away" "The verify step removes the marker" "$T/out"
LAB_RESTORE_GUARD_FORCE=1 guard_py
ok "guard marker: GUARD_FORCE does not skip the marker" "$?" 1
printf 'not json' > "$T/marker.json"
guard_py
ok "guard: an unreadable marker still refuses" "$?" 1
rm -f "$T/marker.json"
write_guard_world empty-gitea
LAB_RESTORE_GUARD_FORCE=1 guard_py
ok "guard: GUARD_FORCE=1 skips the live checks when there is no marker" "$?" 0
ok "guard: GUARD_FORCE=1 asks the cluster nothing" "$(wc -l < "$T/fake/calls" | tr -d ' ')" 0
echo down > "$T/fake/mode"
guard_py
ok "guard: kubectl down refuses" "$?" 1
has "guard: kubectl down says so" "FAIL guard: kubectl cannot read the cluster" "$T/out"
echo ok > "$T/fake/mode"
FAKE_DIR="$T/fake" PATH="$T/bin:$PATH" python3 "$S" --guard --force-all > "$T/out" 2> "$T/err"
ok "guard cannot be combined with --force-all" "$?" 2

# The exec test of the guard is the very test the restore accepts a restored volume with.
python3 - "$R" << 'PY'
import re, sys, yaml
R = sys.argv[1]
sys.path.insert(0, R + "/scripts")
import importlib.util
spec = importlib.util.spec_from_file_location("lbf", R + "/scripts/lab-backup-fresh.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
tasks = yaml.safe_load(open(R + "/ansible/tasks/recover-load.yml"))
targets = None
def walk(x):
    global targets
    if isinstance(x, dict):
        for v in x.values():
            if isinstance(v, list) and v and isinstance(v[0], dict) and "content_test" in v[0]:
                targets = v
            walk(v)
    elif isinstance(x, list):
        for v in x:
            walk(v)
walk(tasks)
assert targets, "no content_test in recover-load.yml"
want = {t["namespace"]: " ".join(str(t["content_test"]).split()) for t in targets}
have = {ns: " ".join(script.split()) for ns, claim, dep, script in mod.GUARD_VOLUMES}
assert want == have, (want, have)
PY
ok "guard data test equals the content_test of the file restore" "$?" 0
grep -Fq 'restore_guard()' "$R/scripts/lab.sh"; ok "lab.sh has the restore guard" "$?" 0
python3 - "$R/scripts/lab.sh" << 'PY'
import sys
text = open(sys.argv[1], encoding="utf-8").read()
body = text[text.index("rebuild_restore()"):text.index("\ncmd_rebuild()")]
g = body.index("restore_guard")
f = body.index("backup_fresh --force-all")
m = body.index("restore_marker_set")
t = body.index("vm_teardown")
assert g < f < m < t, (g, f, m, t)
assert body.count("restore_marker_set") == 1
PY
ok "lab.sh: guard, then fresh backups, then the marker, then the destroy" "$?" 0

echo
echo "$n checks, $fail failures"
[ "$fail" = 0 ]
