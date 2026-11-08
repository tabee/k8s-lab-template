#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
# Tests for scripts/pin-revision.py (issue 71): the patches that pin every git source of the root
# app to one commit while a rebuild runs. Uses PyYAML and, for the build part, `kubectl kustomize`
# (without them the suite prints SKIP for that part). Nothing outside the sandbox is touched.
# Usage: bash tests/pin-revision-tests.sh [repo root]
set -u
R=$(cd "${1:-$(dirname "${BASH_SOURCE[0]}")/..}" && pwd -P)
python3 -c 'import yaml' 2> /dev/null || { echo "SKIP: PyYAML is missing"; exit 0; }
mkdir -p "$HOME/.cache/lab-sh-tests"
T=$(mktemp -d -p "$HOME/.cache/lab-sh-tests")
trap 'rm -rf "$T"' EXIT
PIN=$R/scripts/pin-revision.py
URL=ssh://git@git.example.org/lab/k8s-lab.git
SHA=$(printf "ab%.0s" $(seq 20))
OTHER=$(printf "cd%.0s" $(seq 20))
fail=0
n=0
ok() { n=$((n + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else echo "FAIL $1 (is '$2', want '$3')"; fail=$((fail + 1)); fi; }
rc() { "$@" > /dev/null 2>&1; echo $?; }

echo "== Misuse"
ok "a branch name is refused" "$(rc python3 "$PIN" --repo-url "$URL" --revision main)" 2
ok "a short hash is refused" "$(rc python3 "$PIN" --repo-url "$URL" --revision 0123456)" 2
ok "an upper-case hash is refused" "$(rc python3 "$PIN" --repo-url "$URL" --revision "${SHA^^}")" 2
ok "--from-git needs a full hash" "$(rc python3 "$PIN" --repo-url "$URL" --revision "$SHA" --from-git main)" 2
ok "a repo url nobody reads: nothing to pin" "$(rc python3 "$PIN" --repo-url ssh://nobody/x.git --revision "$SHA" --repo "$R")" 2

echo "== Sandbox with every shape of source"
S=$T/repo
mkdir -p "$S/gitops/apps"
cat > "$S/gitops/apps/kustomization.yaml" <<YAML
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - single.yaml
  - multi.yaml
  - set.yaml
  - other.yaml
YAML
cat > "$S/gitops/apps/single.yaml" <<YAML
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: single, namespace: argocd}
spec:
  project: p
  source: {repoURL: $URL, targetRevision: main, path: gitops/single}
  destination: {server: https://kubernetes.default.svc, namespace: x}
YAML
cat > "$S/gitops/apps/multi.yaml" <<YAML
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: multi, namespace: argocd}
spec:
  project: p
  sources:
    - {repoURL: "https://charts.example.org", chart: c, targetRevision: 1.2.3}
    - {repoURL: $URL, targetRevision: main, ref: values}
    - {repoURL: $URL, path: gitops/multi}
  destination: {server: https://kubernetes.default.svc, namespace: x}
YAML
cat > "$S/gitops/apps/set.yaml" <<YAML
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata: {name: set, namespace: argocd}
spec:
  generators:
    - git: {repoURL: $URL, revision: main, directories: [{path: gitops/x/*}]}
  template:
    metadata: {name: "{{path.basename}}"}
    spec:
      project: p
      source: {repoURL: $URL, targetRevision: main, path: "{{path}}"}
      destination: {server: https://kubernetes.default.svc, namespace: x}
YAML
cat > "$S/gitops/apps/other.yaml" <<YAML
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: other, namespace: argocd}
spec:
  project: p
  source: {repoURL: ssh://git@secrets.example.org/lab/secrets.git, targetRevision: main, path: s}
  destination: {server: https://kubernetes.default.svc, namespace: x}
YAML
python3 "$PIN" --repo "$S" --repo-url "$URL" --revision "$SHA" --summary > "$T/patches.json" 2> "$T/err"
ok "the sandbox builds" "$?" 0
ok "valid JSON" "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$T/patches.json")" 3
ok "summary counts 5 sources in 3 objects" "$(grep -c 'pinned 5 source(s) in 3 object(s)' "$T/err")" 1
ok "the app of another repo is not touched" "$(grep -c '"other"' "$T/patches.json")" 0
ok "the chart source is not touched" "$(grep -c charts.example.org "$T/patches.json")" 0

if command -v kubectl > /dev/null 2>&1 && kubectl kustomize --help > /dev/null 2>&1; then
  echo "== kubectl kustomize with the patches injected (as the root app does)"
  python3 - "$S" "$T/patches.json" <<'PY'
import json, sys
d, pj = sys.argv[1], sys.argv[2]
patches = json.load(open(pj))
with open(d + "/gitops/apps/kustomization.yaml", "a") as fh:
    fh.write("patches:\n")
    for p in patches:
        fh.write("  - target: %s\n    patch: '%s'\n" % (json.dumps(p["target"]), p["patch"]))
PY
  (cd "$S" && kubectl kustomize gitops/apps > "$T/pinned.yaml" 2> "$T/kerr"); ok "kustomize build with the pin" "$?" 0
  python3 - "$T/pinned.yaml" "$URL" "$SHA" > "$T/check.txt" <<'PY'
import sys, yaml
f, url, sha = sys.argv[1:4]
bad = good = foreign = 0
def walk(n, parent=None):
    global bad, good, foreign
    if isinstance(n, dict):
        if "repoURL" in n:
            rev = n.get("revision" if parent == "git" else "targetRevision")
            if n["repoURL"] == url:
                if rev == sha: good += 1
                else: bad += 1
            else:
                if rev == sha: bad += 1
                else: foreign += 1
        for k, v in n.items(): walk(v, k)
    elif isinstance(n, list):
        for v in n: walk(v, parent)
for d in yaml.safe_load_all(open(f)):
    if d: walk(d)
print(good, bad, foreign)
PY
  ok "5 sources pinned, none wrong, 2 foreign ones untouched (chart, secrets repo)" "$(cat "$T/check.txt")" "5 0 2"
  ok "the chart version is unchanged" "$(grep -c 'targetRevision: 1.2.3' "$T/pinned.yaml")" 1
  ok "no source of the code repo still follows main" "$(grep -c 'argetRevision: main' "$T/pinned.yaml")" 1
  ok "(the one left is the secrets repo)" "$(grep -B2 'argetRevision: main' "$T/pinned.yaml" | grep -c secrets.example.org)" 1
else
  echo "SKIP: kubectl kustomize is missing (build part)"
fi

echo "== --from-git reads the commit, not the working tree"
git -C "$S" init -q
git -C "$S" checkout -q -b main 2> /dev/null
git -C "$S" -c user.name=t -c user.email=t@t add -A
git -C "$S" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m base
HEAD=$(git -C "$S" rev-parse HEAD)
# the working tree gets a new app that is NOT in the commit, and the patches for single.yaml are edited away
cat > "$S/gitops/apps/new.yaml" <<YAML
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: new, namespace: argocd}
spec:
  project: p
  source: {repoURL: $URL, targetRevision: main, path: gitops/new}
  destination: {server: https://kubernetes.default.svc, namespace: x}
YAML
sed -i 's/  - other.yaml/  - other.yaml\n  - new.yaml/' "$S/gitops/apps/kustomization.yaml"
python3 "$PIN" --repo "$S" --repo-url "$URL" --revision "$SHA" > "$T/wt.json" 2> /dev/null
ok "working tree: the uncommitted app is included" "$(grep -c '"new"' "$T/wt.json")" 1
python3 "$PIN" --repo "$S" --repo-url "$URL" --revision "$SHA" --from-git "$HEAD" > "$T/commit.json" 2> /dev/null
ok "--from-git: the uncommitted app is NOT included" "$(grep -c '"new"' "$T/commit.json")" 0
ok "--from-git: the three committed objects are" "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$T/commit.json")" 3
ok "--from-git: an unknown commit is refused" "$(rc python3 "$PIN" --repo "$S" --repo-url "$URL" --revision "$SHA" --from-git "$OTHER")" 2

echo "== The real repository"
REAL_URL=$(grep -h 'repoURL: ssh' "$R"/gitops/apps/docs.yaml | head -n 1 | awk '{ print $2 }')
python3 "$PIN" --repo "$R" --repo-url "$REAL_URL" --revision "$SHA" --summary > "$T/real.json" 2> "$T/real.err"
ok "the real gitops/apps can be pinned" "$?" 0
ok "every Application that reads the code repo is covered" \
  "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$T/real.json")" \
  "$(grep -lF "repoURL: $REAL_URL" "$R"/gitops/apps/*.yaml | wc -l)"

echo
echo "$n checks, $fail failures"
[ "$fail" = 0 ]
