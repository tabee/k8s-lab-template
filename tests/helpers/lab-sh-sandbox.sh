#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
# Shared sandbox and stub tools for the lab.sh suites. Source after setting R.
# shellcheck disable=SC2016
# Sandbox on the disk instead of /tmp: /tmp is often tmpfs and too small for the space check in preflight
mkdir -p "$HOME/.cache/lab-sh-tests"
T=$(mktemp -d -p "$HOME/.cache/lab-sh-tests")
trap 'rm -rf "$T"' EXIT
S=$T/state
H=$T/home
mkdir -p "$T/bin" "$S" "$H/.ssh" "$H/.kube" "$T/pool" "$T/repo/scripts" "$T/repo/infra/envs/local" "$T/repo/ansible/roles/backup_s3/files"
export S T
# lab-restore-render.py (and others) import yaml. The sandbox sets HOME=$H, so a
# user-site PyYAML under the real $HOME is invisible. install-tools.sh installs
# the distro package python3-yaml into the system site - require that here.
if ! HOME=$H python3 -c 'import yaml' 2>/dev/null; then
  echo "sandbox: PyYAML missing for HOME=$H (install python3-yaml / bash scripts/lab.sh tools)." >&2
  exit 1
fi
ok() { n=$((n + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else echo "FAIL $1 (actual '$2', expected '$3')"; fail=$((fail + 1)); fi; }
has() { grep -Fq -- "$2" "$3"; ok "$1" "$?" 0; }
hasnt() { ! grep -Fq -- "$2" "$3"; ok "$1" "$?" 0; }
hasnot() { grep -Fq -- "$2" "$3"; ok "$1" "$?" 1; }
first() { find "$1" -maxdepth 1 -name "$2" 2> /dev/null | sort | head -n 1; }
line() { grep -n -- "$1" "$S/calls" | head -n 1 | cut -d: -f1; }

# ---------- Sandbox-Repo
cp "$R/scripts/lab.sh" "$T/repo/scripts/lab.sh"
cp "$R/scripts/gitea-sso.sh" "$T/repo/scripts/"
cp "$R/scripts/import-state.py" "$T/repo/scripts/import-state.py"
cp "$R/scripts/lab-trust.sh" "$T/repo/scripts/lab-trust.sh"
cp "$R/scripts/lab-wal-ready.py" "$T/repo/scripts/lab-wal-ready.py"
cp "$R/scripts/lab-backup-fresh.py" "$T/repo/scripts/lab-backup-fresh.py"
cp "$R/scripts/lab-restore-render.py" "$T/repo/scripts/lab-restore-render.py"
cp "$R/scripts/lab-secrets.py" "$T/repo/scripts/lab-secrets.py"
cp "$R/scripts/memory-budget.py" "$T/repo/scripts/memory-budget.py"
mkdir -p "$T/repo/ansible/scripts" "$T/repo/ansible/inventory/group_vars/all"
cp "$R/ansible/scripts/sops-secret.sh" "$T/repo/ansible/scripts/sops-secret.sh"
cp "$R/ansible/inventory/group_vars/all/secrets.yml" "$T/repo/ansible/inventory/group_vars/all/secrets.yml"
cp "$R/.sops.yaml" "$T/repo/.sops.yaml"
(cd "$R" && find secrets -name '*.sops.yaml.example') | while read -r f; do
  mkdir -p "$T/repo/$(dirname "$f")"
  cp "$R/$f" "$T/repo/$f"
done
cp "$R/infra/envs/local/lab.yaml" "$T/repo/infra/envs/local/lab.yaml"
# Synthetic prod profile: exercise parity/drift even when the real private profile is excluded.
mkdir -p "$T/repo/infra/envs/prod"
printf 'memory_mib: 8192\n' > "$T/repo/infra/envs/prod/lab.yaml"
cp -r "$R/gitops" "$T/repo/gitops"
# Public version: repo_url is a placeholder. The sandbox gets a test address, the same in
# lab.yaml and in gitops/, so that preflight (state = configuration) runs as it does for the owner.
PH_URL='ssh://git@git.example.org/YOUR-NAME/k8s-lab.git'
if grep -qF "$PH_URL" "$T/repo/infra/envs/local/lab.yaml"; then
  grep -rlF "$PH_URL" "$T/repo/infra/envs/local/lab.yaml" "$T/repo/gitops" | while read -r f; do
    sed -i "s#$PH_URL#ssh://git@git.lab-test.invalid/me/k8s-lab.git#" "$f"
  done
fi
# The same for the placeholder of the separate secrets repo (ADR 0022): the sandbox starts with one repo
PH_SURL='ssh://git@git.example.org/YOUR-NAME/k8s-lab-secrets.git'
grep -rlF "$PH_SURL" "$T/repo/infra/envs/local/lab.yaml" "$T/repo/gitops" | while read -r f; do
  sed -i "s#$PH_SURL#ssh://git@git.lab-test.invalid/me/k8s-lab.git#" "$f"
done
# Deployment defaults can be placeholders in the public tree. Tests use concrete neutral inputs.
# Keep GitOps and its state aligned with the configured mirror, as customize would do.
python3 - "$T/repo" <<'PYFIXTURE'
import re, sys
from pathlib import Path
root = Path(sys.argv[1])
lab = root / "infra/envs/local/lab.yaml"
text = lab.read_text()
old = re.search(r"^github_repo_url: (.+)$", text, re.M).group(1)
new = "ssh://git@github.com/test-owner/k8s-lab.git"
for p in [lab, *root.joinpath("gitops").rglob("*")]:
    if p.is_file() and not p.is_symlink():
        content = p.read_text()
        p.write_text(content.replace(old, new))
# No separate secrets repository in the source-switch fixture (GitHub mode refuses one).
lab.write_text(re.sub(r"^secrets_repo_url:.*$", 'secrets_repo_url: ""', lab.read_text(), flags=re.M))
PYFIXTURE
cp "$R/zensical.toml" "$T/repo/zensical.toml"
cp "$R/scripts/lab-customize.py" "$T/repo/scripts/lab-customize.py"
cp "$R/scripts/lab-secrets-repo.py" "$T/repo/scripts/lab-secrets-repo.py"
cp "$R/scripts/repo-egress.py" "$T/repo/scripts/repo-egress.py"
printf 'fake-image' > "$T/fake.img"
SHA=$(sha256sum "$T/fake.img" | awk '{ print $1 }')
cat > "$T/repo/infra/envs/local/lab.local.yaml" <<YAML
ssh_key: $H/.ssh/id_test
image_file: test.img
image_cache_dir: $H/data/images
export_dir: $H/data/vm-export
log_dir: $H/data/logs
image_sha256: $SHA
wait_ssh: 3
wait_argo: 3
repo_egress_cidrs: 192.0.2.7
YAML
# Egress policies: write the (test) git server address into the sandbox gitops/ like the owner does.
PYTHONDONTWRITEBYTECODE=1 python3 "$T/repo/scripts/repo-egress.py" --repo "$T/repo" > /dev/null || { echo "sandbox: repo-egress failed" >&2; exit 1; }
: > "$H/.ssh/id_test"; : > "$H/.ssh/id_test.pub"; : > "$H/.ssh/deploy"
printf 'x' > "$H/age.txt"; chmod 600 "$H/age.txt"
for f in rustfs-root.env u1.env u2.env g1 g2 g3 g4; do printf 'x' > "$H/$f"; done
: > "$T/kvm"
printf 'disk' > "$T/pool/k3s-lab.qcow2"
cat > "$T/repo/ansible/roles/backup_s3/files/rustfs-s3.py" <<'PY'
import json, os, sys
S = os.environ["S"]
sub = sys.argv[1]
open(S + "/calls", "a").write("rustfs-s3 " + " ".join(sys.argv[1:]) + "\n")
def out(ok, changed, akt, message):
    print(json.dumps({"ok": ok, "changed": changed, "actions": akt, "message": message}))
if not os.path.exists(S + "/rustfs_up"):
    if sub == "drop-bucket" and "--check" in sys.argv:
        out(True, True, [], "Check mode: rustfs not reachable yet (stub)")
        sys.exit(0)
    out(False, False, [], "rustfs not reachable (stub)")
    sys.exit(1)
if sub == "drop-bucket":
    if os.path.exists(S + "/bucket_used"):
        info = "pg-lab: 5 version(s)/marker(s), 1.0 MiB (1 bytes)"
        out(True, True, [info], info)
    else:
        out(True, False, [], "pg-lab: does not exist (nothing to do)")
else:
    out(True, False, [], "ok")
PY
# Committed gitops/ may already name the GitHub mirror (live Argo source, ADR 0024) while
# infra/envs/local/lab.yaml still defaults to the private Gitea URL. That mismatch is
# intentional in the repo: the owner runs customize on their machine; Argo keeps reading
# the mirror. Normalize only this sandbox so preflight/customize expectations match
# lab.yaml without rewriting the committed tree the suite resets to.
PYTHONDONTWRITEBYTECODE=1 python3 - "$T/repo" <<'PYBOOT'
import importlib.util, pathlib, sys
r = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("customize", r / "scripts/lab-customize.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
import yaml
cfg = yaml.safe_load((r / "infra/envs/local/lab.yaml").read_text())
values = {k: str(cfg[k]) for k in m.KEYS}
values[m.ITEMS] = str(cfg.get(m.ITEMS, cfg["vm_cidr"])).replace("vm_cidr", cfg["vm_cidr"])
values[m.SECRETS] = cfg.get(m.SECRETS) or cfg["repo_url"]
old = m.read_state(r / "gitops/values-state.yaml")
m.rewrite(str(r), old, values, False)
m.rewrite_secrets_apps(str(r), values["secrets_repo_url"], False)
(r / "gitops/values-state.yaml").write_text(m.state_text(values))
PYBOOT
cd "$T/repo" || exit 1
git init -q -b main .
printf 'infra/envs/local/lab.local.yaml\n' >> .git/info/exclude
git add -A
git -c user.name=t -c user.email=t@t commit -q -m init
git clone -q --bare . "$T/origin.git"
git remote add origin "$T/origin.git"
git fetch -q origin
git branch -q --set-upstream-to=origin/main main

# ---------- Stubs
stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$T/bin/$1"; chmod +x "$T/bin/$1"; }
cat > "$T/bin/ansible" <<'STUB'
#!/usr/bin/env bash
echo "ansible $*" >> "$S/calls"
case "$*" in
  *secrets_all*)
    if [ -f "$S/ansible_geh_fail" ]; then echo "stub error: secrets not readable" >&2; exit 4; fi
    exec python3 - <<'PY'
import json, os, re
H = os.environ["HOME"]
C = H + "/.config/k8s-lab/"
V = {
    "argocd_sops_age_key_path": H + "/.config/sops/age/keys.txt", "lab_ca_secret_file": C + "lab-ca-secret.yaml",
    "argocd_sops_break_glass_key_path": C + "break-glass-age.txt",
    "lab_ca_secret_name": "lab-ca", "lab_ca_namespace": "cert-manager", "lab.domain": "lab.example",
    "lab_ca_cert_path": C + "lab-ca.crt", "lab_acme_token_file": C + "acme-dns01.token", "backup_s3_root_env": H + "/.config/rustfs/rustfs.env",
    "backup_s3_user_env": C + "s3-cnpg-k3s-lab.env", "backup_s3_user": "cnpg-k3s-lab", "backup_s3_bucket": "cnpg-k3s-lab",
    "backup_s3_vm_endpoint": "http://192.168.122.1:9000", "backup_s3_k8up_user_env": C + "s3-k8up-k3s-lab.env",
    "backup_s3_k8up_user": "k8up-k3s-lab", "backup_s3_k8up_bucket": "k8up-k3s-lab",
    "gitea_db_password_file": C + "gitea-k3s-lab-db.pw", "gitea_admin_user_file": C + "gitea-k3s-lab-admin.user",
    "gitea_admin_password_file": C + "gitea-k3s-lab-admin.pw", "gitea_runner_token_file": C + "gitea-k3s-lab-runner.token",
    "gitea_k8up_repo_password_file": C + "k8up-k3s-lab-repo.pw",
    "matrix_db_password_file": C + "matrix-k3s-lab-db.pw", "matrix_admin_user_file": C + "matrix-k3s-lab-admin.user",
    "matrix_admin_password_file": C + "matrix-k3s-lab-admin.pw",
    "matrix_registration_secret_file": C + "matrix-k3s-lab-registration.secret",
    "matrix_signing_key_file": C + "matrix-k3s-lab-signing.key",
    "keycloak_db_password_file": C + "keycloak-k3s-lab-db.pw", "keycloak_admin_user_file": C + "keycloak-k3s-lab-admin.user",
    "keycloak_admin_password_file": C + "keycloak-k3s-lab-admin.pw",
    "keycloak_gitea_client_secret_file": C + "keycloak-k3s-lab-gitea-client.secret",
    "keycloak_synapse_client_secret_file": C + "keycloak-k3s-lab-synapse-client.secret",
    "keycloak_notes_client_secret_file": C + "keycloak-k3s-lab-notes-client.secret",
    "argocd_repo_ssh_key_path": H + "/.ssh/argocd-k8s-lab", "argocd_secrets_repo_ssh_key_path": H + "/.ssh/argocd-k8s-lab-secrets",
    "argocd_secrets_repo_secret_name": "repo-k8s-lab-secrets", "argocd_repo_secret_name": "repo-k8s-lab",
    "lab.ssh_key": H + "/.ssh/id_ed25519", "argocd_kubeconfig": H + "/.kube/k3s-lab.kubeconfig", "argocd_namespace": "argocd",
    "backup_replica_key": H + "/.ssh/k8s-lab-replica", "backup_replica_install_key": H + "/.ssh/id_ed25519",
    "alert_matrix_token_file": C + "alert-matrix.sops.yaml",
    "alert_heartbeat_url_file": C + "alert-heartbeat.sops.yaml",
    "wireguard_server_key_path": C + "wireguard-server.key",
    "wireguard_client_key_path": C + "wireguard-client.key",
}
ein, cur, fold, skip = [], None, None, False
# The secrets repo entries only count with a separate secrets repo (LAB_TEST_SECRETS_REPO=1, ADR 0022).
separate = os.environ.get("LAB_TEST_SECRETS_REPO") == "1"
for z in open("inventory/group_vars/all/secrets.yml", encoding="utf-8"):
    if z.startswith("secrets_notes:"):
        break
    if re.match(r"^[a-z_]+:", z):
        skip = z.startswith("secrets_secrets_repo:") and not separate
        cur = None
    if skip:
        continue
    m = re.match(r"^  - name: (.*)$", z)
    if m:
        cur = {"name": m.group(1).strip()}
        ein.append(cur)
        continue
    m = re.match(r"^      (\S.*)$", z)
    if m and cur is not None and fold:
        w = re.sub(r"\{\{\s*([a-z0-9_.]+)[^}]*\}\}", lambda mm: V[mm.group(1)], m.group(1).strip())
        cur[fold] = (cur[fold] + " " + w).strip()
        continue
    m = re.match(r"^    ([a-z_0-9]+): (.*)$", z)
    if m and cur is not None:
        v = m.group(2).strip()
        fold = m.group(1) if v == ">-" else None
        if fold:
            cur[fold] = ""
            continue
        if len(v) > 1 and v[0] == v[-1] == '"':
            v = v[1:-1]
        if re.fullmatch(r"\d+", v):
            v = int(v)
        elif v in ("true", "false"):
            v = v == "true"
        else:
            v = re.sub(r"\{\{\s*([a-z0-9_.]+)[^}]*\}\}", lambda mm: V[mm.group(1)], v)
        cur[m.group(1)] = v
for kind, fpath, extra in (("ssh", H + "/.ssh/notes-notes-deploy", {"comment": "notes-notes-deploy (k8s-lab, read only)"}),
                         ("pw", C + "notes-notes.cookie", {"length": 32})):
    e = {"name": "notes-notes-" + ("deploy" if kind == "ssh" else "cookie"), "purpose": "Notes site notes", "kind": kind, "path": fpath}
    e.update(extra)
    ein.append(e)
print("steuerrechner | SUCCESS => " + json.dumps({"changed": False, "msg": json.dumps({"entries": ein})}))
PY
    ;;
esac
python3 - <<'PY'
import json, os, re
T = os.environ["T"]
H = T + "/home"
d = {
    "vm_name": "k3s-lab", "vm_ip": "192.168.122.50", "fqdn": "k3s-lab.lab.example", "gateway": "192.168.122.1",
    "kubeconfig": H + "/.kube/k3s-lab.kubeconfig", "age_key": H + "/age.txt", "sops_config": H + "/sops.yaml",
    "deploy_key": H + "/.ssh/deploy", "repo_url": T + "/origin.git", "known_hosts": ["gitea.example ssh-ed25519 AAAAtest"],
    "sudo_exe": "sudo", "rustfs_port": 9000, "rustfs_root_env": H + "/rustfs-root.env",
    "rustfs_env_files": [H + "/u1.env", H + "/u2.env"], "bucket_cnpg": "pg-lab", "bucket_k8up": "k8up",
    "backup_data_dir": H + "/backups",
    "backup_max_age_h": 30,
    "matrix_signing_key_file": H + "/.config/k8s-lab/matrix-k3s-lab-signing.key",
    "secret_files": [H + "/g1", H + "/g2", H + "/g3", H + "/g4"],
    "gitops_gateway_files": ["gitops/workloads/db-lab/objectstore.yaml", "gitops/workloads/gitea/manifests/objectstore.yaml", "gitops/workloads/gitea/manifests/k8up-schedule.yaml"],
    "gitops_cidr_files": ["gitops/platform/traefik/values.yaml"],
    "acme_active": os.path.exists(os.environ["S"] + "/acme_active_flag"),
    "replica_enabled": not os.path.exists(os.environ["S"] + "/replica_off"), "replica_config": H + "/replica.json",
    "replica_script": T + "/fake-lab-tool.py", "alert_enabled": not os.path.exists(os.environ["S"] + "/alert_off"),
    "alert_config": H + "/alert.json", "alert_script": T + "/fake-lab-tool.py",
    "alert_maintenance_file": H + "/alert-maintenance.json",
    "restore_state_file": H + "/restore-in-progress.json",
}
# Ingress networks as Ansible resolves them: lab.local.yaml (edge_ingress_cidrs, comma-separated) or vm_cidr.
local_text = open(T + "/repo/infra/envs/local/lab.local.yaml", encoding="utf-8").read()
m_cidr = re.findall(r"^vm_cidr: (\S+)$", local_text, re.M)
m_edge = re.findall(r"^edge_ingress_cidrs: (.+)$", local_text, re.M)
if re.search(r"^source: github$", local_text, re.M):  # ADR 0024: the effective repo_url is the mirror (a local bare repo here)
    d["repo_url"] = T + "/mirror.git"
    d["known_hosts"] = ["github.com ssh-ed25519 AAAAtest"]
d["edge_ingress_cidrs"] = [x.strip() for x in m_edge[-1].split(",")] if m_edge else [m_cidr[-1] if m_cidr else "192.168.122.0/24"]
print("steuerrechner | SUCCESS => " + json.dumps({"changed": False, "msg": json.dumps(d)}))
PY
STUB
cat > "$T/bin/virsh" <<'STUB'
#!/usr/bin/env bash
shift 2
echo "virsh $*" >> "$S/calls"
z() { cat "$S/vm" 2> /dev/null || echo absent; }
case "$1" in
  version) echo "Using library: libvirt 10" ;;
  net-info) printf 'Name: default\nActive:         yes\n' ;;
  net-dumpxml) echo "<ip address='192.168.122.1' netmask='255.255.255.0'/>" ;;
  pool-info) printf 'State:          running\n' ;;
  pool-dumpxml) echo "<pool><target><path>$T/pool</path></target></pool>" ;;
  domstate) [ "$(z)" = absent ] && exit 1; z ;;
  domblklist) printf 'Type Device Target Source\n---\nfile disk vda %s\n' "$T/pool/k3s-lab.qcow2" ;;
  vol-info) printf 'Allocation:     2147483648\n' ;;
  snapshot-list) cat "$S/snaps" 2> /dev/null ;;
  snapshot-delete) : > "$S/snaps" ;;
  shutdown | destroy) echo "shut off" > "$S/vm" ;;
  start) echo running > "$S/vm" ;;
  undefine) echo absent > "$S/vm" ;;
  dumpxml) echo "<domain>k3s-lab</domain>" ;;
  *) : ;;
esac
exit 0
STUB
cat > "$T/bin/tofu" <<'STUB'
#!/usr/bin/env bash
shift
echo "tofu $*" >> "$S/calls"
case "$1 $2" in
  "state list") [ -f "$S/tfstate" ] && echo libvirt_domain.vm ; exit 0 ;;
esac
case "$1" in
  plan) for a in "$@"; do case $a in -out=*) echo plan > "${a#-out=}" ;; esac; done ;;
  show)
    if [ -f "$S/plan.json" ]; then cat "$S/plan.json"
    elif [ -f "$S/tfstate" ]; then echo '{"resource_changes":[{"address":"a","change":{"actions":["no-op"]}}]}'
    else echo '{"resource_changes":[{"address":"a","change":{"actions":["create"]}},{"address":"b","change":{"actions":["create"]}}]}'; fi ;;
  apply) echo running > "$S/vm"; : > "$S/tfstate"; echo "Apply complete" ;;
  destroy)
    # rebuild --restore must have written its marker before anything is destroyed.
    [ ! -f "$HOME/restore-in-progress.json" ] || echo "RESTORE-MARKER present at tofu destroy" >> "$S/calls"
    if [ -s "$S/snaps" ]; then echo "Error: domain has snapshots" >&2; exit 1; fi
    rm -f "$S/tfstate"; echo absent > "$S/vm"; echo "Destroy complete" ;;
esac
exit 0
STUB
cat > "$T/bin/ansible-playbook" <<'STUB'
#!/usr/bin/env bash
pb=$1
echo "ansible-playbook $*" >> "$S/calls"
for a in "$@"; do
  if [ "$a" = "-" ]; then n=$(head -n 1 | wc -c); echo "stdin-length $n" >> "$S/calls"; fi
done
# Test hook: something happens at the remote while argocd.yml runs (a commit that arrives during the rebuild).
if [ "$pb" = argocd.yml ] && [ -f "$S/on_argocd" ]; then bash "$S/on_argocd"; fi
# Issue #21: is the alert marker there while a playbook runs? (the content is kept for the tests)
if [ -f "$HOME/alert-maintenance.json" ]; then
  echo "MARKER present $pb" >> "$S/calls"
  cp "$HOME/alert-maintenance.json" "$S/marker.last"
fi
# The resume of rebuild --restore ends the paused state of the fake Applications (see the kubectl stub).
case "$*" in *"--tags resume"*) rm -f "$S/apps" ;; esac
# The verify part of recover-files.yml removes the marker of the unfinished restore.
case "$*" in *"--tags verify"*) rm -f "$HOME/restore-in-progress.json" ;; esac
[ ! -f "$S/fail_$pb" ] || { echo "fatal: stub error in $pb" >&2; exit 2; }
# One part of recover-files.yml fails (fail_tag_pause, fail_tag_restore, ...).
case "$*" in *"--tags "*) all="$*"; tg=${all##*--tags }; tg=${tg%% *}; [ ! -f "$S/fail_tag_$tg" ] || { echo "fatal: stub error in tag $tg" >&2; exit 2; } ;; esac
case $pb in
  lab-backups-empty.yml) rm -f "$S/bucket_used" ;;
  backup-host.yml) : > "$S/rustfs_up" ;;
  verify-gitea.yml) echo "    msg: Restore ok: Commit abc1234, SHA-256 deadbeef" ;;
  restore-drill.yml) echo "    msg: RESTORE-DRILL RESULT ok: database 95 s, files 41 s, total 300 s, repositories 3" ;;
  verify-cnpg.yml) echo "    msg: PITR until 2026-10-30 12:00: A = 5, B = 0 rows" ;;
esac
echo "PLAY RECAP *****"
printf 'k3s-lab : ok=5 changed=%s unreachable=0 failed=0 skipped=0 rescued=0 ignored=0\n' "$(cat "$S/changed" 2> /dev/null || echo 0)"
exit 0
STUB
cat > "$T/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
echo "kubectl $*" >> "$S/calls"
if [[ "$*" == *"get cm "*"--ignore-not-found"* ]]; then exit 0; fi
if [[ "$*" == *".lab-import-state.json"* ]]; then exit 44; fi
if [[ "$*" == *"get secret gitea-oidc"* ]]; then exit 1; fi
if [ "$1" = apply ]; then
  cat > "$S/last-apply.json"
  echo apply >> "$S/applies"
  exit 0
fi
if [ "$1" = exec ]; then
  case "$*" in
    *"test -"*) [ ! -f "$S/guard-empty" ] || exit 1; exit 0 ;;
    *last_archived_wal*) echo "000000010000000000000008"; exit 0 ;;
    *pg_switch_wal*) echo "000000010000000000000008"; exit 0 ;;
  esac
fi
serve() {
  if [ -f "$1" ]; then cat "$1"; else echo '{"items":[]}'; fi
}
if [[ "$*" == *"-o json" ]]; then
  if [[ "$*" != *" -A "* ]] && [ -f "$S/last-apply.json" ]; then
    if python3 - "$S/last-apply.json" "$*" << 'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
name = (doc.get("metadata") or {}).get("name") or ""
if not name or name not in sys.argv[2].split():
    sys.exit(2)
api = doc.get("apiVersion") or ""
if api.startswith("postgresql"):
    doc["status"] = {
        "phase": "completed",
        "stoppedAt": "2099-01-01T00:00:00Z",
        "endWal": "000000010000000000000005",
    }
elif doc.get("kind") == "Backup":
    doc["status"] = {
        "finished": True,
        "conditions": [{"type": "Completed", "status": "True", "reason": "Succeeded"}],
    }
json.dump(doc, sys.stdout)
PY
    then
      exit 0
    fi
  fi
  case "$*" in
    # The guard of rebuild --restore: Argo CD applications and the Deployments that mount the file volumes.
    *applications.argoproj.io*) serve "$S/guard-apps.json" ;;
    *"get deployment"*) if [ -f "$S/guard-noready" ]; then echo '{"status":{"readyReplicas":0}}'; else echo '{"status":{"readyReplicas":1}}'; fi ;;
    *clusters.postgresql.cnpg.io*) serve "$S/cnpg-clusters.json" ;;
    *scheduledbackups.postgresql.cnpg.io*) serve "$S/cnpg-scheduled.json" ;;
    *backups.postgresql.cnpg.io*) serve "$S/cnpg-backups.json" ;;
    *schedules.k8up.io*) serve "$S/k8up-schedules.json" ;;
    *snapshots.k8up.io*) serve "$S/k8up-snapshots.json" ;;
    *backups.k8up.io*) serve "$S/k8up-backups.json" ;;
    *) echo '{"items":[]}' ;;
  esac
  exit 0
fi
case "$*" in
  *applications*) if [ -f "$S/apps" ]; then cat "$S/apps"; else echo "app1 Synced/Healthy"; fi ;;
  *clusters*) echo "db/pg=Cluster in healthy state" ;;
  *) echo "k3s-lab Ready" ;;
esac
STUB
cat > "$T/bin/qemu-img" <<'STUB'
#!/usr/bin/env bash
echo "qemu-img $*" >> "$S/calls"
if [ "$1" = convert ]; then for a in "$@"; do last=$a; done; echo qcow2-data > "$last"; fi
exit 0
STUB
cat > "$T/bin/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl $*" >> "$S/calls"
while [ $# -gt 0 ]; do
  if [ "$1" = -o ]; then if [ -f "$S/curl_bad" ]; then printf bad > "$2"; else cp "$T/fake.img" "$2"; fi; fi
  shift
done
STUB
cat > "$T/bin/sudo" <<'STUB'
#!/usr/bin/env bash
read -r pw
[ "$pw" = s3kr1t ]
STUB
# $S/git_ssh: git over the stub ssh talks to the sandbox origin (source trust tests). $S/real_keygen: the real ssh-keygen
# (git verify-commit needs it).
stub ssh 'case "$*" in *git-upload-pack*) [ -f "$S/git_ssh" ] && exec git upload-pack "$T/origin.git" ;; esac; case "$*" in *cloud-init*) echo "status: done" ;; esac; exit 0'
stub ssh-keygen 'if [ -f "$S/real_keygen" ]; then exec '"$(command -v ssh-keygen)"' "$@"; fi; echo "ssh-keygen $*" >> "$S/calls"; exit 0'
stub helm 'exit 0'
# Tools of the preflight that only need to exist (release prep).
for w in sops age age-keygen podman ufw; do stub "$w" 'exit 0'; done
chmod +x "$T/bin/"*

# ---------- Helpers
lab() { # lab ARGS... (stdin: answers); output in $T/out
  : > "$S/calls.fresh"
  HOME=$H PATH=$T/bin:$PATH LAB_POLL=0 LAB_REQUIRE_TTY=0 LAB_KVM=$T/kvm \
    LAB_FRESH_ATTEMPTS=3 LAB_FRESH_INTERVAL=0 \
    bash "$T/repo/scripts/lab.sh" "$@" > "$T/out" 2>&1
}
vm() { echo "$1" > "$S/vm"; if [ "$1" = absent ]; then rm -f "$S/tfstate"; else : > "$S/tfstate"; : > "$H/.kube/k3s-lab.kubeconfig"; fi; }
fresh() { : > "$S/calls"; }
# Used by the suites that source this sandbox.
# shellcheck disable=SC2034
SUDO=$'s3kr1t\n'
