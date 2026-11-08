#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
# Offline checks for Matrix (Synapse + Element Web): federation stays off,
# server_name has one source, the admin helper is idempotent, and customize
# pins serverName after a domain change. No cluster and no secret values.
# Usage: bash tests/matrix-tests.sh [repo root]
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
hasnt() { grep -Fq -- "$2" "$3"; ok "$1" "$?" 1; }

HS="$R/gitops/charts/matrix/templates/configmap-homeserver.yaml"
EL="$R/gitops/charts/matrix/templates/configmap-element.yaml"
VAL="$R/gitops/charts/matrix/values.yaml"
LAB="$R/infra/envs/local/lab.yaml"
NP="$R/gitops/workloads/matrix/manifests/networkpolicy.yaml"
CERT="$R/gitops/workloads/matrix/manifests/certificate.yaml"

echo "== user directory and Element defaults (taken over from the old server)"
has "user directory is on" "user_directory:" "$HS"
has "user directory searches all users" "search_all_users: true" "$HS"
has "element default theme is dark" '"default_theme": "dark"' "$EL"
has "element default country is CH" '"default_country_code": "CH"' "$EL"
has "element has no 3pid login" '"disable_3pid_login": true' "$EL"
hasnt "element has no call switch from the old server" "feature_group_calls" "$EL"
hasnt "homeserver has no call setting from the old server" "rtc_foci" "$HS"

echo "== federation off and one server name"
has "whitelist is an empty list" "federation_domain_whitelist: []" "$HS"
has "registration is off" "enable_registration: false" "$HS"
has "server well-known is off" "serve_server_wellknown: false" "$HS"
has "only the client listener" "names: [client]" "$HS"
hasnt "no federation listener" "names: [federation]" "$HS"
hasnt "no federation port in the homeserver template" "8448" "$HS"
has "homeserver uses the chart value" ".Values.serverName" "$HS"
has "element uses the chart value" ".Values.serverName" "$EL"
hasnt "homeserver template has no baked-in server name" "matrix.lab.example" "$HS"
hasnt "element template has no baked-in server name" "matrix.lab.example" "$EL"
ok "serverName line exists once" "$(grep -c '^serverName:' "$VAL")" 1
ok "matrix_server_name exists once" "$(grep -c '^matrix_server_name:' "$LAB")" 1
python3 - "$VAL" "$LAB" "$CERT" << 'PY'
import sys
import yaml
val, lab, cert = sys.argv[1:4]
values = yaml.safe_load(open(val, encoding="utf-8"))
lab_v = yaml.safe_load(open(lab, encoding="utf-8"))
doc = yaml.safe_load(open(cert, encoding="utf-8"))
names = sorted(doc["spec"]["dnsNames"])
domain = lab_v["domain"]
sys.exit(0 if values["serverName"] == lab_v["matrix_server_name"] and values["domain"] == domain and names == sorted(["matrix." + domain, "element." + domain]) else 1)
PY
ok "serverName, chart domain and certificate names agree" "$?" 0
hasnt "network policy has no general internet egress" "0.0.0.0/0" "$NP"
cmp -s "$R/gitops/workloads/whoami/limitrange.yaml" "$R/gitops/workloads/matrix/manifests/limitrange.yaml"
ok "matrix LimitRange matches whoami" "$?" 0
has "signing key is optional" "@optional:matrix-signing-key" "$R/secrets/matrix/matrix-signing-key.sops.yaml.example"
has "database user is the literal matrix" "user: matrix" "$HS"
has "k8up restic prefix is the matrix prefix" "bucket: k8up-k3s-lab/matrix" "$R/gitops/workloads/matrix/manifests/k8up-schedule.yaml"
has "cnpg prefix is the matrix prefix" "destinationPath: s3://cnpg-k3s-lab/matrix" "$R/gitops/workloads/matrix/manifests/objectstore.yaml"

python3 - "$R/gitops/workloads/matrix/manifests" << 'PY'
import sys
import yaml
d = sys.argv[1]
routes = [x for x in yaml.safe_load_all(open(d + "/ingressroute.yaml", encoding="utf-8")) if x and x["metadata"]["name"] == "matrix"][0]["spec"]["routes"]
mw = yaml.safe_load(open(d + "/middleware.yaml", encoding="utf-8"))
admin = [r for r in routes if "/_synapse/admin" in r["match"]]
rest = [r for r in routes if "/_synapse/admin" not in r["match"]]
good = (len(admin) == 1 and len(rest) == 1
        and admin[0]["match"].startswith("Host(") and admin[0].get("priority", 0) > 100
        and [m["name"] for m in admin[0]["middlewares"]] == [mw["metadata"]["name"]]
        and "middlewares" not in rest[0]
        and mw["spec"]["ipAllowList"]["sourceRange"] == ["192.0.2.1/32"])
sys.exit(0 if good else 1)
PY
ok "the admin API path has its own high-priority rule that only lets 127.0.0.1 in" "$?" 0

echo "== admin helper and signing decision"
python3 - "$R" > "$T/admin.out" 2>&1 << 'PY'
import importlib.util
import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

root = sys.argv[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


entry = load("matrix_entry", os.path.join(root, "gitops/charts/matrix/files/entrypoint.py"))
admin = load("matrix_admin", os.path.join(root, "gitops/charts/matrix/files/ensure-admin.py"))
fails = []


def check(name, cond):
    print(("OK   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


check("decide empty keeps", entry.decide_signing("", "") == "keep")
check("decide provided installs", entry.decide_signing("ed25519 a b", "") == "install")
check("decide existing keeps", entry.decide_signing("", "ed25519 a b") == "keep")
check("decide same keeps", entry.decide_signing("ed25519 a b", "ed25519 a b") == "keep")
check("decide different aborts", entry.decide_signing("ed25519 a b", "ed25519 a c") == "abort")
mac = admin.registration_mac("secret", "nonce", "alice", "s3cret")
check("registration mac matches the frozen vector", mac == "3479581ff311a69f01b44d2ef5584e63ae4c5e9e")

state = {"n": 0}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        return

    def _send(self, code, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self._send(200, {"nonce": "nonce"})

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length)
        state["body"] = raw.decode("utf-8")
        state["n"] += 1
        if state["n"] == 1:
            self._send(200, {"user_id": "@alice:example"})
        else:
            self._send(400, {"errcode": "M_USER_IN_USE"})


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
port = server.server_address[1]
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
base = "http://127.0.0.1:%d" % port
ok1, line1 = admin.ensure_admin(base, "alice", "s3cret", "secret")
ok2, line2 = admin.ensure_admin(base, "alice", "s3cret", "secret")
server.shutdown()
check("first call ensures the admin", ok1 and line1 == "matrix-admin: admin ensured")
check("second call finds the admin", ok2 and line2 == "matrix-admin: admin already present")
posted = json.loads(state["body"])
check("posted mac uses the frozen inputs", posted["mac"] == mac and posted["username"] == "alice" and posted["admin"] is True)
check("helper lines do not contain the password", "s3cret" not in line1 and "s3cret" not in line2)
sys.exit(1 if fails else 0)
PY
admin_rc=$?
while IFS= read -r line; do
  case $line in
    "OK   "*) n=$((n + 1)); echo "$line" ;;
    "FAIL "*) n=$((n + 1)); fail=$((fail + 1)); echo "$line" ;;
    *) echo "$line" ;;
  esac
done < "$T/admin.out"
ok "admin helper and signing decision" "$admin_rc" 0

echo "== customize pins serverName"
G=$T/pin
mkdir -p "$G"
cp -a "$R/gitops" "$G/gitops"
cp "$R/zensical.toml" "$G/zensical.toml"
ST="$G/gitops/values-state.yaml"
URL=$(sed -n 's/^repo_url: *//p' "$ST")
GW=$(sed -n 's/^gateway: *//p' "$ST")
CIDR=$(sed -n 's/^vm_cidr: *//p' "$ST")
IP=$(sed -n 's/^vm_ip: *//p' "$ST")
EDGE=$(sed -n 's/^edge_ingress_cidrs: *//p' "$ST")
# The pin matters when the identity contains the lab domain (the default of a fresh instance, matrix.<domain>): the domain
# replacement would rewrite it. The tracked lab.yaml may hold an imported name outside that domain, so the case is built here.
OLDDOM=$(sed -n 's/^domain: *//p' "$ST")
SN="matrix.$OLDDOM"
sed -i "s/^serverName: .*$/serverName: $SN/" "$G/gitops/charts/matrix/values.yaml"
python3 "$R/scripts/lab-customize.py" --repo "$G" --domain test.local --repo-url "$URL" --gateway "$GW" --vm-cidr "$CIDR" --vm-ip "$IP" --edge-ingress-cidrs "$EDGE" --server-name "$SN" > "$T/pin1.out" 2>&1
ok "customize with a new domain: exit 0" "$?" 0
has "customize reports the serverName pin" "(serverName)" "$T/pin1.out"
has "serverName stayed the lab identity" "serverName: $SN" "$G/gitops/charts/matrix/values.yaml"
has "chart domain followed the lab domain" "domain: test.local" "$G/gitops/charts/matrix/values.yaml"
python3 "$R/scripts/lab-customize.py" --repo "$G" --domain test.local --repo-url "$URL" --gateway "$GW" --vm-cidr "$CIDR" --vm-ip "$IP" --edge-ingress-cidrs "$EDGE" --server-name "$SN" > "$T/pin2.out" 2>&1
ok "second customize: exit 0" "$?" 0
has "second customize is a no-op" "SKIP: gitops/ already matches" "$T/pin2.out"
python3 "$R/scripts/lab-customize.py" --repo "$G" --domain test.local --repo-url "$URL" --gateway "$GW" --vm-cidr "$CIDR" --vm-ip "$IP" --edge-ingress-cidrs "$EDGE" --server-name other.example --check > "$T/pin3.out" 2>&1
ok "check with a different server name: exit 1" "$?" 1
has "check names the serverName drift" "lab.yaml says 'other.example'" "$T/pin3.out"
# The identity of lab.yaml (an imported homeserver is outside the lab domain): a domain change leaves it alone
SNL=$(sed -n 's/^matrix_server_name: *//p' "$LAB")
G2=$T/pin2
mkdir -p "$G2"
cp -a "$R/gitops" "$G2/gitops"
cp "$R/zensical.toml" "$G2/zensical.toml"
python3 "$R/scripts/lab-customize.py" --repo "$G2" --domain test.local --repo-url "$URL" --gateway "$GW" --vm-cidr "$CIDR" --vm-ip "$IP" --edge-ingress-cidrs "$EDGE" --server-name "$SNL" > "$T/pin4.out" 2>&1
ok "customize with the server_name of lab.yaml and a new domain: exit 0" "$?" 0
has "the server_name of lab.yaml is in the chart values after a domain change" "serverName: $SNL" "$G2/gitops/charts/matrix/values.yaml"

echo "== helm and ansible syntax"
if command -v helm > /dev/null 2>&1; then
  helm template matrix "$R/gitops/charts/matrix" --namespace matrix > "$T/helm.out" 2> "$T/helm.err"
  ok "helm template: exit 0" "$?" 0
  has "rendered whitelist is empty" "federation_domain_whitelist: []" "$T/helm.out"
  has "rendered registration is off" "enable_registration: false" "$T/helm.out"
  hasnt "rendered chart has no federation port" "8448" "$T/helm.out"
  python3 -c 'import yaml,sys; list(yaml.safe_load_all(open(sys.argv[1], encoding="utf-8")))' "$T/helm.out"
  ok "helm output is YAML" "$?" 0
  python3 - "$T/helm.out" << 'PY'
import json
import sys
import yaml

docs = [d for d in yaml.safe_load_all(open(sys.argv[1], encoding="utf-8")) if d]
cms = {d["metadata"]["name"]: d for d in docs if d.get("kind") == "ConfigMap"}
hs = yaml.safe_load(cms["matrix-homeserver"]["data"]["homeserver.yaml"])
el = json.loads(cms["matrix-element-config"]["data"]["config.json"])
ok = (
    hs.get("user_directory") == {"enabled": True, "search_all_users": True}
    and el.get("default_theme") == "dark"
    and el.get("default_country_code") == "CH"
    and el.get("disable_3pid_login") is True
    and hs.get("federation_domain_whitelist") == []
)
sys.exit(0 if ok else 1)
PY
  ok "rendered: user directory, Element defaults and an empty whitelist parse as YAML and JSON" "$?" 0
  # Pod restart on config change: the Deployments are chart templates so they can carry a checksum of the rendered ConfigMaps
  # (a mounted ConfigMap is updated in place, Synapse and Element read it only at start).
  for variant in a:oidcAllowExistingUsers=false b:oidcAllowExistingUsers=true c:serverName=other.example a2:oidcAllowExistingUsers=false; do
    helm template matrix "$R/gitops/charts/matrix" --namespace matrix --set "${variant#*:}" > "$T/helm-${variant%%:*}.out" 2> /dev/null
  done
  python3 - "$T" << 'PY'
import re
import sys
import yaml


def annotations(variant):
    docs = [d for d in yaml.safe_load_all(open("%s/helm-%s.out" % (sys.argv[1], variant), encoding="utf-8")) if d]
    deps = {d["metadata"]["name"]: d for d in docs if d.get("kind") == "Deployment"}
    return {n: deps[n]["spec"]["template"]["metadata"].get("annotations", {}) for n in ("synapse", "element")}


a, a2, b, c = (annotations(v) for v in ("a", "a2", "b", "c"))
bad = []
for name, key in (("synapse", "checksum/config"), ("synapse", "checksum/scripts"), ("element", "checksum/config")):
    if not re.fullmatch(r"[0-9a-f]{64}", a[name].get(key, "")):
        bad.append("%s %s is not a sha256" % (name, key))
if a != a2:
    bad.append("annotations are not stable for the same values")
if a["synapse"]["checksum/config"] == b["synapse"]["checksum/config"]:
    bad.append("synapse checksum/config does not change with oidcAllowExistingUsers")
if a["synapse"]["checksum/scripts"] != b["synapse"]["checksum/scripts"]:
    bad.append("synapse checksum/scripts changed without a script change")
if a["element"]["checksum/config"] != b["element"]["checksum/config"]:
    bad.append("element checksum/config changed with a switch it does not render")
if a["synapse"]["checksum/config"] == c["synapse"]["checksum/config"]:
    bad.append("synapse checksum/config does not change with serverName")
if a["element"]["checksum/config"] == c["element"]["checksum/config"]:
    bad.append("element checksum/config does not change with serverName")
print("\n".join(bad))
sys.exit(1 if bad else 0)
PY
  ok "rendered Deployments: checksum annotations are present, stable, and change with the rendered ConfigMaps" "$?" 0
  has "synapse Deployment template carries checksum/config of the homeserver ConfigMap" 'checksum/config: '"'"'{{ include (print $.Template.BasePath "/configmap-homeserver.yaml") . | sha256sum }}'"'" "$R/gitops/charts/matrix/templates/deployment-synapse.yaml"
  has "element Deployment template carries checksum/config of the Element ConfigMap" 'checksum/config: '"'"'{{ include (print $.Template.BasePath "/configmap-element.yaml") . | sha256sum }}'"'" "$R/gitops/charts/matrix/templates/deployment-element.yaml"
  ok "no second copy of the Deployments among the raw manifests" "$(ls "$R"/gitops/workloads/matrix/manifests/deployment-*.yaml 2> /dev/null | wc -l | tr -d ' ')" 0
else
  echo "SKIP: helm is missing (chart not rendered)"
fi
if command -v ansible-playbook > /dev/null 2>&1; then
  (cd "$R/ansible" && ANSIBLE_LOCALHOST_WARNING=False ansible-playbook --syntax-check verify-matrix.yml > "$T/syn.out" 2>&1)
  ok "verify-matrix.yml: syntax check" "$?" 0
  (cd "$R/ansible" && ANSIBLE_LOCALHOST_WARNING=False ansible-playbook --syntax-check restore-drill-matrix.yml > "$T/syn.out" 2>&1)
  ok "restore-drill-matrix.yml: syntax check" "$?" 0
  (cd "$R/ansible" && ANSIBLE_LOCALHOST_WARNING=False ansible-playbook --syntax-check restore-drill.yml > "$T/syn.out" 2>&1)
  ok "restore-drill.yml imports: syntax check" "$?" 0
else
  echo "SKIP: ansible-playbook is missing"
fi

echo
echo "$n checks, $fail failures"
[ "$fail" = 0 ]
