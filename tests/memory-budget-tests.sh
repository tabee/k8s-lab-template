#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
# Tests for the memory budget of issue #9 (scripts/memory-budget.py, the lab-limit markers, the LimitRange
# copies, ansible/verify-budget.yml), without a cluster:
#   1. check: green, over budget, no limit, bad limit, pending counts, kube-system and finished pods do not,
#      memory pressure, bad input
#   2. sample: peaks from a fake `kubectl top` (the maximum wins, a second run keeps it, normalized pod names)
#   3. report and apply on a copy of the repo: LOWER is written (EDIT), the second run is all SKIP, a limit is
#      never raised, a limit below peak x 1.2 is flagged, the reserve may rise, the doc table is refreshed
#   4. the repo itself: every marker parses and is unique, the LimitRange copies are identical
#   5. verify-budget.yml passes the syntax check
# Usage: bash tests/memory-budget-tests.sh [repo root]
set -u
export PYTHONDONTWRITEBYTECODE=1
R=$(cd "${1:-$(dirname "${BASH_SOURCE[0]}")/..}" && pwd -P)
mkdir -p "$HOME/.cache/lab-sh-tests"
T=$(mktemp -d -p "$HOME/.cache/lab-sh-tests")
# shellcheck disable=SC2064
trap "rm -rf '$T'" EXIT
fail=0
n=0
ok() { n=$((n + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else echo "FAIL $1 (is '$2', want '$3')"; fail=$((fail + 1)); fi; }
has() { grep -Fq -- "$2" "$3"; ok "$1" "$?" 0; }
hasnot() { ! grep -Fq -- "$2" "$3"; ok "$1" "$?" 0; }
MB="$R/scripts/memory-budget.py"

# ---------- helpers: build the JSON of pods and nodes
# pod NS NAME PHASE CONTAINER=LIMIT... (LIMIT "-" = no limit)
pods_json() {
  python3 - "$@" << 'PY'
import json, sys
items = []
for spec in sys.argv[1:]:
    ns, name, phase, *ctrs = spec.split(",")
    containers = []
    for c in ctrs:
        cname, limit = c.split("=")
        res = {} if limit == "-" else {"limits": {"memory": limit}}
        containers.append({"name": cname, "resources": res})
    items.append({"metadata": {"namespace": ns, "name": name}, "status": {"phase": phase}, "spec": {"containers": containers}})
print(json.dumps(items))
PY
}
node_json() { printf '[{"metadata":{"name":"k3s-lab"},"status":{"conditions":[{"type":"MemoryPressure","status":"%s"},{"type":"DiskPressure","status":"False"}]}}]' "$1"; }
# check TOTAL RESERVE PODS NODES -> $T/out, exit code of the tool
check() {
  printf '{"memory_mib": %s, "reserve_mib": %s, "disk_gb": 60, "pods": %s, "nodes": %s}' "$1" "$2" "$3" "$4" | python3 "$MB" check > "$T/out" 2>&1
}

echo "== check"
P_OK=$(pods_json "gitea,gitea-abc-12345,Running,gitea=1Gi" "docs,docs-x-y,Running,web=256Mi,builder=512Mi")
check 8192 1536 "$P_OK" "$(node_json False)"; ok "within budget: exit 0" "$?" 0
has "within budget: sum of 1792 MiB" "SUM of work pods                      3         1792" "$T/out"
has "within budget: BUDGET OK" "BUDGET OK: 0 problem(s)" "$T/out"
check 2000 1536 "$P_OK" "$(node_json False)"; ok "over budget: exit 1" "$?" 1
has "over budget: OVERBUDGET named" "OVERBUDGET the memory limits add up to 1792 MiB, the budget is 464 MiB" "$T/out"
has "over budget: names the remedy" "bash scripts/lab.sh budget" "$T/out"
check 1792 0 "$P_OK" "$(node_json False)"; ok "exactly at the budget: exit 0" "$?" 0
P_NOLIMIT=$(pods_json "gitea,gitea-abc-12345,Running,gitea=-")
check 8192 1536 "$P_NOLIMIT" "$(node_json False)"; ok "container without limit: exit 1" "$?" 1
has "no limit: NOLIMIT names the container" "NOLIMIT gitea/gitea-abc-12345/gitea has no memory limit" "$T/out"
P_BAD=$(pods_json "gitea,gitea-abc-12345,Running,gitea=lots")
check 8192 1536 "$P_BAD" "$(node_json False)"; ok "unreadable limit: exit 1" "$?" 1
has "unreadable limit: BADLIMIT" "BADLIMIT gitea/gitea-abc-12345/gitea" "$T/out"
P_PEND=$(pods_json "gitea,a,Pending,x=4Gi" "gitea,b,Succeeded,y=64Gi" "gitea,c,Failed,z=64Gi" "kube-system,coredns-1,Running,coredns=64Gi")
check 8192 1536 "$P_PEND" "$(node_json False)"; ok "pending counts, finished pods and kube-system do not: exit 0" "$?" 0
has "pending: 4096 MiB counted" "4096" "$T/out"
P_SIDECAR='[{"metadata":{"namespace":"gitea","name":"gitea-db-1"},"status":{"phase":"Running"},"spec":{"containers":[{"name":"postgres","resources":{"limits":{"memory":"512Mi"}}}],"initContainers":[{"name":"bootstrap-controller","resources":{"limits":{"memory":"512Mi"}}},{"name":"plugin-barman-cloud","restartPolicy":"Always","resources":{"limits":{"memory":"256Mi"}}}]}}]'
check 8192 1536 "$P_SIDECAR" "$(node_json False)"; ok "native sidecar counts, plain init container does not: exit 0" "$?" 0
has "sidecar: 512 + 256 MiB counted" "768" "$T/out"
check 8192 1536 "$P_OK" "$(node_json True)"; ok "memory pressure: exit 1" "$?" 1
has "memory pressure: PRESSURE named" "PRESSURE node k3s-lab reports MemoryPressure=True" "$T/out"
check 8192 1536 "[]" "[]"; ok "empty cluster: exit 0" "$?" 0
printf 'not json' | python3 "$MB" check > "$T/out" 2>&1; ok "bad input: exit 2" "$?" 2
printf '{"memory_mib": 1}' | python3 "$MB" check > "$T/out" 2>&1; ok "missing keys: exit 2" "$?" 2
has "bad input: says what is needed" "stdin must be JSON with memory_mib, reserve_mib, pods, nodes" "$T/out"

echo "== sample"
# Fake kubectl: prints the files top-pods.txt, top-nodes.txt and nodes.json from $FAKE.
mkdir -p "$T/fake"
cat > "$T/fake/kubectl" << 'STUB'
#!/usr/bin/env bash
case "$*" in
  "top pods -A --containers --no-headers") cat "$FAKE/top-pods.txt" ;;
  "top nodes --no-headers") cat "$FAKE/top-nodes.txt" ;;
  "get nodes -o json") cat "$FAKE/nodes.json" ;;
  *) echo "unexpected: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$T/fake/kubectl"
export FAKE="$T/fake" KUBECTL="$T/fake/kubectl"
cat > "$T/fake/top-pods.txt" << 'TOP'
gitea   gitea-5d9f7c8b6d-abcde   gitea   12m   300Mi
gitea   gitea-db-1               postgres 5m   150Mi
gitea   backup-gitea-files-x7k2p-9qwer   backup  20m   90Mi
kube-system   coredns-76f75df574-zzzzz   coredns   2m   30Mi
TOP
printf 'k3s-lab   120m   3%%   1500Mi   19%%\n' > "$T/fake/top-nodes.txt"
printf '{"items":[{"status":{"conditions":[{"type":"MemoryPressure","status":"False"}]}}]}' > "$T/fake/nodes.json"
python3 "$MB" sample --out "$T/peaks.json" --duration 5 --interval 0.2 --stop-file "$T/stop" > "$T/out" 2>&1 &
SP=$!
sleep 1
sed -i 's/300Mi/700Mi/' "$T/fake/top-pods.txt"
sleep 1
: > "$T/stop"
wait "$SP"; ok "sample ends with the stop file: exit 0" "$?" 0
python3 - "$T/peaks.json" << 'PY' > "$T/peaks.txt"
import json, sys
d = json.load(open(sys.argv[1]))
for k in sorted(d["containers"]):
    print(k, d["containers"][k]["peak_mib"])
print("node", d["node"]["used_mib_max"], d["node"]["overhead_mib_max"], d["node"]["kube_system_mib_max"], d["node"]["pressure_seen"])
PY
has "pod name without the ReplicaSet hash, maximum wins" "gitea/gitea/gitea 700" "$T/peaks.txt"
has "StatefulSet-style index is cut" "gitea/gitea-db/postgres 150" "$T/peaks.txt"
has "job pod name is normalized" "gitea/backup-gitea-files-x7k2p/backup 90" "$T/peaks.txt"
has "node peak, overhead (node minus pods) and kube-system" "node 1500.0 " "$T/peaks.txt"
has "no pressure seen" "False" "$T/peaks.txt"
cp "$T/peaks.json" "$T/peaks.keep"
sed -i 's/700Mi/100Mi/' "$T/fake/top-pods.txt"
python3 "$MB" sample --out "$T/peaks.json" --duration 0.5 --interval 0.2 > "$T/out" 2>&1; ok "second run: exit 0" "$?" 0
python3 -c '
import json, sys
a, b = (json.load(open(f)) for f in sys.argv[1:3])
sys.exit(0 if b["containers"]["gitea/gitea/gitea"]["peak_mib"] == 700 and b["samples"] > a["samples"] else 1)' "$T/peaks.keep" "$T/peaks.json"
ok "second run keeps the earlier maximum and adds samples" "$?" 0
printf '{"items":[{"status":{"conditions":[{"type":"MemoryPressure","status":"True"}]}}]}' > "$T/fake/nodes.json"
python3 "$MB" sample --out "$T/peaks2.json" --duration 0.5 --interval 0.2 > "$T/out" 2>&1
has "pressure during sampling is recorded" '"pressure_seen": true' "$T/peaks2.json"
printf 'k3s-lab Ready' > "$T/fake/nodes.json"
python3 "$MB" sample --out "$T/peaks4.json" --duration 0.5 --interval 0.2 > "$T/out" 2>&1; ok "unreadable node JSON does not lose the sample: exit 0" "$?" 0
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/fake/kubectl-bad"; chmod +x "$T/fake/kubectl-bad"
KUBECTL="$T/fake/kubectl-bad" python3 "$MB" sample --out "$T/peaks3.json" --duration 3 --interval 0.05 > "$T/out" 2>&1; ok "kubectl top never works: exit 1" "$?" 1
has "kubectl top failing says why" "metrics-server not ready" "$T/out"

echo "== report and apply on a copy of the repo"
C="$T/repo"
mkdir -p "$C/docs/reference"
# Committed state, not the working tree: an uncommitted adoption must not change the fixture.
git -C "$R" archive HEAD gitops ansible infra docs/reference/memory-budget.md | tar -x -C "$C"
# Adoption tests use fixed input limits, independent of later right-sizing of the repository.
python3 - "$C" << 'PYFIX'
from pathlib import Path
import re, sys
root = Path(sys.argv[1])
fixtures = {
    "ansible/roles/argocd_bootstrap/templates/values.yaml.j2": {
        "argocd/argocd-server/server": "512Mi", "argocd/argocd-repo-server/repo-server": "512Mi"},
    "gitops/platform/traefik/values.yaml": {"traefik/traefik/traefik": "256Mi"},
}
for name, limits in fixtures.items():
    path = root / name
    lines = path.read_text().splitlines()
    for marker, limit in limits.items():
        indices = [i for i, line in enumerate(lines) if "# lab-limit: " + marker in line]
        assert len(indices) == 1
        i = indices[0]
        lines[i] = re.sub(r"memory: \d+(?:Mi|Gi)", "memory: " + limit, lines[i])
    path.write_text("\n".join(lines) + "\n")
PYFIX
# A marker inside a dot folder (ansible/.ansible/collections: installed, gitignored) does not count: the
# NOMARKER line for default/unmarked/app below proves it.
mkdir -p "$C/ansible/.ansible/collections/x"
printf '%s\n' '    memory: 64Mi  # lab-limit: default/unmarked/app' > "$C/ansible/.ansible/collections/x/values.yaml"
# Peaks for four real markers: server (lower), repo-server (peak high: keep), traefik (over: flag), gitea (no peak).
cat > "$T/fixture.json" << 'JSON'
{"containers": {"argocd/argocd-server/server": {"peak_mib": 100, "samples": 9},
                "argocd/argocd-repo-server/repo-server": {"peak_mib": 400, "samples": 9},
                "traefik/traefik/traefik": {"peak_mib": 300, "samples": 9},
                "gitea/backup-gitea-files/backup": {"peak_mib": 200, "samples": 9},
                "default/unmarked/app": {"peak_mib": 10, "samples": 9}},
 "node": {"used_mib_max": 2500, "overhead_mib_max": 1000, "kube_system_mib_max": 300, "pressure_seen": false},
 "samples": 9, "measured": "2026-10-30"}
JSON
python3 "$MB" report --peaks "$T/fixture.json" --repo "$C" > "$T/report.txt" 2>&1; ok "report: exit 0" "$?" 0
has "report: server lowers 512Mi -> 160Mi" "-> 160Mi" "$T/report.txt"
has "report: traefik is flagged" "FLAG: the limit is below peak x 1.2" "$T/report.txt"
has "report: marker without a peak" "NOPEAK" "$T/report.txt"
has "report: peak without a marker" "NOMARKER default/unmarked/app" "$T/report.txt"
has "report: reserve needs raising" "(RAISE)" "$T/report.txt"
LIM() { grep -h "lab-limit: $2\( \|$\)" "$C/$1" | sed 's/.*memory: *\([0-9]*[MG]i\).*/\1/'; }
F_ARGO=ansible/roles/argocd_bootstrap/templates/values.yaml.j2
F_TRAEFIK=gitops/platform/traefik/values.yaml
BEFORE_SERVER=$(LIM "$F_ARGO" "argocd/argocd-server/server")
BEFORE_TRAEFIK=$(LIM "$F_TRAEFIK" "traefik/traefik/traefik")
BEFORE_REPO=$(LIM "$F_ARGO" "argocd/argocd-repo-server/repo-server")
RES_BEFORE=$(sed -n 's/^memory_reserve_mib: *\([0-9]*\).*/\1/p' "$C/infra/envs/local/lab.yaml")
python3 "$MB" apply --peaks "$T/fixture.json" --repo "$C" --dry-run > "$T/out" 2>&1; ok "apply --dry-run: exit 0" "$?" 0
ok "apply --dry-run writes nothing" "$(LIM "$F_ARGO" "argocd/argocd-server/server")" "$BEFORE_SERVER"
python3 "$MB" apply --peaks "$T/fixture.json" --repo "$C" > "$T/apply1.txt" 2>&1; ok "apply: exit 0" "$?" 0
has "apply: EDIT for the server" "EDIT  ansible/roles/argocd_bootstrap/templates/values.yaml.j2" "$T/apply1.txt"
ok "apply: server limit is now 160Mi" "$(LIM "$F_ARGO" "argocd/argocd-server/server")" 160Mi
ok "apply: a limit over 70 % of peak is kept (repo-server)" "$(LIM "$F_ARGO" "argocd/argocd-repo-server/repo-server")" "$BEFORE_REPO"
ok "apply: a flagged limit is not raised (traefik)" "$(LIM "$F_TRAEFIK" "traefik/traefik/traefik")" "$BEFORE_TRAEFIK"
grep -q "lab-limit: argocd/argocd-server/server" "$C/$F_ARGO"; ok "apply: the marker stays" "$?" 0
RES_AFTER=$(sed -n 's/^memory_reserve_mib: *\([0-9]*\).*/\1/p' "$C/infra/envs/local/lab.yaml")
python3 -c 'import sys; sys.exit(0 if int(sys.argv[2]) > int(sys.argv[1]) else 1)' "$RES_BEFORE" "$RES_AFTER"; ok "apply: the reserve rose ($RES_BEFORE -> $RES_AFTER)" "$?" 0
has "apply: reserve comment points to the doc" "measured peaks, see docs/reference/memory-budget.md" "$C/infra/envs/local/lab.yaml"
has "apply: doc table has the server row" '| `argocd/argocd-server/server` | 160Mi | 100Mi | 62 |' "$C/docs/reference/memory-budget.md"
has "apply: doc table keeps the markers" "<!-- memory-budget:end -->" "$C/docs/reference/memory-budget.md"
cp -a "$C" "$T/repo-after1"
python3 "$MB" apply --peaks "$T/fixture.json" --repo "$C" > "$T/apply2.txt" 2>&1; ok "apply again: exit 0" "$?" 0
hasnot "apply again: no EDIT line" "EDIT " "$T/apply2.txt"
has "apply again: 0 changes" "0 change(s)" "$T/apply2.txt"
diff -r --no-dereference "$T/repo-after1" "$C" > /dev/null; ok "apply again: the tree is byte-identical" "$?" 0
python3 "$MB" report --peaks "$T/fixture.json" --repo "$C" > "$T/report2.txt" 2>&1
hasnot "report after apply: nothing left to lower" " LOWER " "$T/report2.txt"
printf '{"containers": {}, "node": {}, "samples": 0, "measured": ""}' > "$T/empty.json"
python3 "$MB" apply --peaks "$T/empty.json" --repo "$C" > "$T/out" 2>&1; ok "apply without peaks: exit 2" "$?" 2
python3 "$MB" report --peaks "$T/nothing.json" --repo "$C" > "$T/out" 2>&1; ok "report without a peaks file: exit 0 (empty table)" "$?" 0
printf 'bad: memory: 64Mi # lab-limit: onlytwo/parts\n' > "$C/gitops/bad-marker.yaml"
python3 "$MB" report --peaks "$T/fixture.json" --repo "$C" > "$T/out" 2>&1; ok "a marker that is not ns/workload/container: exit 2" "$?" 2

echo "== the repo itself"
python3 - "$R" << 'PY' > "$T/markers.txt" 2>&1
import importlib.util, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("mb", Path(sys.argv[1]) / "scripts/memory-budget.py")
mb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mb)
found = mb.find_markers(Path(sys.argv[1]))
seen = {}
bad = 0
for path, idx, mib, specs in found:
    for s in specs:
        key = "/".join(s)
        if key in seen:
            print("DUPLICATE", key, path, idx + 1, "and", seen[key])
            bad += 1
        seen[key] = "%s:%d" % (path, idx + 1)
    if mib < mb.FLOOR_MIB:
        print("BELOW FLOOR", path, idx + 1)
        bad += 1
    # A right-sized limit must not fall below its request (the API rejects that pod).
    import re
    preceding = path.read_text().splitlines()[max(0, idx - 5):idx]
    if any("requests:" in line for line in preceding):
        quantities = [m.group(1) for line in preceding if (m := re.search(r"memory: ([0-9]+(?:Mi|Gi))", line))]
        if quantities and mb.parse_mib(quantities[-1]) > mib:
            print("REQUEST ABOVE LIMIT", path, idx + 1, quantities[-1], mib)
            bad += 1
print("markers", len(found), "problems", bad)
PY
has "every marker parses, is unique and is at least the floor" "problems 0" "$T/markers.txt"
N=$(sed -n 's/^markers \([0-9]*\) .*/\1/p' "$T/markers.txt")
python3 -c 'import sys; sys.exit(0 if int(sys.argv[1]) >= 20 else 1)' "${N:-0}"; ok "at least 20 markers exist ($N)" "$?" 0
LR_A="$R/gitops/workloads/whoami/limitrange.yaml"
for f in gitops/workloads/docs/limitrange.yaml gitops/workloads/db-lab/limitrange.yaml gitops/workloads/gitea/manifests/limitrange.yaml gitops/workloads/matrix/manifests/limitrange.yaml gitops/workloads/gitea-runner/limitrange.yaml gitops/charts/notes-site/templates/limitrange.yaml; do
  cmp -s "$LR_A" "$R/$f"; ok "LimitRange copy identical: $f" "$?" 0
done
has "LimitRange is named lab-memory" "name: lab-memory" "$LR_A"
has "LimitRange has memory only: max 1Gi" "memory: 1Gi" "$LR_A"
hasnot "LimitRange sets no CPU value" "cpu:" "$LR_A"
if command -v helm > /dev/null; then
  helm template t "$R/gitops/charts/notes-site" --set site.name=t,site.host=t.example.test,site.repo=ssh://git@x/y.git 2> /dev/null > "$T/chart.yaml"
  has "the notes chart renders the LimitRange" "kind: LimitRange" "$T/chart.yaml"
else
  echo "SKIP: helm is missing"
fi
has "the login proxy of the notes sites carries a lab-limit marker" "# lab-limit: notes-*/notes-oauth2-proxy/oauth2-proxy" "$R/gitops/charts/notes-site/templates/oauth2-proxy.yaml"
has "the doc names the login proxy RAM (24 MiB request, 64 MiB limit)" "24 MiB Arbeitsspeicher, 10m CPU" "$R/docs/reference/memory-budget.md"
has "lab.yaml has memory_reserve_mib" "memory_reserve_mib:" "$R/infra/envs/local/lab.yaml"
has "the doc has the table markers" "<!-- memory-budget:begin -->" "$R/docs/reference/memory-budget.md"

echo "== verify-budget.yml"
if command -v ansible-playbook > /dev/null; then
  (cd "$R/ansible" && ansible-playbook --syntax-check verify-budget.yml > "$T/out" 2>&1); ok "syntax check" "$?" 0
else
  echo "SKIP: ansible-playbook is missing"
fi
has "the playbook calls the tool" "memory-budget.py" "$R/ansible/verify-budget.yml"

echo
echo "$n checks, $fail failures"
[ "$fail" = 0 ]
