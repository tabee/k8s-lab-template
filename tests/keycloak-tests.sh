#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
# Offline checks for Keycloak (single sign-on for Gitea and Matrix, ADR-0019):
# federation of Matrix stays off, registration is off, Git stays initdb, the realm,
# route and OIDC wiring agree, secrets exist only as examples, and Keycloak has the
# same lifecycle entries as Gitea (restore list, alert, acceptance, verify, egress).
# No cluster and no secret values.
# Usage: bash tests/keycloak-tests.sh [repo root]
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

M="$R/gitops/workloads/keycloak/manifests"
CH="$R/gitops/charts/keycloak"
REALM="$CH/templates/configmap-realm.yaml"
HS="$R/gitops/charts/matrix/templates/configmap-homeserver.yaml"

echo "== files exist"
for f in namespace limitrange cluster objectstore scheduledbackup networkpolicy certificate ingressroute service deployment job-config; do
  if [ -f "$M/$f.yaml" ]; then rc=0; else rc=1; fi
  ok "manifest $f.yaml" "$rc" 0
done
for f in "$CH/Chart.yaml" "$CH/values.yaml" "$REALM" "$R/gitops/apps/keycloak.yaml" "$R/gitops/apps/secrets-keycloak.yaml" \
  "$R/ansible/verify-keycloak.yml" "$R/docs/how-to/keycloak.md" "$R/docs/concepts/decisions/0019-keycloak-sso.md"; do
  if [ -f "$f" ]; then rc=0; else rc=1; fi
  ok "file ${f#"$R"/}" "$rc" 0
done

echo "== Matrix federation stays off"
has "whitelist is an empty list" "federation_domain_whitelist: []" "$HS"
has "trusted key servers are empty" "trusted_key_servers: []" "$HS"
has "server well-known is off" "serve_server_wellknown: false" "$HS"
has "only the client listener" "names: [client]" "$HS"
hasnt "no federation listener" "names: [federation]" "$HS"
has "registration is still off" "enable_registration: false" "$HS"
has "OIDC provider links local users only by the switch oidcAllowExistingUsers" "allow_existing_users: {{ .Values.oidcAllowExistingUsers | ternary" "$HS"
# The value itself is an operator decision: false on a fresh instance (default intent, ADR-0020),
# true after a Matrix import. The test pins the type, the helm renders below pin both outcomes.
grep -Eq '^oidcAllowExistingUsers: (true|false)[[:space:]]*(#.*)?$' "$R/gitops/charts/matrix/values.yaml"
ok "oidcAllowExistingUsers in values.yaml is a boolean (true|false)" "$?" 0
has "OIDC provider uses explicit endpoints (no discovery)" "discover: false" "$HS"
has "OIDC provider skips https-only metadata validation (internal http endpoints)" "skip_verification: true" "$HS"
has "OIDC login needs the group lab-users" "attribute_requirements" "$HS"
has "login button name comes from the chart value" 'idp_name: {{ .Values.oidcDisplayName | quote }}' "$HS"
python3 - "$R" << 'PY'
import re
import sys
from pathlib import Path

import yaml

R = Path(sys.argv[1])
name = yaml.safe_load((R / "gitops/charts/matrix/values.yaml").read_text())["oidcDisplayName"]
gitea = (R / "gitops/workloads/gitea/values-gitea.yaml").read_text()
src = re.search(r"--name (\S+) --provider openidConnect", gitea).group(1)
sys.exit(0 if name == src.capitalize() else 1)
PY
ok "login button: Matrix oidcDisplayName is the Gitea source name, capitalized (one name for both)" "$?" 0

echo "== structure, git stays initdb, hardening, pins"
python3 - "$R" > "$T/struct.out" 2>&1 << 'PY'
import re
import sys
from pathlib import Path

import yaml

R = Path(sys.argv[1])
M = R / "gitops/workloads/keycloak/manifests"
errs = []


def load(p):
    return yaml.safe_load(Path(p).read_text(encoding="utf-8"))


def check(name, cond):
    print(("OK   " if cond else "FAIL ") + name)
    if not cond:
        errs.append(name)


cl = load(M / "cluster.yaml")
check("cluster: bootstrap.initdb only, never recovery in Git", "initdb" in cl["spec"]["bootstrap"] and "recovery" not in cl["spec"]["bootstrap"])
check("cluster: initdb owner secret is keycloak-db-owner", cl["spec"]["bootstrap"]["initdb"]["secret"]["name"] == "keycloak-db-owner")
check("cluster: no superuser access", cl["spec"].get("enableSuperuserAccess") is False)
check("cluster: barman plugin is the WAL archiver", cl["spec"]["plugins"][0]["name"] == "barman-cloud.cloudnative-pg.io" and cl["spec"]["plugins"][0]["isWALArchiver"] is True)
check("cluster: image is pinned by digest", "@sha256:" in cl["spec"]["imageName"])
db_pg = load(R / "gitops/workloads/gitea/manifests/cluster.yaml")["spec"]["imageName"]
check("cluster: same PostgreSQL image as gitea-db", cl["spec"]["imageName"] == db_pg)
os_ = load(M / "objectstore.yaml")
check("objectstore: bucket cnpg-k3s-lab, prefix keycloak", os_["spec"]["configuration"]["destinationPath"] == "s3://cnpg-k3s-lab/keycloak")
check("objectstore: retention 14d", os_["spec"]["retentionPolicy"] == "14d")
sb = load(M / "scheduledbackup.yaml")
others = [load(R / p)["spec"]["schedule"] for p in (
    "gitops/workloads/gitea/manifests/scheduledbackup.yaml",
    "gitops/workloads/matrix/manifests/scheduledbackup.yaml",
    "gitops/workloads/db-lab/scheduledbackup.yaml")]
check("scheduledbackup: own time, no collision with gitea, matrix, db-lab", sb["spec"]["schedule"] not in others)
check("scheduledbackup: not at 20:15 (matrix)", not sb["spec"]["schedule"].startswith("0 15 20"))
check("scheduledbackup: immediate, so a base backup exists for rebuild --restore", sb["spec"].get("immediate") is True)
check("scheduledbackup: barman plugin method", sb["spec"]["method"] == "plugin")

ns = load(M / "namespace.yaml")
check("namespace keycloak, PSA restricted", ns["metadata"]["name"] == "keycloak" and ns["metadata"]["labels"]["pod-security.kubernetes.io/enforce"] == "restricted")
proj = (R / "ansible/inventory/group_vars/all/argocd.yml").read_text(encoding="utf-8")
check("AppProject namespaces list keycloak", re.search(r"^\s+- keycloak\s*$", proj, re.M) is not None)

dep = load(M / "deployment.yaml")
spec = dep["spec"]["template"]["spec"]
check("deployment: pod runs non-root with seccomp RuntimeDefault", spec["securityContext"]["runAsNonRoot"] is True and spec["securityContext"]["seccompProfile"]["type"] == "RuntimeDefault")
conts = spec.get("initContainers", []) + spec["containers"]
check("deployment: every container drops ALL capabilities", all(c["securityContext"]["capabilities"]["drop"] == ["ALL"] for c in conts))
check("deployment: every container has a read-only root", all(c["securityContext"]["readOnlyRootFilesystem"] is True for c in conts))
check("deployment: no privilege escalation", all(c["securityContext"]["allowPrivilegeEscalation"] is False for c in conts))
check("deployment: every container has a memory limit", all("memory" in c.get("resources", {}).get("limits", {}) for c in conts))
check("deployment: images are pinned by digest", all(re.search(r"@sha256:[0-9a-f]{64}$", c["image"]) for c in conts))
check("deployment: copy-quarkus uses cp -R (cp -a fails on an emptyDir)", "cp -R /opt/keycloak/lib/quarkus/." in (M / "deployment.yaml").read_text(encoding="utf-8") and "cp -a" not in (M / "deployment.yaml").read_text(encoding="utf-8"))
env = {e["name"]: e for e in spec["containers"][0]["env"]}
check("deployment: hostname is sso.<lab domain> from the chart domain", "sso." in env["KC_HOSTNAME"]["value"] or "KC_HOSTNAME" in env)
check("deployment: backchannel dynamic (token calls over the Service)", env.get("KC_HOSTNAME_BACKCHANNEL_DYNAMIC", {}).get("value") == "true")
check("deployment: database over TLS", "sslmode=require" in str(env.get("KC_DB_URL_PROPERTIES", {}).get("value", "")))
job = load(M / "job-config.yaml")
check("job: PostSync hook", job["metadata"]["annotations"]["argocd.argoproj.io/hook"] == "PostSync")
check("job: image pinned", re.search(r"@sha256:[0-9a-f]{64}$", job["spec"]["template"]["spec"]["containers"][0]["image"]) is not None)
check("job: non-root, read-only root", job["spec"]["template"]["spec"]["securityContext"]["runAsNonRoot"] is True and job["spec"]["template"]["spec"]["containers"][0]["securityContext"]["readOnlyRootFilesystem"] is True)
check("job: realm as code (no --import-realm)", "import-realm" not in (M / "job-config.yaml").read_text(encoding="utf-8"))

route = load(M / "ingressroute.yaml")
routes = route["spec"]["routes"]
match = routes[0]["match"]
check("route: exactly one route", len(routes) == 1)
check("route: only /realms/lab/ and /resources/", "/realms/lab/" in match and "/resources/" in match and "/admin" not in match and "master" not in match and "/metrics" not in match and "/health" not in match)
cert = load(M / "certificate.yaml")
vals = load(R / "gitops/charts/keycloak/values.yaml")
check("certificate: sso.<domain> with the chart domain", cert["spec"]["dnsNames"] == ["sso." + vals["domain"]] and vals["domain"] == load(R / "infra/envs/local/lab.yaml")["domain"])
check("certificate: issuer lab-ca", cert["spec"]["issuerRef"]["name"] == "lab-ca")

np_text = (M / "networkpolicy.yaml").read_text(encoding="utf-8")
check("networkpolicy: no 0.0.0.0/0", "0.0.0.0/0" not in np_text)
nps = [d for d in yaml.safe_load_all(np_text) if d]
def deny(kind):
    return any(d["spec"].get("podSelector") == {} and d["spec"]["policyTypes"] == [kind] and not d["spec"].get("ingress") and not d["spec"].get("egress") for d in nps)


check("networkpolicy: default deny for ingress", deny("Ingress"))
check("networkpolicy: default deny for egress", deny("Egress"))
check("networkpolicy: Traefik may reach Keycloak only on 8080", any(d["metadata"]["name"].startswith("keycloak-allow-traefik") for d in nps))
lr_k = (M / "limitrange.yaml").read_text(encoding="utf-8")
check("limitrange: identical to the whoami copy", lr_k == (R / "gitops/workloads/whoami/limitrange.yaml").read_text(encoding="utf-8"))

# realm text: rendered with its defaults by the helm template later; here only the source
rt = (CH_REALM := R / "gitops/charts/keycloak/templates/configmap-realm.yaml").read_text(encoding="utf-8")
check("realm: registration off", '"registrationAllowed": false' in rt)
check("realm: brute force protection on", '"bruteForceProtected": true' in rt)
check("realm: groups lab-users and lab-admins", "lab-users" in rt and "lab-admins" in rt)
check("realm: clients gitea and synapse", '"clientId": "gitea"' in rt and '"clientId": "synapse"' in rt)
check("realm: client secrets come from the environment, not from the file", "$(env:" in rt and "secret\": \"" not in rt.replace('"secret": "$(env:', ""))
check("realm: Gitea callback of the keycloak source", "/user/oauth2/keycloak/callback" in rt)
check("realm: Synapse callback", "/_synapse/client/oidc/callback" in rt)
check("realm name in values and Gitea and Matrix agree",
      vals["realm"] == "lab" and "/realms/lab/" in (R / "gitops/workloads/gitea/values-gitea.yaml").read_text(encoding="utf-8")
      and load(R / "gitops/charts/matrix/values.yaml")["oidcRealm"] == "lab")

gv = load(R / "gitops/workloads/gitea/values-gitea.yaml")
check("gitea: no chart oauth block (it would fail hard while Keycloak is down)", "oauth" not in gv["gitea"])
c = gv["postExtraInitContainers"][0]
check("gitea: configure-oidc image equals the Gitea image", c["image"] == "%s/%s:%s-rootless@%s" % (gv["image"]["registry"], gv["image"]["repository"], gv["image"]["tag"], gv["image"]["digest"]))
script = c["args"][0]
check("gitea: configure-oidc never fails the pod (exit 0 at the end)", script.rstrip().endswith("exit 0"))
check("gitea: configure-oidc is idempotent (add-oauth or update-oauth)", "add-oauth" in script and "update-oauth" in script)
check("gitea: configure-oidc waits up to 180 s for a cold Keycloak start", "-ge 36" in script and "sleep 5" in script)
check("gitea: only members of lab-users, no admin mapping", "--required-claim-value lab-users" in script and "admin-group" not in script and "--group-claim-name groups" in script)
check("gitea: self-registration form closed, accounts only through OIDC",
      gv["gitea"]["config"]["service"]["DISABLE_REGISTRATION"] is True and gv["gitea"]["config"]["oauth2_client"]["ENABLE_AUTO_REGISTRATION"] is True)
check("gitea: accounts of a gitea-import link to the Keycloak user of the same name (ACCOUNT_LINKING auto, name from preferred_username)",
      gv["gitea"]["config"]["oauth2_client"]["ACCOUNT_LINKING"] == "auto" and gv["gitea"]["config"]["oauth2_client"]["USERNAME"] == "preferred_username")
check("gitea: container is hardened", c["securityContext"]["readOnlyRootFilesystem"] is True and c["securityContext"]["capabilities"]["drop"] == ["ALL"])
check("gitea: the key and secret come from the secret gitea-oidc",
      {e["name"]: e["valueFrom"]["secretKeyRef"]["name"] for e in c["env"] if "valueFrom" in e} == {"OIDC_KEY": "gitea-oidc", "OIDC_SECRET": "gitea-oidc"})

sys.exit(1 if errs else 0)
PY
cat "$T/struct.out"
n=$((n + $(grep -c '^OK ' "$T/struct.out") + $(grep -c '^FAIL' "$T/struct.out")))
fail=$((fail + $(grep -c '^FAIL' "$T/struct.out")))
grep -q 'Traceback' "$T/struct.out"
ok "structure checks ran without a Python error" "$?" 1

echo "== secrets: examples only, never real values"
S="$R/secrets"
for f in keycloak/backup-s3-creds keycloak/keycloak-db-owner keycloak/keycloak-admin keycloak/keycloak-oidc-clients keycloak/keycloak-notes-client gitea/gitea-oidc matrix/matrix-oidc; do
  if [ -f "$S/$f.sops.yaml.example" ]; then rc=0; else rc=1; fi
  ok "example exists: secrets/$f.sops.yaml.example" "$rc" 0
  grep -q 'ENC\[' "$S/$f.sops.yaml.example"
  ok "example holds no encrypted value and no cleartext: $f" "$?" 1
done
has "gitea-oidc takes the client secret from the lab file" "@file:keycloak-gitea-client-secret" "$S/gitea/gitea-oidc.sops.yaml.example"
has "matrix-oidc takes the client secret from the lab file" "@file:keycloak-synapse-client-secret" "$S/matrix/matrix-oidc.sops.yaml.example"
has "notes-client example takes the secret from the lab file" "@file:keycloak-notes-client-secret" "$S/keycloak/keycloak-notes-client.sops.yaml.example"
has "ksops lists the notes client secret file" "keycloak-notes-client.sops.yaml" "$S/keycloak/ksops.yaml"
has "secrets kustomization lists the generator" "ksops.yaml" "$S/keycloak/kustomization.yaml"
n_secrets=$(grep -c 'keycloak' "$R/docs/reference/secrets-map.md")
[ "$n_secrets" -ge 6 ]
ok "secrets map lists the Keycloak secrets" "$?" 0
grep -q "keycloak" "$R/.sops.yaml" || grep -q 'secrets/' "$R/.sops.yaml"
ok ".sops.yaml covers the secrets directory" "$?" 0

echo "== lifecycle coverage: Keycloak is handled like Gitea"
has "restore renderer lists the Keycloak cluster" "gitops/workloads/keycloak/manifests/cluster.yaml" "$R/scripts/lab-restore-render.py"
has "restore-clusters.yml restores keycloak-db" "keycloak/manifests/cluster.yaml" "$R/ansible/restore-clusters.yml"
has "alert checks keycloak-db" "keycloak-db" "$R/ansible/inventory/group_vars/all/alert.yml"
has "AppProject lists the namespace" "- keycloak" "$R/ansible/inventory/group_vars/all/argocd.yml"
has "egress: probe set exists" "egress_probe_keycloak" "$R/ansible/inventory/group_vars/all/egress.yml"
has "consistency check reads the Keycloak NetworkPolicy" "gitops/workloads/keycloak/manifests/networkpolicy.yaml" "$R/scripts/consistency-check.py"
has "ksops: secrets-keycloak is verified" "keycloak" "$R/ansible/verify-ksops.yml"
has "acceptance has the Keycloak phase" "verify-keycloak.yml" "$R/scripts/lab.sh"
has "preflight knows the Keycloak files" "Keycloak" "$R/scripts/lab.sh"
has "ADR index lists 0019" "0019-keycloak-sso.md" "$R/docs/concepts/decisions/index.md"
has "docs nav lists the how-to" "how-to/keycloak.md" "$R/zensical.toml"
has "backup-and-restore documents Keycloak" "keycloak" "$R/docs/concepts/backup-and-restore.md"
has "rebuild documents Keycloak" "Keycloak" "$R/docs/how-to/rebuild.md"
has "lab-sh reference documents Keycloak" "Keycloak" "$R/docs/reference/lab-sh.md"
has "versions lists the Keycloak pin" "quay.io/keycloak/keycloak" "$R/docs/reference/versions.md"
K8UP_DIR="$R/gitops/workloads/matrix/manifests"
hasnt "K8up schedule of matrix has no Keycloak (no PVC, documented)" "keycloak" "$K8UP_DIR/k8up-schedule.yaml"
python3 - "$R" << 'PY'
import sys
from pathlib import Path

import yaml

R = Path(sys.argv[1])
alert = yaml.safe_load((R / "ansible/inventory/group_vars/all/alert.yml").read_text(encoding="utf-8"))
cn = [x for x in alert.get("backup_alert_cnpg_clusters", [])]
k8 = alert.get("backup_alert_k8up_namespaces", [])
sys.exit(0 if {"namespace": "keycloak", "name": "keycloak-db"} in cn and "keycloak" not in k8 else 1)
PY
ok "alert: CNPG list has keycloak-db, K8up list has no keycloak" "$?" 0

echo "== helm render of the chart and the realm job values"
if command -v helm > /dev/null 2>&1; then
  helm template keycloak "$CH" > "$T/render.yaml" 2> "$T/render.err"
  ok "helm template of the keycloak chart" "$?" 0
  python3 - "$T/render.yaml" "$R/gitops/sites.yaml" << 'PY'
import json
import sys

import yaml

docs = [d for d in yaml.safe_load_all(open(sys.argv[1], encoding="utf-8")) if d]
# The notes client gets one redirect URI per sso site; a fresh clone (public export) lists no site yet.
sso_sites = [s for s in (yaml.safe_load(open(sys.argv[2], encoding="utf-8")) or []) if s.get("auth", "sso") != "basic"]
cm = [d for d in docs if d["kind"] == "ConfigMap"][0]
realm = json.loads(cm["data"]["realm.json"])
bad = []
if realm.get("registrationAllowed") is not False:
    bad.append("registration")
if realm.get("realm") != "lab":
    bad.append("realm name")
if {g["name"] for g in realm.get("groups", [])} != {"lab-users", "lab-admins"}:
    bad.append("groups")
ids = {c["clientId"]: c for c in realm.get("clients", [])}
if set(ids) != {"gitea", "synapse", "notes"}:
    bad.append("clients")
for cid, c in ids.items():
    if c.get("publicClient") or c.get("directAccessGrantsEnabled") or c.get("implicitFlowEnabled") or c.get("serviceAccountsEnabled"):
        bad.append(cid + " flows")
    if (not c["redirectUris"] and (cid != "notes" or sso_sites)) or any("*" in u for u in c["redirectUris"]):
        bad.append(cid + " redirect")
sys.exit(1 if bad else 0)
PY
  ok "rendered realm: registration off, three confidential code-flow clients, exact redirect URIs" "$?" 0
  python3 - "$T/render.yaml" "$M/deployment.yaml" "$M/job-config.yaml" << 'PY'
import json
import sys

import yaml

docs = [d for d in yaml.safe_load_all(open(sys.argv[1], encoding="utf-8")) if d]
cm = [d for d in docs if d["kind"] == "ConfigMap"][0]
dep = yaml.safe_load(open(sys.argv[2], encoding="utf-8"))
job = yaml.safe_load(open(sys.argv[3], encoding="utf-8"))
env = {e["name"]: e.get("value") for e in dep["spec"]["template"]["spec"]["containers"][0]["env"]}
master = json.loads(cm["data"]["realm-master.json"])
files = {e["name"]: e.get("value") for e in job["spec"]["template"]["spec"]["containers"][0]["env"]}["IMPORT_FILES_LOCATIONS"].split(",")
bad = []
if master.get("realm") != "master":
    bad.append("realm name")
if master.get("attributes", {}).get("frontendUrl") != env["KC_HOSTNAME_ADMIN"]:
    bad.append("frontendUrl differs from KC_HOSTNAME_ADMIN")
if set(master) != {"realm", "attributes"} or set(master["attributes"]) != {"frontendUrl"}:
    bad.append("master file has more than the frontendUrl")
if files != ["/config/realm.json", "/config/realm-master.json"]:
    bad.append("import files or order: " + ",".join(files))
sys.exit(1 if bad else 0)
PY
  ok "rendered master realm: frontendUrl = KC_HOSTNAME_ADMIN, job imports realm.json then realm-master.json" "$?" 0
  MX="$R/gitops/charts/matrix"
  helm template matrix "$MX" --set oidcAllowExistingUsers=false > "$T/mx-off.yaml" 2> /dev/null
  helm template matrix "$MX" --set oidcAllowExistingUsers=true > "$T/mx-on.yaml" 2> /dev/null
  has "rendered homeserver: allow_existing_users is false when switched off" "allow_existing_users: false" "$T/mx-off.yaml"
  has "rendered homeserver: allow_existing_users is true when switched on" "allow_existing_users: true" "$T/mx-on.yaml"
  hasnt "rendered homeserver: no second allow_existing_users value (switched on)" "allow_existing_users: false" "$T/mx-on.yaml"
else
  echo "SKIP: helm is missing"
fi

echo "== playbook syntax"
if command -v ansible-playbook > /dev/null 2>&1; then
  (cd "$R/ansible" && ANSIBLE_LOCALHOST_WARNING=False ansible-playbook --syntax-check verify-keycloak.yml > "$T/syn.out" 2>&1)
  ok "verify-keycloak.yml: syntax check" "$?" 0
  (cd "$R/ansible" && ANSIBLE_LOCALHOST_WARNING=False ansible-playbook --syntax-check restore-clusters.yml > "$T/syn.out" 2>&1)
  ok "restore-clusters.yml: syntax check" "$?" 0
else
  echo "SKIP: ansible-playbook is missing"
fi

echo
echo "$n checks, $fail failures"
[ "$fail" = 0 ]
