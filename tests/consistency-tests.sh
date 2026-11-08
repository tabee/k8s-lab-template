#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
# Tests for the drift check of issue #10 (scripts/consistency-check.py, ansible/verify-consistency.yml),
# without a cluster:
#   1. the committed repo is consistent (the baseline of every deviation below)
#   2. every kind of deviation turns the check red, with the right check id
#   3. bad input is refused (exit 2)
#   4. the playbook itself: green on a copy of the repo, red when one copy in gitops/ is changed
# Needs: python3 with PyYAML. ansible-playbook is optional (SKIP line without it).
# Usage: bash tests/consistency-tests.sh [repo root]
set -u
export PYTHONDONTWRITEBYTECODE=1
R=$(cd "${1:-$(dirname "${BASH_SOURCE[0]}")/..}" && pwd -P)
python3 -c 'import yaml' 2> /dev/null || { echo "SKIP: python3 PyYAML is missing"; exit 0; }
mkdir -p "$HOME/.cache/lab-sh-tests"
T=$(mktemp -d -p "$HOME/.cache/lab-sh-tests")
# shellcheck disable=SC2064
trap "rm -rf '$T'" EXIT
fail=0
n=0
ok() { n=$((n + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else echo "FAIL $1 (is '$2', want '$3')"; fail=$((fail + 1)); fi; }
has() { grep -Fq -- "$2" "$3"; ok "$1" "$?" 0; }

# Expected values: read from the committed files the same way the playbook gets them from lab.yaml
# (the test must not depend on lab.local.yaml of the person who runs it).
GW=$(sed -n 's/^gateway: *//p' "$R/infra/envs/local/lab.yaml")
VMIP=$(sed -n 's/^vm_ip: *//p' "$R/infra/envs/local/lab.yaml")
DOMAIN=$(sed -n 's/^domain: *//p' "$R/infra/envs/local/lab.yaml")
PROBE=$(sed -n 's/^egress_probe_image: *//p' "$R/ansible/inventory/group_vars/all/egress.yml")
S3PORT=$(sed -n 's/^backup_s3_port: *//p' "$R/ansible/inventory/group_vars/all/backup_s3.yml")
REPO_CIDR=$(sed -n '/lab-egress:repo-cidrs BEGIN/,/lab-egress:repo-cidrs END/s/.*cidr: *//p' "$R/gitops/workloads/argocd/networkpolicy.yaml")
REPO_PORT=$(sed -n '/lab-egress:repo-port BEGIN/,/lab-egress:repo-port END/s/.*port: *//p' "$R/gitops/workloads/argocd/networkpolicy.yaml")
MSN=$(sed -n 's/^matrix_server_name: *//p' "$R/infra/envs/local/lab.yaml")
REPO_CIDRS_JSON=$(python3 -c 'import json, sys; print(json.dumps(sys.argv[1].splitlines()))' "$REPO_CIDR")
REPO_CIDRS_CSV=$(python3 -c 'import sys; print(",".join(sys.argv[1].splitlines()))' "$REPO_CIDR")
cat > "$T/expect.json" << JSON
{"vm_ip": "$VMIP", "gateway": "$GW", "s3_port": $S3PORT, "repo_cidrs": $REPO_CIDRS_JSON, "repo_port": $REPO_PORT,
 "domain": "$DOMAIN", "probe_image": "$PROBE", "revision": "main", "matrix_server_name": "$MSN",
 "gateway_files": ["gitops/workloads/db-lab/objectstore.yaml", "gitops/workloads/gitea/manifests/objectstore.yaml",
                   "gitops/workloads/gitea/manifests/k8up-schedule.yaml",
                   "gitops/workloads/matrix/manifests/objectstore.yaml",
                   "gitops/workloads/matrix/manifests/k8up-schedule.yaml"]}
JSON

# A fresh copy of gitops/ for every case.
fresh() { rm -rf "$T/case"; mkdir -p "$T/case"; cp -r "$R/gitops" "$T/case/gitops"; }
run() { python3 "$R/scripts/consistency-check.py" --repo "$T/case" --expect "$T/expect.json" > "$T/out" 2>&1; }
# red NAME CHECK-ID: the last run is red and names the check id.
red() { run; ok "$1: red" "$?" 1; has "$1: names [$2]" "MISMATCH [$2]" "$T/out"; }
# edit FILE OLD NEW [COUNT]: exact; OLD must occur exactly COUNT times (default 1) in the copy, all are replaced.
edit() {
  python3 - "$T/case/$1" "$2" "$3" "${4:-1}" << 'PY'
import sys
path, old, new, count = sys.argv[1:5]
text = open(path, encoding="utf-8").read()
if text.count(old) != int(count):
    sys.exit("edit: %r found %d times in %s, expected %s" % (old, text.count(old), path, count))
open(path, "w", encoding="utf-8").write(text.replace(old, new))
PY
  ok "setup: edit $1" "$?" 0
}

echo "== baseline"
fresh; run; ok "committed gitops/ is consistent" "$?" 0
has "baseline: OK line" "OK: " "$T/out"
# Folders that only exist on an operator machine (ansible/.ansible/collections, gitignored) are never read.
fresh; mkdir -p "$T/case/gitops/platform/.hidden"
printf '%s\n' 'kind: NetworkPolicy' 'broken: [unclosed' > "$T/case/gitops/platform/.hidden/np.yaml"
run; ok "a broken NetworkPolicy file in a dot folder is not read" "$?" 0

echo "== deviations"
fresh; edit gitops/workloads/db-lab/objectstore.yaml "http://$GW:$S3PORT" "http://$GW:9"; red "gateway file: other S3 port" gateway
fresh; edit gitops/workloads/gitea/manifests/k8up-schedule.yaml "http://$GW:$S3PORT" "http://10.9.9.1:$S3PORT"; red "gateway file: other gateway" gateway
fresh; edit gitops/workloads/gitea/manifests/networkpolicy.yaml "          port: $S3PORT" "          port: 9" 2; red "gitea policy: other S3 port" netpol
fresh; edit gitops/workloads/db-lab/networkpolicy.yaml "cidr: $VMIP/32" "cidr: 10.9.9.50/32" 2; red "db-lab policy: other API address" netpol
fresh; edit gitops/workloads/docs/networkpolicy.yaml "          port: $REPO_PORT" "          port: 2299"; red "docs policy: other git port" netpol
fresh; edit gitops/platform/traefik/manifests/networkpolicy.yaml "          port: 8444" "          port: 8445"; red "traefik policy: other admin port" traefik
fresh; edit gitops/platform/traefik/values.yaml "    exposedPort: 8444" "    exposedPort: 8444
    port: 9444"; red "traefik values: other admin container port" traefik
fresh; edit gitops/platform/traefik/values.yaml "    port: 8000
" ""; red "traefik values: web port not explicit" traefik
fresh; edit gitops/workloads/gitea/values-gitea.yaml "DOMAIN: git.$DOMAIN" "DOMAIN: git.other.test"; red "gitea DOMAIN outside the lab domain" domain
fresh; edit gitops/workloads/matrix/manifests/objectstore.yaml "http://$GW:$S3PORT" "http://$GW:9"; red "matrix gateway file: other S3 port" gateway
fresh; edit gitops/workloads/matrix/manifests/networkpolicy.yaml "cidr: $VMIP/32" "cidr: 10.9.9.50/32" 3; red "matrix policy: other API address" netpol
fresh; edit gitops/charts/matrix/values.yaml "serverName: $MSN" "serverName: other.example"; red "matrix serverName differs from lab.yaml" matrix
DIGEST=$(printf '%s' "$PROBE" | sed 's/.*@sha256://')
fresh; sed -i "s/$DIGEST/$(printf 'a%.0s' $(seq 64))/" "$T/case/gitops/workloads/docs/deployment.yaml"; red "docs builder digest differs from the probe image" images
fresh; sed -i "s/$DIGEST/$(printf 'b%.0s' $(seq 64))/" "$T/case/gitops/charts/notes-site/values.yaml"; red "notes builder digest differs from the probe image" images
WEBD=$(sed -n 's/.*web: .*@sha256://p' "$R/gitops/charts/notes-site/values.yaml")
fresh; sed -i "s/$WEBD/$(printf 'c%.0s' $(seq 64))/" "$T/case/gitops/charts/notes-site/values.yaml"; red "notes web digest differs from the docs web image" images
fresh; edit gitops/apps/whoami.yaml "targetRevision: main" "targetRevision: dev"; red "Application on another branch" revision
fresh; edit gitops/apps/notes.yaml "revision: main" "revision: dev"; red "ApplicationSet generator on another branch" revision
fresh; cp "$T/case/gitops/apps/whoami.yaml" "$T/case/gitops/apps/extra.yaml"; red "an application file that kustomization.yaml does not list" kustomization
fresh; edit gitops/apps/kustomization.yaml "  - whoami.yaml
" ""; red "a listed application that was removed from kustomization.yaml" kustomization
fresh; edit gitops/apps/kustomization.yaml "  - whoami.yaml" "  - whoami.yaml
  - gone.yaml"; red "kustomization.yaml lists a file that does not exist" kustomization
fresh; rm "$T/case/gitops/apps/kustomization.yaml"; red "kustomization.yaml missing" kustomization

echo "== bad input"
python3 "$R/scripts/consistency-check.py" --repo "$R" --expect "$T/missing.json" > "$T/out" 2>&1; ok "missing expectation file: exit 2" "$?" 2
echo '{"vm_ip": "1.2.3.4"}' > "$T/partial.json"
python3 "$R/scripts/consistency-check.py" --repo "$R" --expect "$T/partial.json" > "$T/out" 2>&1; ok "incomplete expectation: exit 2" "$?" 2

echo "== playbook"
if ! command -v ansible-playbook > /dev/null 2>&1; then
  echo "SKIP: ansible-playbook is missing"
elif [ "${REPO_CIDR%/32}" = 203.0.113.10 ]; then
  echo "SKIP: the repo address is still the placeholder (public copy): run 'bash scripts/lab.sh repo-egress --resolve' first"
else
  P=$T/pb
  mkdir -p "$P"
  cp -r "$R/ansible" "$R/scripts" "$R/gitops" "$P/"
  mkdir -p "$P/infra/envs"
  cp -r "$R/infra/envs/local" "$P/infra/envs/local"
  rm -f "$P/infra/envs/local/lab.local.yaml"
  printf 'repo_egress_cidrs: %s\n' "$REPO_CIDRS_CSV" > "$P/infra/envs/local/lab.local.yaml"
  # Match the generated tree even when the default source differs from the selected mirror.
  STATE_URL=$(sed -n 's/^repo_url: //p' "$R/gitops/values-state.yaml")
  case "$STATE_URL" in
    ssh://git@github.com/*)
      printf 'source: github\ngithub_repo_url: %s\ngithub_egress_cidrs: %s\n' "$STATE_URL" "$REPO_CIDRS_CSV" \
        >> "$P/infra/envs/local/lab.local.yaml" ;;
    *) printf 'repo_url: %s\n' "$STATE_URL" >> "$P/infra/envs/local/lab.local.yaml" ;;
  esac
  rm -rf "$P/ansible/.ansible"
  (cd "$P/ansible" && ansible-playbook -i inventory/local.yml verify-consistency.yml > "$T/pb.out" 2>&1)
  ok "playbook: green on a copy of the repo" "$?" 0
  has "playbook: reports the check count" "0 mismatches" "$T/pb.out"
  sed -i "s/$DIGEST/$(printf 'd%.0s' $(seq 64))/" "$P/gitops/workloads/docs/deployment.yaml"
  (cd "$P/ansible" && ansible-playbook -i inventory/local.yml verify-consistency.yml > "$T/pb.out" 2>&1)
  ok "playbook: red when one copy in gitops/ differs" "$?" 2
  has "playbook: names the check" "MISMATCH [images]" "$T/pb.out"
fi

echo
echo "$n checks, $fail failures"
[ "$fail" = 0 ]
