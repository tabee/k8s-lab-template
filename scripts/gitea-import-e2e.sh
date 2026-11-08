#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
# gitea-import-e2e.sh: MANUAL end-to-end test of scripts/gitea-import.sh on a workstation with Docker. Not part of ci-tests
# (needs Docker, internet for images and a few minutes). It builds a throwaway "production" Gitea (Postgres or SQLite,
# test users with known passwords, an org, a template repo, a wiki, webhooks, LFS) and a throwaway "lab" (k3s in Docker
# with Traefik, the real NetworkPolicies, the chart and values of this repo, a plain Postgres instead of CNPG, a fake
# Argo CD CRD) and runs the real import against it. Nothing touches your real clusters: every kubectl call uses its
# own kubeconfig file; all containers are named gie2e-*; `down` removes everything.
#
#   bash scripts/gitea-import-e2e.sh up                 build the throwaway lab (k3s, Postgres, Gitea)
#   bash scripts/gitea-import-e2e.sh source postgres    start a throwaway production Gitea (postgres | sqlite) and seed it
#   bash scripts/gitea-import-e2e.sh dump FORMAT        dump it as the VPS script does: age | sops (needs `source` first)
#   bash scripts/gitea-import-e2e.sh scenario [postgres|sqlite]   all of it: run 1, run 2 (SKIP), negative run, --replace
#   bash scripts/gitea-import-e2e.sh down               remove containers, network, scratch directory
#
# Environment: E2E_DIR (default /tmp/gie2e), E2E_K3S_IMAGE, E2E_GITEA_SRC_IMAGE, E2E_HTTPS_PORT (18443), E2E_API_PORT (16443).
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
E2E=${E2E_DIR:-/tmp/gie2e}
K3S_IMAGE=${E2E_K3S_IMAGE:-rancher/k3s:v1.34.1-k3s1}
SRC_IMAGE=${E2E_GITEA_SRC_IMAGE:-docker.gitea.com/gitea:1.27.3}
SRC_OLD_IMAGE=${E2E_GITEA_SRC_OLD_IMAGE:-docker.gitea.com/gitea:1.26.4}
HTTPS_PORT=${E2E_HTTPS_PORT:-18443}
API_PORT=${E2E_API_PORT:-16443}
HOST=git.lab.example
GITOPS="$ROOT/gitops/workloads/gitea"
export KUBECONFIG="$E2E/kubeconfig"
export SOPS_AGE_KEY_FILE="$E2E/age.key"
IMPORT=(bash "$HERE/gitea-import.sh" --cacert "$E2E/ca.crt" --resolve "$HOST:$HTTPS_PORT:127.0.0.1" --base-url "https://$HOST:$HTTPS_PORT" --age-key "$E2E/age.key")

say() { echo "e2e: $*"; }
die() { echo "e2e: ERROR: $*" >&2; exit 1; }
K() { kubectl -n gitea "$@"; }
pass=0
fail=0
expect() { # expect "label" EXPECTED_EXIT COMMAND... ; output goes to $E2E/last.out
  local label=$1 want=$2 rc=0
  shift 2
  "$@" >"$E2E/last.out" 2>&1 || rc=$?
  if [ "$rc" = "$want" ]; then pass=$((pass + 1)); say "PASS  $label (exit $rc)"; else fail=$((fail + 1)); say "FAIL  $label (exit $rc, wanted $want)"; tail -n 25 "$E2E/last.out" | sed 's/^/        /'; fi
}
expect_out() { # expect_out "label" REGEX: the last command printed REGEX
  if grep -Eq "$2" "$E2E/last.out"; then pass=$((pass + 1)); say "PASS  $1"; else fail=$((fail + 1)); say "FAIL  $1 (no match: $2)"; tail -n 25 "$E2E/last.out" | sed 's/^/        /'; fi
}

# ---------------------------------------------------------------- the throwaway lab
up() {
  command -v docker kubectl helm openssl age >/dev/null || die "needs docker, kubectl, helm, openssl, age"
  mkdir -p "$E2E"
  [ -f "$E2E/age.key" ] || age-keygen -o "$E2E/age.key" 2>/dev/null
  chmod 600 "$E2E/age.key"
  if ! docker inspect gie2e-k3s >/dev/null 2>&1; then
    say "starting k3s ($K3S_IMAGE)"
    docker run -d --name gie2e-k3s --privileged --tmpfs /run --tmpfs /var/run \
      -p "127.0.0.1:$API_PORT:6443" -p "127.0.0.1:$HTTPS_PORT:30443" "$K3S_IMAGE" \
      server --tls-san 127.0.0.1 --disable metrics-server --disable servicelb --flannel-backend=host-gw >/dev/null
    # Without servicelb (klipper needs the kernel module xt_multiport, missing on some hosts):
    # Traefik as NodePort, published by docker on $HTTPS_PORT.
    docker exec -i gie2e-k3s sh -c 'mkdir -p /var/lib/rancher/k3s/server/manifests && cat >/var/lib/rancher/k3s/server/manifests/traefik-nodeport.yaml' <<'YAML'
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata: {name: traefik, namespace: kube-system}
spec:
  valuesContent: |-
    service: {type: NodePort}
    ports:
      websecure: {nodePort: 30443}
YAML
  fi
  for _ in $(seq 1 60); do docker exec gie2e-k3s test -s /etc/rancher/k3s/k3s.yaml 2>/dev/null && break; sleep 2; done
  docker exec gie2e-k3s cat /etc/rancher/k3s/k3s.yaml | sed "s#https://127.0.0.1:6443#https://127.0.0.1:$API_PORT#" >"$KUBECONFIG"
  chmod 600 "$KUBECONFIG"
  for _ in $(seq 1 90); do kubectl get nodes 2>/dev/null | grep -q ' Ready' && break; sleep 2; done
  kubectl get nodes | grep -q ' Ready' || die "k3s node not ready"
  for _ in $(seq 1 90); do kubectl -n kube-system get pods -l app.kubernetes.io/name=traefik 2>/dev/null | grep -q ' 1/1' && break; sleep 3; done

  say "namespace, LimitRange, NetworkPolicies of this repo (Traefik namespace adapted: k3s ships it in kube-system)"
  kubectl apply -f "$GITOPS/manifests/namespace.yaml" -f "$GITOPS/manifests/limitrange.yaml" >/dev/null
  sed 's/kubernetes.io\/metadata.name: traefik/kubernetes.io\/metadata.name: kube-system/' "$GITOPS/manifests/networkpolicy.yaml" | kubectl apply -f - >/dev/null

  say "fake Argo CD (CRD + apps root and gitea with auto-sync)"
  kubectl apply -f - >/dev/null <<'YAML'
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata: {name: applications.argoproj.io}
spec:
  group: argoproj.io
  names: {kind: Application, listKind: ApplicationList, plural: applications, singular: application}
  scope: Namespaced
  versions:
    - name: v1alpha1
      served: true
      storage: true
      schema: {openAPIV3Schema: {type: object, x-kubernetes-preserve-unknown-fields: true}}
YAML
  kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  local app
  for app in root gitea; do
    kubectl apply -f - >/dev/null <<YAML
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: $app, namespace: argocd}
spec: {syncPolicy: {automated: {prune: true, selfHeal: true}}}
YAML
  done

  say "secrets and Postgres (plain Postgres 16 with TLS, role/database like CNPG: owner is NOT a superuser)"
  # random passwords, created once (a second `up` keeps them), never printed
  K get secret gitea-db-owner >/dev/null 2>&1 \
    || K create secret generic gitea-db-owner --from-literal=username=gitea --from-literal=password="$(openssl rand -hex 12)" >/dev/null
  K get secret gitea-admin >/dev/null 2>&1 \
    || K create secret generic gitea-admin --from-literal=username=labadmin --from-literal=password="$(openssl rand -hex 12)" >/dev/null
  [ -f "$E2E/pg.key" ] || openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj "/CN=pg" -keyout "$E2E/pg.key" -out "$E2E/pg.crt" 2>/dev/null
  K create secret generic pg-tls --from-file=tls.crt="$E2E/pg.crt" --from-file=tls.key="$E2E/pg.key" --dry-run=client -o yaml | K apply -f - >/dev/null
  K create configmap pg-init --from-literal=init.sh='#!/bin/sh
set -e
psql -v ON_ERROR_STOP=1 -U postgres -c "CREATE ROLE gitea LOGIN PASSWORD '"'"'$GITEA_PW'"'"'" -c "CREATE DATABASE gitea OWNER gitea"' --dry-run=client -o yaml | K apply -f - >/dev/null
  K apply -f - >/dev/null <<'YAML'
apiVersion: v1
kind: Pod
metadata: {name: gitea-db-1, labels: {app: e2e-pg}}
spec:
  securityContext: {runAsNonRoot: true, runAsUser: 70, runAsGroup: 70, fsGroup: 70, seccompProfile: {type: RuntimeDefault}}
  containers:
    - name: postgres
      image: postgres:16-alpine
      args: ["-c", "ssl=on", "-c", "ssl_cert_file=/certs/tls.crt", "-c", "ssl_key_file=/certs/tls.key"]
      env:
        - {name: POSTGRES_PASSWORD, value: e2e-superuser}
        - {name: PGDATA, value: /var/lib/postgresql/data/pgdata}
        - {name: GITEA_PW, valueFrom: {secretKeyRef: {name: gitea-db-owner, key: password}}}
      securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
      resources: {limits: {memory: 512Mi}}
      volumeMounts:
        - {name: data, mountPath: /var/lib/postgresql/data}
        - {name: run, mountPath: /var/run/postgresql}
        - {name: certs, mountPath: /certs}
        - {name: init, mountPath: /docker-entrypoint-initdb.d}
      readinessProbe: {exec: {command: [pg_isready, -U, postgres]}, periodSeconds: 3}
  volumes:
    - {name: data, emptyDir: {}}
    - {name: run, emptyDir: {}}
    - {name: certs, secret: {secretName: pg-tls, defaultMode: 0640}}
    - {name: init, configMap: {name: pg-init, defaultMode: 0755}}
---
apiVersion: v1
kind: Service
metadata: {name: gitea-db-rw}
spec: {selector: {app: e2e-pg}, ports: [{port: 5432}]}
---
apiVersion: v1
kind: Service
metadata: {name: gitea-db-pooler-rw}
spec: {selector: {app: e2e-pg}, ports: [{port: 5432}]}
YAML
  K wait --for=condition=Ready pod/gitea-db-1 --timeout=240s >/dev/null || { K describe pod gitea-db-1 | tail -n 20; die "Postgres pod not ready"; }

  say "Gitea chart with the real values (extraDeploy replaced by a plain Ingress with a self-signed certificate)"
  local ver
  ver=$(sed -n 's/^ *targetRevision: *"\{0,1\}\(12\.[0-9.]*\)"\{0,1\}.*/\1/p' "$ROOT/gitops/apps/gitea.yaml" | head -n 1)
  : "${ver:=12.7.0}"
  [ -f "$E2E/gitea-$ver.tgz" ] || (cd "$E2E" && helm pull gitea --repo https://dl.gitea.com/charts/ --version "$ver" >/dev/null)
  [ -f "$E2E/tls.key" ] || openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj "/CN=$HOST" -addext "subjectAltName=DNS:$HOST" \
    -keyout "$E2E/tls.key" -out "$E2E/ca.crt" 2>/dev/null
  K create secret tls gitea-tls --cert="$E2E/ca.crt" --key="$E2E/tls.key" --dry-run=client -o yaml | K apply -f - >/dev/null
  # This import-only fixture has no Keycloak; OIDC repair is covered by unattended-build tests.
  printf 'extraDeploy: []\npostExtraInitContainers: []\n' >"$E2E/values-override.yaml"
  helm upgrade --install gitea "$E2E/gitea-$ver.tgz" -n gitea -f "$GITOPS/values-gitea.yaml" -f "$E2E/values-override.yaml" --wait --timeout 8m >/dev/null \
    || { K get pods; K logs deploy/gitea --all-containers --tail=30 || true; die "helm install failed"; }
  K apply -f - >/dev/null <<YAML
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata: {name: gitea, annotations: {traefik.ingress.kubernetes.io/router.entrypoints: websecure, traefik.ingress.kubernetes.io/router.tls: "true"}}
spec:
  ingressClassName: traefik
  tls: [{hosts: [$HOST], secretName: gitea-tls}]
  rules: [{host: $HOST, http: {paths: [{path: /, pathType: Prefix, backend: {service: {name: gitea-http, port: {name: http}}}}]}}]
YAML
  for _ in $(seq 1 60); do
    curl -s --cacert "$E2E/ca.crt" --resolve "$HOST:$HTTPS_PORT:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$HOST:$HTTPS_PORT/api/healthz" 2>/dev/null | grep -q 200 && break
    sleep 3
  done
  say "lab is up: https://$HOST:$HTTPS_PORT (resolve to 127.0.0.1)"
}

down() {
  docker rm -f gie2e-k3s gie2e-src gie2e-src-pg >/dev/null 2>&1 || true
  docker network rm gie2e-net >/dev/null 2>&1 || true
  rm -rf "$E2E"
  say "removed gie2e-* containers, network and $E2E"
}

# ---------------------------------------------------------------- the throwaway production Gitea
source_up() {
  local variant=${1:-postgres} img=$SRC_IMAGE
  docker rm -f gie2e-src gie2e-src-pg >/dev/null 2>&1 || true
  docker network create gie2e-net >/dev/null 2>&1 || true
  local env=(-e USER_UID=1000 -e USER_GID=1000 -e GITEA__security__INSTALL_LOCK=true -e GITEA__security__SECRET_KEY=src-secret-for-test-only
    -e GITEA__server__ROOT_URL=http://localhost:13000/ -e GITEA__webhook__ALLOWED_HOST_LIST=private -e GITEA__server__LFS_START_SERVER=true
    -e GITEA__packages__ENABLED=true -e GITEA__actions__ENABLED=true)
  if [ "$variant" = postgres ]; then
    docker run -d --name gie2e-src-pg --network gie2e-net -e POSTGRES_USER=gitea -e POSTGRES_PASSWORD=srcpw -e POSTGRES_DB=gitea postgres:16-alpine >/dev/null
    sleep 6
    env+=(-e GITEA__database__DB_TYPE=postgres -e GITEA__database__HOST=gie2e-src-pg:5432 -e GITEA__database__NAME=gitea -e GITEA__database__USER=gitea -e GITEA__database__PASSWD=srcpw)
  else
    img=$SRC_OLD_IMAGE
    env+=(-e GITEA__database__DB_TYPE=sqlite3)
  fi
  docker run -d --name gie2e-src --network gie2e-net -p 127.0.0.1:13000:3000 "${env[@]}" "$img" >/dev/null
  for _ in $(seq 1 60); do curl -sf http://127.0.0.1:13000/api/healthz >/dev/null 2>&1 && break; sleep 2; done
  seed_source
}

seed_source() {
  local G=(docker exec -u git gie2e-src gitea) B=http://127.0.0.1:13000/api/v1
  "${G[@]}" admin user create --admin --username srcadmin --password 'Adm1n-Old-Pass!' --email srcadmin@example.test --must-change-password=false >/dev/null
  "${G[@]}" admin user create --username alice --password 'Alice-Old-Pass1!' --email alice@example.test --must-change-password=false >/dev/null
  "${G[@]}" admin user create --username bob --password 'Bob-Old-Pass1!' --email bob@example.test --must-change-password=false >/dev/null
  A() { curl -sf -u srcadmin:'Adm1n-Old-Pass!' -H Content-Type:application/json "$@"; }
  A $B/orgs -d '{"username":"acme","visibility":"private"}' >/dev/null
  A $B/orgs/acme/repos -d '{"name":"platform","auto_init":true,"private":true}' >/dev/null
  A $B/orgs/acme/repos -d '{"name":"tpl","auto_init":true,"private":true}' >/dev/null
  A $B/repos/acme/tpl -X PATCH -d '{"template":true}' >/dev/null
  A $B/repos/acme/platform/collaborators/alice -X PUT -d '{"permission":"write"}' >/dev/null
  curl -sf -u alice:'Alice-Old-Pass1!' -H Content-Type:application/json $B/user/repos -d '{"name":"notes","auto_init":true}' >/dev/null
  A $B/repos/acme/platform/hooks -d '{"type":"gitea","config":{"url":"http://example.invalid/hook","content_type":"json"},"events":["push"],"active":true}' >/dev/null
  A $B/orgs/acme/hooks -d '{"type":"gitea","config":{"url":"http://example.invalid/orghook","content_type":"json"},"events":["push"],"active":true}' >/dev/null
  A $B/repos/acme/platform/wiki/new -d '{"title":"Home","content_base64":"SGVsbG8gd2lraQ=="}' >/dev/null
  A $B/repos/acme/platform/issues -d '{"title":"first issue","body":"hello"}' >/dev/null
  A $B/repos/acme/platform/releases -d '{"tag_name":"v1.0","name":"v1"}' >/dev/null
  A $B/repos/acme/tpl/generate -d '{"owner":"acme","name":"fromtpl","git_content":true}' >/dev/null
  # an LFS object pushed over git with a real git-lfs pointer, when git-lfs is available
  if command -v git-lfs >/dev/null 2>&1; then
    local w
    w=$(mktemp -d)
    (cd "$w" && git clone -q "http://alice:Alice-Old-Pass1!@127.0.0.1:13000/alice/notes.git" n 2>/dev/null && cd n \
      && git lfs install --local >/dev/null && git lfs track '*.bin' >/dev/null && head -c 20000 /dev/urandom >big.bin \
      && git add . && git -c user.name=a -c user.email=a@example.test commit -qm lfs && git push -q origin HEAD 2>/dev/null) || say "LFS seeding skipped (push failed)"
    rm -rf "$w"
  else
    say "git-lfs not installed: no LFS object seeded (LFS path not exercised)"
  fi
  say "source seeded (3 users, org acme, 4 repos incl. 1 template, 2 webhooks, wiki, issue, release)"
}

# A user clones alice/notes with git-lfs from the lab and gets the 20000-byte LFS object (needs git-lfs).
verify_lfs() {
  command -v git-lfs >/dev/null 2>&1 || { say "SKIP  LFS download check (git-lfs not installed)"; return 0; }
  # git-lfs does its own name resolution (ignores http.curloptResolve): $HOST must resolve to 127.0.0.1 (/etc/hosts).
  getent hosts "$HOST" >/dev/null 2>&1 || { say "SKIP  LFS download check ($HOST does not resolve: add '127.0.0.1 $HOST' to /etc/hosts)"; return 0; }
  local w size
  w=$(mktemp -d)
  size=$(cd "$w" && GIT_TERMINAL_PROMPT=0 git -c http.sslCAInfo="$E2E/ca.crt" -c "http.curloptResolve=$HOST:$HTTPS_PORT:127.0.0.1" \
    clone -q "https://alice:Alice-Old-Pass1!@$HOST:$HTTPS_PORT/alice/notes.git" n >/dev/null 2>&1 && wc -c <n/big.bin) || size=0
  rm -rf "$w"
  if [ "${size:-0}" -eq 20000 ]; then pass=$((pass + 1)); say "PASS  LFS object downloads through the lab Gitea (20000 bytes)"; else fail=$((fail + 1)); say "FAIL  LFS object did not download (got ${size:-0} bytes)"; fi
}

make_dump() {
  local fmt=${1:-age} out
  [ -f "$E2E/age.key" ] || die "run 'up' first (creates the throwaway age key)"
  local pub
  pub=$(age-keygen -y "$E2E/age.key")
  out="$E2E/dump.$fmt"
  if [ "$fmt" = sops ]; then
    bash "$HERE/gitea-import-vps-dump.sh" --container gie2e-src --format sops --recipient "$pub" >"$out.json"
    out="$out.json"
  else
    bash "$HERE/gitea-import-vps-dump.sh" --container gie2e-src --recipient "$pub" >"$out"
  fi
  say "dump: $out ($(wc -c <"$out") bytes)"
  echo "$out"
}

# ---------------------------------------------------------------- the scenario
scenario() {
  local variant=${1:-postgres} dump
  [ -f "$KUBECONFIG" ] || up
  source_up "$variant"
  dump=$(make_dump age | tail -n 1)
  export GITEA_IMPORT_PSQL_IMAGE="ghcr.io/cloudnative-pg/postgresql:18.6-minimal-trixie@sha256:64abc98a4387361afd6821a3a99f975763bbd87bbdde9449e75ad6002528a318"
  export GITEA_IMPORT_VERIFY_LOGIN="alice:Alice-Old-Pass1! bob:Bob-Old-Pass1!"
  local pre
  pre=$(kubectl -n argocd get applications.argoproj.io root -o jsonpath='{.spec.syncPolicy.automated.prune}')
  say "== dry run"
  expect "dry-run changes nothing" 0 "${IMPORT[@]}" --no-backup --dry-run "$dump"
  expect_out "dry-run reports the manifest" '4 users|3 users'
  say "== run 1"
  expect "run 1: import and acceptance" 0 "${IMPORT[@]}" --no-backup "$dump"
  expect_out "run 1: IMPORT OK" 'IMPORT OK'
  expect_out "run 1: no FAIL line" '^  PASS' 
  ! grep -q '^  FAIL' "$E2E/last.out" || { fail=$((fail + 1)); say "FAIL  run 1 printed FAIL lines"; }
  [ "$(kubectl -n argocd get applications.argoproj.io root -o jsonpath='{.spec.syncPolicy.automated.prune}')" = "$pre" ] \
    && { pass=$((pass + 1)); say "PASS  Argo CD auto-sync restored"; } || { fail=$((fail + 1)); say "FAIL  Argo CD auto-sync not restored"; }
  verify_lfs
  say "== acceptance after loss of the cluster-only ConfigMap"
  K delete cm gitea-import-state >/dev/null
  expect "acceptance restores the saved import evidence without re-import" 0 "${IMPORT[@]}" accept
  expect_out "lost ConfigMap restored from the data volume" 'Restored gitea import evidence'
  say "== run 2 (same dump)"
  expect "run 2: SKIP" 0 "${IMPORT[@]}" --no-backup "$dump"
  expect_out "run 2 says SKIP" 'SKIP'
  say "== negative run: foreign content"
  K exec deploy/gitea -- gitea admin user create --username intruder --password 'Intr-Uder-123456!' --email i@example.test --must-change-password=false >/dev/null 2>&1 \
    || say "(could not create the foreign user)"
  expect "foreign content without --replace aborts" 1 "${IMPORT[@]}" --no-backup --reimport "$dump"
  expect_out "ABORT names --replace" 'ABORT.*--replace'
  expect "non-interactive --replace without --yes aborts" 1 "${IMPORT[@]}" --no-backup --reimport --replace "$dump" </dev/null
  expect "--replace --yes replaces" 0 "${IMPORT[@]}" --no-backup --reimport --replace --yes "$dump"
  expect "acceptance alone" 0 "${IMPORT[@]}" accept
  say "== sops format"
  dump=$(make_dump sops | tail -n 1)
  expect "sops dump: replace after previous import (no prompt: result of earlier import)" 0 "${IMPORT[@]}" --no-backup "$dump"
  say "results: $pass passed, $fail failed"
  [ "$fail" = 0 ]
}

case ${1:-} in
  up) up ;;
  down) down ;;
  source) source_up "${2:-postgres}" ;;
  dump) make_dump "${2:-age}" ;;
  scenario) shift; scenario "$@" ;;
  *) sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac
