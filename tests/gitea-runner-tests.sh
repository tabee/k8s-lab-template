#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
# Offline checks for Gitea Actions and the runner in the cluster (issue #115, ADR 0030):
#   1. Gitea has Actions on, takes the global runner token from an OPTIONAL secret, fetches no actions from GitHub
#   2. isolation: PSA restricted, no privileged container, no Docker socket, no host namespaces, job pods without
#      service account token and without a way to the API server; the runner's RBAC only covers job pods
#   3. budget: capacity 1, marked limits for the runner and the job pod, the quota enforces the same job limit,
#      and the prod projection with runner + job + the largest periodic job still fits
#   4. copies: default job image = the image of the lint workflow, insteadOf host = Gitea DOMAIN, namespaces =
#      argocd_project_namespaces (lab and prod), the registration token exists only as SOPS templates
# No cluster, no network and no secret values.
# Usage: bash tests/gitea-runner-tests.sh [repo root]
set -u
export PYTHONDONTWRITEBYTECODE=1
R=$(cd "${1:-$(dirname "${BASH_SOURCE[0]}")/..}" && pwd -P)
python3 -c 'import yaml' 2> /dev/null || { echo "SKIP: python3 PyYAML is missing"; exit 0; }
fail=0
n=0
ok() { n=$((n + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else echo "FAIL $1 (is '$2', want '$3')"; fail=$((fail + 1)); fi; }

W="$R/gitops/workloads/gitea-runner"

echo "== files exist"
for f in namespace limitrange rbac configmap jobs-configmap jobs-limits deployment networkpolicy; do
  if [ -f "$W/$f.yaml" ]; then rc=0; else rc=1; fi
  ok "manifest $f.yaml" "$rc" 0
done
for f in gitops/apps/gitea-runner.yaml gitops/apps/secrets-gitea-runner.yaml gitops/workloads/gitea/manifests/networkpolicy-runner.yaml \
  secrets/gitea/gitea-runner-token.sops.yaml.example secrets/gitea-runner/gitea-runner-registration.sops.yaml.example \
  secrets/gitea-runner/ksops.yaml secrets/gitea-runner/kustomization.yaml docs/how-to/gitea-actions.md \
  docs/concepts/decisions/0030-gitea-actions-runner.md; do
  if [ -f "$R/$f" ]; then rc=0; else rc=1; fi
  ok "file $f" "$rc" 0
done

echo "== rules (python)"
python3 - "$R" << 'PY'
import glob
import re
import shutil
import subprocess
import sys
from pathlib import Path

import yaml

R = Path(sys.argv[1])
W = R / "gitops/workloads/gitea-runner"
fails = 0


def check(label, cond):
    global fails
    print(("OK   " if cond else "FAIL ") + label)
    if not cond:
        fails += 1


def docs(path):
    return [d for d in yaml.safe_load_all(path.read_text(encoding="utf-8")) if d]


def walk(value):
    if isinstance(value, dict):
        yield value
        for item in value.values():
            yield from walk(item)
    elif isinstance(value, list):
        for item in value:
            yield from walk(item)


objs = [d for p in sorted(W.glob("*.yaml")) for d in docs(p)]
by_kind = {}
for d in objs:
    by_kind.setdefault(d["kind"], []).append(d)

# ---- 1. Gitea
values = yaml.safe_load((R / "gitops/workloads/gitea/values-gitea.yaml").read_text(encoding="utf-8"))
actions = values["gitea"]["config"]["actions"]
check("gitea: actions ENABLED true", actions.get("ENABLED") is True)
check("gitea: DEFAULT_ACTIONS_URL self (no implicit github.com)", actions.get("DEFAULT_ACTIONS_URL") == "self")
env = {e["name"]: e for e in values.get("deployment", {}).get("env", [])}
tok = env.get("GITEA_RUNNER_REGISTRATION_TOKEN", {}).get("valueFrom", {}).get("secretKeyRef", {})
check("gitea: runner token from secret gitea-runner-token/token", tok.get("name") == "gitea-runner-token" and tok.get("key") == "token")
check("gitea: the token secret is optional (Gitea starts without it)", tok.get("optional") is True)
check("gitea: no literal token value in values", "value" not in env.get("GITEA_RUNNER_REGISTRATION_TOKEN", {}))
domain = values["gitea"]["config"]["server"]["DOMAIN"]

# ---- 2. isolation
ns_docs = by_kind.get("Namespace", [])
names = sorted(d["metadata"]["name"] for d in ns_docs)
check("namespaces gitea-runner and gitea-runner-jobs", names == ["gitea-runner", "gitea-runner-jobs"])
for d in ns_docs:
    lab = d["metadata"].get("labels", {})
    check("%s: PSA enforce restricted" % d["metadata"]["name"], lab.get("pod-security.kubernetes.io/enforce") == "restricted")
text = "\n".join(p.read_text(encoding="utf-8") for p in sorted(W.glob("*.yaml")))
check("no privileged container anywhere", not re.search(r"privileged:\s*true", text))
check("no Docker socket, no docker:dind, no hostPath", not re.search(r"docker\.sock|dind|hostPath", text))
check("no host namespaces", not re.search(r"host(Network|PID|IPC|Users):\s*true", text))
check("no ClusterRole or ClusterRoleBinding", not ({"ClusterRole", "ClusterRoleBinding"} & set(by_kind)))
roles = by_kind.get("Role", [])
check("exactly one Role, in gitea-runner-jobs", len(roles) == 1 and roles[0]["metadata"]["namespace"] == "gitea-runner-jobs")
allowed = {("pods", "create"), ("pods", "get"), ("pods", "list"), ("pods", "delete"), ("pods/exec", "create"), ("pods/exec", "get"),
           ("pods/log", "get"), ("secrets", "create"), ("secrets", "delete")}
granted = {(res, verb) for rule in roles[0]["rules"] for res in rule["resources"] for verb in rule["verbs"]} if roles else set()
check("Role: only the job pod verbs of the upstream example", granted and granted <= allowed and all(r["apiGroups"] == [""] for r in roles[0]["rules"]))
check("Role: secrets cannot be read (no get/list/watch)", not {("secrets", v) for v in ("get", "list", "watch")} & granted)
rb = by_kind.get("RoleBinding", [])
check("RoleBinding binds only the runner service account", len(rb) == 1 and rb[0]["subjects"] == [{"kind": "ServiceAccount", "name": "gitea-runner", "namespace": "gitea-runner"}])
sas = {(d["metadata"]["namespace"], d["metadata"]["name"]): d for d in by_kind.get("ServiceAccount", [])}
check("default service account of the job namespace mounts no token", sas.get(("gitea-runner-jobs", "default"), {}).get("automountServiceAccountToken") is False)

deploy = by_kind["Deployment"][0]
pod = deploy["spec"]["template"]["spec"]
ctr = pod["containers"][0]
check("runner: one replica", deploy["spec"]["replicas"] == 1)
check("runner: image pinned by digest", re.fullmatch(r"docker\.io/gitea/runner:[0-9.]+@sha256:[0-9a-f]{64}", ctr["image"]) is not None)
check("runner: non-root, seccomp RuntimeDefault", pod["securityContext"].get("runAsNonRoot") is True and pod["securityContext"]["seccompProfile"]["type"] == "RuntimeDefault")
sc = ctr["securityContext"]
check("runner: read-only root, no privilege escalation, drop ALL", sc.get("readOnlyRootFilesystem") is True and sc.get("allowPrivilegeEscalation") is False and sc["capabilities"]["drop"] == ["ALL"])
check("runner: registers with --token-file (token not in env or argv)", "--token-file /run/secrets/gitea-runner/token" in ctr["args"][0]
      and all("TOKEN" not in e["name"] for e in ctr.get("env", [])))
check("runner: talks to the Gitea Service, not to the public URL", {e["name"]: e.get("value") for e in ctr["env"]}.get("GITEA_INSTANCE_URL") == "http://gitea-http.gitea.svc:3000")
check("runner: no ports", "ports" not in ctr)
vols = {v["name"]: v for v in pod["volumes"]}
check("runner: registration secret gitea-runner-registration", vols["registration"]["secret"]["secretName"] == "gitea-runner-registration")

cfg = yaml.safe_load(by_kind["ConfigMap"][[c["metadata"]["name"] for c in by_kind["ConfigMap"]].index("gitea-runner-config")]["data"]["config.yaml"])
check("config: capacity 1", cfg["runner"]["capacity"] == 1)
check("config: bounded job time", re.fullmatch(r"\d+m", str(cfg["runner"]["timeout"])) is not None and int(str(cfg["runner"]["timeout"])[:-1]) <= 60)
check("config: cache server and metrics off (no open port)", cfg["cache"]["enabled"] is False and cfg["metrics"]["enabled"] is False)
check("config: copies through the API server (no listening transfer port)", cfg["kubernetes"]["transfer"]["mode"] == "api")
check("config: job pods in gitea-runner-jobs", cfg["kubernetes"]["namespace"] == "gitea-runner-jobs")
labels = cfg["runner"]["labels"]
check("config: only kubernetes:// labels (no host, no docker)", labels and all(re.fullmatch(r"[a-z0-9.-]+:kubernetes://\S+@sha256:[0-9a-f]{64}", l) for l in labels))
tmpl = cfg["kubernetes"]["pod_template"]["spec"]
check("job pod: no service account token requested", tmpl.get("automountServiceAccountToken", False) is False)
psc = tmpl["securityContext"]
check("job pod: runAsNonRoot uid 1000, seccomp RuntimeDefault", psc.get("runAsNonRoot") is True and psc.get("runAsUser") == 1000 and psc["seccompProfile"]["type"] == "RuntimeDefault")
job = [c for c in tmpl["containers"] if c["name"] == "job"]
check("job pod: template container named job", len(job) == 1)
job = job[0]
check("job pod: no privilege escalation, drop ALL", job["securityContext"].get("allowPrivilegeEscalation") is False and job["securityContext"]["capabilities"]["drop"] == ["ALL"])
check("job pod: bounded run time", 0 < tmpl.get("activeDeadlineSeconds", 0) <= 3600)
lint_image = yaml.safe_load((R / ".github/workflows/lint.yml").read_text(encoding="utf-8"))["jobs"]["lint"]["container"]["image"]
check("default job image = image of .github/workflows/lint.yml", labels[0].split("kubernetes://", 1)[1] == lint_image)

pols = {(d["metadata"]["namespace"], d["metadata"]["name"]): d for d in by_kind.get("NetworkPolicy", [])}
for ns in ("gitea-runner", "gitea-runner-jobs"):
    deny = pols.get((ns, "default-deny"), {}).get("spec", {})
    check("%s: default-deny ingress and egress" % ns, deny.get("podSelector") == {} and sorted(deny.get("policyTypes", [])) == ["Egress", "Ingress"])
    check("%s: no ingress allowed" % ns, not any("ingress" in d["spec"] for (n, _), d in pols.items() if n == ns))
jobs_egress = [r for (n, _), d in pols.items() if n == "gitea-runner-jobs" for r in d["spec"].get("egress", [])]
ports = sorted({p["port"] for r in jobs_egress for p in r.get("ports", [])})
check("job pods: egress only to ports 53, 443, 3000 (never 6443)", ports == [53, 443, 3000])
blocks = [t["ipBlock"] for r in jobs_egress for t in r.get("to", []) if "ipBlock" in t]
check("job pods: the only ipBlock is 0.0.0.0/0 with the private ranges excepted",
      len(blocks) == 1 and blocks[0]["cidr"] == "0.0.0.0/0"
      and {"10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "100.64.0.0/10", "127.0.0.0/8"} <= set(blocks[0].get("except", [])))
runner_egress = [r for (n, _), d in pols.items() if n == "gitea-runner" for r in d["spec"].get("egress", [])]
check("runner: egress only DNS, Gitea 3000 and the API server 6443", sorted({p["port"] for r in runner_egress for p in r["ports"]}) == [53, 3000, 6443])
check("runner: no egress to the internet", not any(t.get("ipBlock", {}).get("cidr") == "0.0.0.0/0" for r in runner_egress for t in r["to"]))
gpol = docs(R / "gitops/workloads/gitea/manifests/networkpolicy-runner.yaml")[0]
srcs = [f["namespaceSelector"]["matchLabels"]["kubernetes.io/metadata.name"] for r in gpol["spec"]["ingress"] for f in r["from"]]
check("gitea: lets in only gitea-runner and gitea-runner-jobs on 3000", sorted(srcs) == ["gitea-runner", "gitea-runner-jobs"]
      and [p["port"] for r in gpol["spec"]["ingress"] for p in r["ports"]] == [3000])

# ---- 3. budget
marker = re.compile(r"\bmemory:\s*(\d+)Mi\s*#\s*lab-limit:\s*(\S+)")
marks = {m.group(2): int(m.group(1)) for m in marker.finditer(text)}
check("marker gitea-runner/gitea-runner/runner", "gitea-runner/gitea-runner/runner" in marks)
check("marker gitea-runner-jobs/*/job", "gitea-runner-jobs/*/job" in marks)
job_limit = marks.get("gitea-runner-jobs/*/job")
check("job pod limit in the template = marked limit", job["resources"]["limits"]["memory"] == "%dMi" % (job_limit or 0))
check("runner limit in the deployment = marked limit", ctr["resources"]["limits"]["memory"] == "%dMi" % marks.get("gitea-runner/gitea-runner/runner", 0))
quota = [d for d in by_kind.get("ResourceQuota", []) if d["metadata"]["namespace"] == "gitea-runner-jobs"]
check("quota in gitea-runner-jobs", len(quota) == 1)
hard = quota[0]["spec"]["hard"] if quota else {}
check("quota: one pod at a time (capacity 1)", str(hard.get("pods")) == "1")
check("quota: limits.memory = the marked job limit", hard.get("limits.memory") == "%dMi" % (job_limit or 0))
lr = [d for d in by_kind.get("LimitRange", []) if d["metadata"].get("namespace") == "gitea-runner-jobs"]
check("LimitRange of the job namespace caps a container at the job limit", lr and lr[0]["spec"]["limits"][0]["max"]["memory"] == "%dMi" % (job_limit or 0))
# The public copy ships without the prod budget check and the prod inventory (scripts/public/exclude.txt).
if (R / "scripts/prod-budget-check.py").is_file():
    out = subprocess.run([sys.executable, str(R / "scripts/prod-budget-check.py"), "--repo", str(R)], capture_output=True, text=True)
    check("prod projection passes with runner, job and the largest periodic job", out.returncode == 0 and "BUDGET OK" in out.stdout)
    check("prod projection counts the job pod", re.search(r"^gitea-runner-jobs\s+1\s+%d$" % (job_limit or 0), out.stdout, re.M) is not None)
    steady = subprocess.run([sys.executable, str(R / "scripts/prod-budget-check.py"), "--repo", str(R), "--steady"], capture_output=True, text=True)
    check("--steady leaves the job pod out", "gitea-runner-jobs" not in steady.stdout)
else:
    print("SKIP: scripts/prod-budget-check.py is missing (public copy)")

# ---- 3b. backup window: no new CI job while CNPG or K8up may run
hc = cfg.get("health_check", {})
check("health_check is on and runs backup-window.sh", hc.get("enabled") is True and hc.get("script") == "/etc/gitea-runner/backup-window.sh")
check("free space floor cannot trip on the small /data volume", hc.get("min_free_disk_space_mb") == 1)
cm = by_kind["ConfigMap"][[c["metadata"]["name"] for c in by_kind["ConfigMap"]].index("gitea-runner-config")]["data"]
script = cm.get("backup-window.sh", "")
dep = by_kind["Deployment"][0]["spec"]["template"]["spec"]
cfg_vol = [v for v in dep["volumes"] if v["name"] == "config"][0]["configMap"]
check("the script is executable in the runner (defaultMode 0555)", cfg_vol.get("defaultMode") == 0o555)
blocked = []
if script and shutil.which("bash"):
    for minute in range(0, 1440, 5):
        hhmm = "%02d%02d" % divmod(minute, 60)
        probe = script.replace("$(date -u +%H%M)", hhmm)
        rc = subprocess.run(["bash", "-c", probe], capture_output=True).returncode
        if rc != 0:
            blocked.append(minute)
check("backup-window.sh blocks exactly 19:00-02:30 UTC", blocked == list(range(0, 150, 5)) + list(range(1140, 1440, 5)))
# Every CNPG ScheduledBackup and K8up schedule (start + 30 min deadline + 5 min) lies inside 20:00-02:30 UTC,
# and the gate starts early enough for the longest job (activeDeadlineSeconds) to end before 20:00.
starts = []
for f in sorted(R.glob("gitops/workloads/*/manifests/*.yaml")) + sorted(R.glob("gitops/workloads/*/*.yaml")):
    for doc in yaml.safe_load_all(f.read_text(encoding="utf-8")):
        if not isinstance(doc, dict):
            continue
        spec = doc.get("spec") or {}
        if doc.get("kind") == "ScheduledBackup":
            fields = spec["schedule"].split()
            starts.append((f.name, int(fields[2]) * 60 + int(fields[1])))
        elif doc.get("kind") == "Schedule":
            for action in ("backup", "prune", "check", "archive", "restore"):
                if isinstance(spec.get(action), dict) and "schedule" in spec[action]:
                    fields = spec[action]["schedule"].split()
                    starts.append((f.name + ":" + action, int(fields[1]) * 60 + int(fields[0])))
check("found the backup schedules (CNPG and K8up)", len(starts) >= 8)
def in_gate(minute):
    return minute >= 1200 or minute + 35 <= 150
outside = [s for s in starts if not in_gate(s[1])]
check("every backup action starts at or after 20:00 UTC and ends by 02:30 UTC", not outside)
if outside:
    print("  outside the window:", outside)
deadline = cfg["kubernetes"]["pod_template"]["spec"]["activeDeadlineSeconds"]
check("a job accepted at 18:59 UTC ends before 20:00 UTC (activeDeadlineSeconds)", 1139 + deadline / 60 < 1200)

# ---- 4. copies
gitconfig = by_kind["ConfigMap"][[c["metadata"]["name"] for c in by_kind["ConfigMap"]].index("gitea-runner-job-env")]["data"]["gitconfig"]
check("insteadOf host = Gitea DOMAIN", "insteadOf = https://%s/" % domain in gitconfig)
check("insteadOf target = Service gitea-http:3000", '[url "http://gitea-http.gitea.svc:3000/"]' in gitconfig)
for rel in ("ansible/inventory/group_vars/all/argocd.yml", "ansible/inventory/group_vars/prod/main.yml"):
    if not (R / rel).is_file():
        print("SKIP: %s is missing (public copy)" % rel)
        continue
    proj = yaml.safe_load((R / rel).read_text(encoding="utf-8"))["argocd_project_namespaces"]
    check("%s: both runner namespaces in argocd_project_namespaces" % rel, {"gitea-runner", "gitea-runner-jobs"} <= set(proj))
apps = (R / "gitops/apps/kustomization.yaml").read_text(encoding="utf-8")
check("apps kustomization lists gitea-runner and secrets-gitea-runner", "- gitea-runner.yaml" in apps and "- secrets-gitea-runner.yaml" in apps)
secrets = (R / "ansible/inventory/group_vars/all/secrets.yml").read_text(encoding="utf-8")
entry = re.search(r"- name: gitea-runner-token\n(?:    .*\n)+", secrets)
check("secrets.yml: gitea-runner-token is a generated pw of at least 32 characters",
      entry is not None and "kind: pw" in entry.group(0) and int(re.search(r"length: (\d+)", entry.group(0)).group(1)) >= 32)
for rel, ns, name in (("secrets/gitea/gitea-runner-token.sops.yaml.example", "gitea", "gitea-runner-token"),
                      ("secrets/gitea-runner/gitea-runner-registration.sops.yaml.example", "gitea-runner", "gitea-runner-registration")):
    ex = yaml.safe_load((R / rel).read_text(encoding="utf-8"))
    check("%s: %s/%s with the token from the file gitea-runner-token" % (rel, ns, name),
          ex["metadata"] == {**ex["metadata"], "name": name, "namespace": ns} and ex["stringData"] == {"token": "@file:gitea-runner-token"})
check("ksops gitea lists the token file", "./gitea-runner-token.sops.yaml" in (R / "secrets/gitea/ksops.yaml").read_text(encoding="utf-8"))
check("ksops gitea-runner lists the registration file", "./gitea-runner-registration.sops.yaml" in (R / "secrets/gitea-runner/ksops.yaml").read_text(encoding="utf-8"))
tracked = subprocess.run(["git", "-C", str(R), "ls-files", "secrets/gitea-runner", "secrets/gitea/gitea-runner-token.sops.yaml"], capture_output=True, text=True).stdout.split()
check("no rendered secret committed by this change (only templates, ksops, kustomization)",
      all(t.endswith((".example", "ksops.yaml", "kustomization.yaml")) or "sops:" in (R / t).read_text(encoding="utf-8") for t in tracked))
print("PYFAIL %d" % fails)
sys.exit(1 if fails else 0)
PY
ok "python rules" "$?" 0

echo "== render the Gitea chart (optional, needs the cached chart)"
CHART=$(find "$HOME/.cache" -name 'gitea-12.7.0.tgz' -print -quit 2> /dev/null)
if command -v helm > /dev/null 2>&1 && [ -n "$CHART" ]; then
  out=$(helm template gitea "$CHART" -n gitea -f "$R/gitops/workloads/gitea/values-gitea.yaml" 2>&1)
  printf '%s' "$out" | grep -q 'ENABLED=true'
  ok "helm: app.ini has actions ENABLED=true" "$?" 0
  python3 -c '
import sys, yaml
refs = []
for doc in yaml.safe_load_all(sys.stdin):
    if not doc:
        continue
    spec = doc.get("spec", {}).get("template", {}).get("spec", {})
    for container in spec.get("containers", []) + spec.get("initContainers", []):
        refs.extend(env.get("valueFrom", {}).get("secretKeyRef", {})
                    for env in container.get("env", [])
                    if env.get("name") == "GITEA_RUNNER_REGISTRATION_TOKEN")
assert refs and all(ref.get("optional") is True for ref in refs)
' <<< "$out"
  ok "helm: the token env is optional" "$?" 0
else
  echo "SKIP: helm or the cached gitea chart 12.7.0 is missing"
fi

echo
echo "$n checks, $fail failures"
[ "$fail" = 0 ]
