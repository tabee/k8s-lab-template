#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
# Offline proofs for the bounded periodic calendar and actual overlap rejection.
set -euo pipefail
R=$(cd "${1:-$(dirname "${BASH_SOURCE[0]}")/..}" && pwd -P)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
python3 - "$R" "$T" <<'PYTEST'
import copy, importlib.util, json, shutil, subprocess, sys
from pathlib import Path
import yaml
root, tmp = map(Path, sys.argv[1:])
spec = importlib.util.spec_from_file_location("mb", root / "scripts/memory-budget.py")
mb = importlib.util.module_from_spec(spec); spec.loader.exec_module(mb)
repo = tmp / "repo"
shutil.copytree(root / "gitops", repo / "gitops")
path = "ansible/roles/argocd_bootstrap/tasks/gitops.yml"
(repo / path).parent.mkdir(parents=True)
shutil.copy(root / path, repo / path)
count = 0

def ok(name, condition):
    global count
    assert condition, name
    count += 1
    print("OK   " + name)

def mutate(rel, fn):
    p = repo / rel; original = p.read_text()
    doc = yaml.safe_load(original); fn(doc); p.write_text(yaml.safe_dump(doc))
    result = mb.stagger_problems(repo); p.write_text(original)
    return result

def walk(value):
    if isinstance(value, dict):
        yield value
        for item in value.values(): yield from walk(item)
    elif isinstance(value, list):
        for item in value: yield from walk(item)

def project(doc):
    return next(obj for obj in walk(doc) if obj.get("kind") == "AppProject" and obj.get("spec", {}).get("syncWindows"))

ok("bounded weekly calendar is valid", not mb.stagger_problems(repo))
rel = "gitops/workloads/matrix/manifests/k8up-schedule.yaml"
ok("same-time cross-namespace schedules fail", mutate(rel, lambda d: d["spec"]["backup"].update(schedule="30 20 * * *")))
ok("deadline longer than slot fails", mutate(rel, lambda d: d["spec"]["backup"].update(activeDeadlineSeconds=7200)))
ok("missing deadline fails closed", mutate(rel, lambda d: d["spec"]["backup"].pop("activeDeadlineSeconds")))
ok("concurrent action runs fail", mutate(rel, lambda d: d["spec"]["backup"].update(concurrentRunsAllowed=True)))
ok("randomized cron fails closed", mutate(rel, lambda d: d["spec"]["backup"].update(schedule="@random")))
ok("Saturday to Sunday wrap overlap fails", mutate(rel, lambda d: d["spec"]["prune"].update(schedule="59 23 * * *")))
ok("missing sync fence fails", mutate(path, lambda d: project(d)["spec"].pop("syncWindows")))
ok("manual override of sync fence fails", mutate(path, lambda d: project(d)["spec"]["syncWindows"][0].update(manualSync=True)))
ok("sync overrun bypass fails", mutate(path, lambda d: project(d)["spec"]["syncWindows"][0].update(syncOverrun=True)))
ok("short sync fence fails", mutate(path, lambda d: project(d)["spec"]["syncWindows"][0].update(duration="1h")))
ok("non-UTC scheduler fails", mutate("gitops/platform/k8up/values.yaml", lambda d: d["k8up"].update(timezone="Europe/Zurich")))
ok("CNPG must use already counted sidecars", mutate("gitops/workloads/gitea/manifests/scheduledbackup.yaml", lambda d: d["spec"].update(method="barmanObjectStore")))
# The live calendar must be checked too; a not-yet-deployed Git change is not proof.
live = []
for ns in ("gitea", "matrix"):
    for name in ("k8up-schedule.yaml", "k8up-podconfig.yaml"):
        live.append(yaml.safe_load((repo / ("gitops/workloads/%s/manifests/%s" % (ns, name))).read_text()))
live.append(copy.deepcopy(project(yaml.safe_load((repo / path).read_text()))))
ok("matching deployed policy is valid", not mb.stagger_problems(repo, live))
stale = copy.deepcopy(live); stale[2]["spec"]["backup"]["schedule"] = "30 20 * * *"
ok("stale overlapping deployed policy fails", mb.stagger_problems(repo, stale))
ok("missing deployed fence fails", mb.stagger_problems(repo, live[:-1]))
stale = copy.deepcopy(live)
stale[1]["spec"]["template"]["spec"]["containers"][0]["resources"]["limits"]["memory"] = "1Gi"
ok("larger deployed job limit fails", mb.stagger_problems(repo, stale))

def pod(ns, name, ctr, mib):
    return {"metadata": {"namespace": ns, "name": name}, "status": {"phase": "Running"},
            "spec": {"containers": [{"name": ctr, "resources": {"limits": {"memory": "%dMi" % mib}}}]}}
pods = [pod("gitea", "backup-gitea", "backup", 512), pod("matrix", "check-matrix", "check", 512),
        pod("keycloak", "keycloak-config", "config-cli", 384), pod("gitea", "gitea-db-1", "postgres", 256)]
projected, errors = mb.staggered_projection(pods, repo)
ok("offline model is steady plus max single job", not errors and len(projected) == 2)
old = (repo / rel).read_text(); (repo / rel).write_text(old.replace('"30 21 * * *"', '"30 20 * * *"'))
projected, errors = mb.staggered_projection(pods, repo)
ok("invalid calendar never gets the max discount", errors and len(projected) == 4)
(repo / rel).write_text(old)
# Real Running/Pending pods are NEVER reduced to max, even if their sum fits.
payload = {"memory_mib": 8192, "reserve_mib": 1536, "periodic_stagger_enforce": True,
           "periodic_resources": live, "pods": pods[:1] + pods[2:3], "nodes": []}
cmd = [sys.executable, str(root / "scripts/memory-budget.py"), "check", "--repo", str(repo)]
proc = subprocess.run(cmd, input=json.dumps(payload), text=True, capture_output=True)
ok("actual overlap fails despite fitting RAM", proc.returncode == 1 and "STAGGER active periodic pods overlap" in proc.stdout)
ok("actual sum is not replaced by max", "896" in proc.stdout)
payload["pods"][1]["status"]["phase"] = "Pending"
proc = subprocess.run(cmd, input=json.dumps(payload), text=True, capture_output=True)
ok("pending hooks count as overlap", proc.returncode == 1 and "STAGGER active periodic pods overlap" in proc.stdout)
payload["periodic_stagger_enforce"] = False
proc = subprocess.run(cmd, input=json.dumps(payload), text=True, capture_output=True)
ok("lab overlap is a warning, not enforcement", proc.returncode == 0 and "WARNING stagger" in proc.stdout)
print("%d checks, 0 failures" % count)
PYTEST
