#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
# Offline tests of the sync order inside the Argo CD app cnpg (third real restore, 2026-11-03):
# the plugin Deployment was created 10 min BEFORE its Certificates and waited for TLS secrets that did not exist.
#   1. the pins: values-plugin.yaml carries the wave, the app cnpg has ten retries
#   2. an ordering model of Argo CD (sync phase, wave, kind order, name; the kind order is copied from gitops-engine)
#      run over the resources of the plugin chart (fixture tests/argo-waves/*.tsv): Issuer and Certificates come
#      strictly before the Deployment; with the old values (no wave) the model reproduces the bug
#   3. no other app has a pod that mounts the secret of a cert-manager Certificate of the same app
#   4. optional: the real `helm template` of the cached chart equals the fixture and gives the same order
# No cluster, no network, no secret. Without PyYAML the suite prints SKIP.
# Refresh the fixture after a chart update: run this suite with the chart in the helm cache, the diff is printed.
# Usage: bash tests/argo-waves-tests.sh [repo root]
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
R=$(cd "${1:-$HERE/..}" && pwd -P)
fail=0
n=0
ok() { n=$((n + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else echo "FAIL $1 (actual '$2', expected '$3')"; fail=$((fail + 1)); fi; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

if ! python3 -c 'import yaml' 2> /dev/null; then
  echo "SKIP argo-waves-tests: PyYAML missing"
  exit 0
fi

FIX="$R/tests/argo-waves/plugin-barman-cloud-0.8.1.tsv"
APP="$R/gitops/apps/cnpg.yaml"
VAL="$R/gitops/platform/cnpg/values-plugin.yaml"

# The ordering model, one file for all checks: argo_model.py MODE [values file or chart render]
cat > "$T/model.py" << 'PY'
import sys, yaml

# gitops-engine pkg/sync/sync_tasks.go: known kinds in this order, every unknown kind (Certificate, Issuer ...) AFTER them
KINDS = """Namespace NetworkPolicy ResourceQuota LimitRange PodSecurityPolicy PodDisruptionBudget ServiceAccount Secret
SecretList ConfigMap StorageClass PersistentVolume PersistentVolumeClaim CustomResourceDefinition ClusterRole ClusterRoleList
ClusterRoleBinding ClusterRoleBindingList Role RoleList RoleBinding RoleBindingList Service DaemonSet Pod ReplicationController
ReplicaSet Deployment HorizontalPodAutoscaler StatefulSet Job CronJob IngressClass Ingress APIService
""".split()
ORDER = {k: i - len(KINDS) for i, k in enumerate(KINDS)}   # unknown kind -> 0 = last

def load_fixture(path):
    rows = []
    for line in open(path):
        if line.startswith("#") or not line.strip():
            continue
        kind, name, probe = line.rstrip("\n").split("\t")
        rows.append((kind, name, probe == "yes"))
    return rows

def tasks_from_fixture(rows, common):
    out = []
    for kind, name, takes in rows:
        wave = int((common or {}).get("argocd.argoproj.io/sync-wave", 0)) if takes else 0
        out.append((wave, kind, name))
    return out

def sync_order(tasks):
    # Sync(): one wave after the other; inside a wave sorted by kind order, then name; groups of one kind are applied
    # one after the other, a wave only ends when its resources are Healthy
    return sorted(tasks, key=lambda t: (t[0], ORDER.get(t[1], 0), t[2]))

def verdict(tasks):
    """Problems of the order, empty list = the Deployment starts only after Issuer and Certificates are Healthy."""
    bad = []
    wave = {(k, n): w for w, k, n in tasks}
    dep = [w for (k, n), w in wave.items() if k == "Deployment"]
    cert = [w for (k, n), w in wave.items() if k in ("Certificate", "Issuer")]
    if not dep or not cert:
        return ["no Deployment or no Certificate in the render"]
    if not max(cert) < min(dep):
        bad.append("Deployment wave %d is not after the Certificates/Issuer wave %d" % (min(dep), max(cert)))
    first = sync_order(tasks)
    pos = {(k, n): i for i, (w, k, n) in enumerate(first)}
    for (k, n), w in wave.items():
        if k in ("Certificate", "Issuer") and any(pos[(k, n)] > pos[(dk, dn)] for (dk, dn) in wave if dk == "Deployment") and w == min(dep):
            bad.append("%s %s is applied after the Deployment in the same wave" % (k, n))
    for (k, n), w in wave.items():
        if k in ("ServiceAccount", "ConfigMap", "Role", "RoleBinding", "ClusterRole", "ClusterRoleBinding", "CustomResourceDefinition") and w > min(dep):
            bad.append("%s %s comes after the Deployment" % (k, n))
    return bad

if __name__ == "__main__":
    mode, fixture = sys.argv[1], sys.argv[2]
    vals = yaml.safe_load(open(sys.argv[3])) if len(sys.argv) > 3 else {}
    common = vals.get("commonAnnotations")
    rows = load_fixture(fixture)
    if mode == "problems":
        for p in verdict(tasks_from_fixture(rows, common)):
            print(p)
    elif mode == "order":
        for w, k, n in sync_order(tasks_from_fixture(rows, common)):
            print("%d %s %s" % (w, k, n))
PY

echo "-- pins"
python3 - "$APP" "$VAL" << 'PY'
import sys, yaml
app = yaml.safe_load(open(sys.argv[1]))
val = yaml.safe_load(open(sys.argv[2]))
assert val["commonAnnotations"] == {"argocd.argoproj.io/sync-wave": "1"}, val.get("commonAnnotations")
assert app["spec"]["syncPolicy"]["retry"]["limit"] >= 10
assert app["spec"]["syncPolicy"]["retry"]["backoff"]["maxDuration"] == "3m"
assert val["certificate"]["createIssuer"] is True and val["certificate"]["createClientCertificate"] is True
PY
ok "values-plugin.yaml: commonAnnotations sync-wave \"1\" (a string, Argo CD reads annotations as strings)" "$?" 0
ok "the app cnpg has ten retries (a slow cert-manager must not end the sync)" "$(sed -n 's/^ *limit: *//p' "$APP" | head -1)" 10
ok "the app cnpg does not use Replace (waves need the normal apply)" "$(grep -c 'Replace=true' "$APP")" 0
ok "the chart version of the fixture is the pinned one" "$(sed -n 's/^# chart plugin-barman-cloud \([0-9.]*\),.*/\1/p' "$FIX")" "$(awk '/chart: plugin-barman-cloud/{f=1} f&&/targetRevision:/{print $2; exit}' "$APP")"
ok "the Certificates and the Issuer carry no wave of their own (the chart cannot set one)" "$(awk -F'\t' '$1=="Certificate"||$1=="Issuer"{print $3}' "$FIX" | sort -u | tr '\n' ' ')" "no "

echo "-- ordering model on the plugin chart"
python3 "$T/model.py" problems "$FIX" "$VAL" > "$T/new.out" 2>&1
ok "with the values of the repo: no ordering problem" "$(cat "$T/new.out")" ""
python3 "$T/model.py" order "$FIX" "$VAL" > "$T/order.out"
ok "the Deployment is in wave 1" "$(grep -c '^1 Deployment ' "$T/order.out")" 1
ok "the Certificates and the Issuer are in wave 0" "$(grep -cE '^0 (Certificate|Issuer) ' "$T/order.out")" 3
ok "the last wave-0 task is a custom resource (applied after the known kinds, before wave 1)" "$(awk '$1==0' "$T/order.out" | tail -1 | awk '{print $2}')" Issuer
ok "wave 1 holds ServiceAccount, Service and Deployment only" "$(awk '$1==1{print $2}' "$T/order.out" | tr '\n' ' ')" "ServiceAccount Service Deployment "
printf 'commonAnnotations: {}\n' > "$T/old.yaml"
python3 "$T/model.py" problems "$FIX" "$T/old.yaml" > "$T/old.out" 2>&1
has() { case $2 in *"$3"*) ok "$1" 1 1 ;; *) ok "$1" 0 1 ;; esac; }
has "old values (no wave): the model reports the bug" "$(cat "$T/old.out")" "is not after the Certificates"
has "old values: the Deployment is applied BEFORE the Certificates of its own wave" "$(cat "$T/old.out")" "applied after the Deployment in the same wave"
printf 'commonAnnotations:\n  argocd.argoproj.io/sync-wave: "0"\n' > "$T/zero.yaml"
python3 "$T/model.py" problems "$FIX" "$T/zero.yaml" > "$T/zero.out" 2>&1
has "wave 0 for everything is the same bug" "$(cat "$T/zero.out")" "is not after the Certificates"
python3 "$T/model.py" order "$FIX" "$T/old.yaml" | awk '$2=="Deployment"||$2=="Certificate"{print $2}' | tr '\n' ' ' > "$T/old.order"
ok "old order: Deployment, then Certificate, Certificate" "$(cat "$T/old.order")" "Deployment Certificate Certificate "

echo "-- other apps: no pod mounts the secret of a Certificate of its own app"
cat > "$T/scan.py" << 'PY'
import os, re, sys, yaml
R = sys.argv[1]
G = os.path.join(R, "gitops")
apps = {}   # app dir -> files
for sub in ("workloads", "platform", "charts"):
    for d in sorted(os.listdir(os.path.join(G, sub))):
        top = os.path.join(G, sub, d)
        files = [os.path.join(dp, f) for dp, _, fs in os.walk(top) for f in fs if f.endswith((".yaml", ".yml", ".tpl"))]
        apps[sub + "/" + d] = files
WL = re.compile(r"^\s*kind:\s*(Deployment|StatefulSet|DaemonSet|Job|CronJob)\s*$", re.M)
bad = []
seen = 0
for app, files in apps.items():
    secrets = set()
    for f in files:
        t = open(f).read()
        # a Certificate document: its secretName (also inside extraDeploy of a values file)
        for m in re.finditer(r"kind:\s*Certificate\b.*?(?:\n---|\Z)", t, re.S):
            secrets.update(re.findall(r"secretName:\s*[\"']?([A-Za-z0-9._-]+)", m.group(0)))
    for f in files:
        t = open(f).read()
        if not WL.search(t):
            continue
        seen += 1
        for s in secrets:
            if re.search(r"\b" + re.escape(s) + r"\b", t):
                bad.append("%s: %s mounts %s" % (app, os.path.relpath(f, R), s))
print("workload files checked:", seen)
for b in bad:
    print("PROBLEM", b)
sys.exit(1 if bad else 0)
PY
python3 "$T/scan.py" "$R" > "$T/scan.out" 2>&1
ok "no Deployment/StatefulSet/Job of an app uses a TLS secret that the same app gets from cert-manager" "$?" 0
mkdir -p "$T/neg/gitops/workloads/x" "$T/neg/gitops/platform" "$T/neg/gitops/charts"
printf 'kind: Certificate\nspec:\n  secretName: x-tls\n' > "$T/neg/gitops/workloads/x/certificate.yaml"
printf 'kind: Deployment\nspec:\n  volumes:\n    - secret:\n        secretName: x-tls\n' > "$T/neg/gitops/workloads/x/deployment.yaml"
python3 "$T/scan.py" "$T/neg" > "$T/neg.out" 2>&1
ok "the scan finds a pod that mounts the Certificate secret of its app (self-test)" "$?" 1
ok "the chart notes-site: the Certificate secret is only used by the IngressRoute" "$(grep -c 'notes-tls' "$R/gitops/charts/notes-site/templates/deployment.yaml")" 0

echo "-- real render of the chart (optional)"
CACHE=$(helm env HELM_REPOSITORY_CACHE 2> /dev/null || true)
CHART="${PLUGIN_CHART_TGZ:-$CACHE/plugin-barman-cloud-0.8.1.tgz}"
if command -v helm > /dev/null 2>&1 && [ -f "$CHART" ]; then
  helm template plugin-barman-cloud "$CHART" -n cnpg-system -f "$VAL" > "$T/render.yaml" 2> "$T/render.err"
  ok "helm template of the plugin chart with the repo values: exit 0" "$?" 0
  python3 - "$T/render.yaml" "$FIX" "$T/real.tsv" << 'PY'
import sys, yaml
rows = []
for d in yaml.safe_load_all(open(sys.argv[1])):
    if not d:
        continue
    a = d["metadata"].get("annotations") or {}
    rows.append((d["kind"], d["metadata"]["name"], a.get("argocd.argoproj.io/sync-wave")))
fix = [l.rstrip("\n").split("\t") for l in open(sys.argv[2]) if not l.startswith("#") and l.strip()]
# same resources as the fixture
assert sorted((k, n) for k, n, _ in rows) == sorted((k, n) for k, n, _ in fix), "the fixture differs from the chart render"
# the real annotation: exactly the resources of the fixture marked yes carry wave 1
for k, n, w in rows:
    want = "1" if [f for f in fix if f[0] == k and f[1] == n][0][2] == "yes" else None
    assert w == want, (k, n, w, want)
PY
  ok "the render has the resources of the fixture and the wave on exactly the marked ones" "$?" 0
  python3 - "$T/render.yaml" "$T/model.py" << 'PY'
import sys, yaml, importlib.util
spec = importlib.util.spec_from_file_location("m", sys.argv[2]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
tasks = []
for d in yaml.safe_load_all(open(sys.argv[1])):
    if d:
        tasks.append((int((d["metadata"].get("annotations") or {}).get("argocd.argoproj.io/sync-wave", 0)), d["kind"], d["metadata"]["name"]))
assert m.verdict(tasks) == [], m.verdict(tasks)
PY
  ok "the REAL render: Certificates and Issuer before the Deployment" "$?" 0
else
  echo "SKIP the real render: helm or $CHART is missing (helm pull cnpg/plugin-barman-cloud --version 0.8.1 -d \"\$(helm env HELM_REPOSITORY_CACHE)\")"
fi

echo
echo "$n checks, $fail failures"
[ "$fail" -eq 0 ]
