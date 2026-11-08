#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
"""Offline tests of the unattended lifecycle contract and PVC import evidence."""
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from unittest.mock import patch

ROOT = Path(sys.argv[1])
SOURCE = (ROOT / "scripts/lab.sh").read_text()
count = 0


def check(name, condition):
    global count
    count += 1
    print(("OK   " if condition else "FAIL ") + name, flush=True)
    if not condition:
        raise AssertionError(name)


def function(name):
    match = re.search(r"^" + name + r"\(\).*?^}", SOURCE, re.M | re.S)
    assert match, name
    return match.group()


def shell(names, script):
    code = "set -euo pipefail\n" + "\n".join(function(n) for n in names) + "\n" + script
    return subprocess.run(["bash", "-c", code], text=True, capture_output=True)


base = 'ARGO_SKIP=""; POLL=0; '
r = shell(["wait_for_argo"], base + '''argo_status() { printf 'root Synced/Healthy\\ndocs Synced/Degraded\\nnotes-notes Unknown/Unknown\\n'; }; wait_for_argo 0''')
check("optional docs and notes warn without waiting", r.returncode == 0 and "WARNING" in r.stdout)
r = shell(["wait_for_argo"], base + '''argo_status() { printf 'gitea Synced/Degraded\\ndocs Synced/Healthy\\n'; }; wait_for_argo 0''')
check("core degradation still fails", r.returncode == 1 and "gitea" in r.stderr)
r = shell(["wait_for_argo"], base + '''argo_status() { :; }; wait_for_argo 0''')
check("empty API response never counts as healthy", r.returncode == 1)
r = shell(["wait_for_argo"], base + '''argo_status() { echo 'docs Synced/Degraded'; }; wait_for_argo 0''')
check("optional-only response cannot hide missing core apps", r.returncode == 1)
r = shell(["acc_optional_site"], '''argo_status() { echo 'docs Synced/Degraded'; }; acc_optional_site docs false''')
check("unavailable optional acceptance is explicitly not a PASS", r.returncode == 0 and "not a PASS" in r.stdout)
r = shell(["acc_optional_site"], '''argo_status() { echo 'docs Synced/Healthy'; }; acc_optional_site docs false''')
check("failed optional site probe warns", r.returncode == 0 and "WARNING" in r.stdout)
for present in (True, False):
    script = '''calls=0; restarts=0
kubectl() { case "$*" in *"rollout restart"*) restarts=$((restarts+1));; esac; }
gitea_sso_present() { calls=$((calls+1)); [ "$calls" -gt FIRST ]; }
ensure_gitea_sso
[ "$restarts" = EXPECT ]
'''.replace("FIRST", "0" if present else "1").replace("EXPECT", "0" if present else "1")
    r = shell(["ensure_gitea_sso"], script)
    check("OIDC source present: no restart" if present else "missing OIDC source: one repair restart", r.returncode == 0)
r = shell(["ensure_gitea_sso"], '''kubectl() { return 0; }; gitea_sso_present() { return 1; }; ensure_gitea_sso''')
check("OIDC still absent after repair is an explicit failure", r.returncode == 1)
r = shell(["ensure_gitea_sso"], '''kubectl() { return 1; }; gitea_sso_present() { return 1; }; ensure_gitea_sso''')
check("without OIDC secret break-glass does not depend on Keycloak", r.returncode == 0)
r = shell(["cluster_ready"], '''L_wait_argo=0; POLL=0; kubectl() { return 1; }; wait_for_argo() { echo BAD; }; cluster_ready''')
check("API outage has a bounded failure before Argo and backups", r.returncode == 1 and "BAD" not in r.stdout)
r = shell(["cluster_ready"], '''L_wait_argo=1; POLL=0; calls=""; kubectl() { calls="$calls kube"; }; wait_for_argo() { calls="$calls argo"; }; wait_for_db() { calls="$calls db"; }; cluster_ready; [ "$calls" = ' kube kube argo db' ]''')
check("restart readiness checks API, Ready nodes, Argo and CNPG in order", r.returncode == 0)
flow = function("build_phases")
check("file restore must succeed before resume; no unconditional cleanup resume", flow.index('--tags restore') < flow.index('--tags resume') and 'phase "Restore Gitea and Matrix files" ans recover-files.yml --tags restore' in flow)
check("optional-app handling does not weaken restore failure guard", 'ROOT_PAUSED=0' not in function("cleanup") if re.search(r'^cleanup\(\)', SOURCE, re.M) else 'ROOT_PAUSED=0' not in SOURCE[SOURCE.index('cleanup()'):SOURCE.index('cleanup()')+2200])
check("restore rechecks and releases source trust only after import verification", flow.index('import_accept_restored') < flow.index('trust_recheck') < flow.index('trust_release'))
check("export awaits cluster readiness after restart", function("cmd_export").index('start "$VM"') < function("cmd_export").index('cluster_ready'))
check("sudo password prompt uses terminal and timeout", '>/dev/tty' in function("ask_sudo") and 'read -rs -t 120' in function("ask_sudo"))
check("export and drill use maintenance markers", 'maintenance_begin export' in function("cmd_export") and 'maintenance_begin restore-drill' in function("cmd_restore_drill"))
check("backup command wraps existing backup and WAL helpers", 'backup_fresh "$BACKUP_MODE"' in function("cmd_backup") and 'wal_ready' in function("cmd_backup"))
check("check and restore guard do not save or mutate import evidence", '--force-all | --post-restore) import_state_save' in function("backup_fresh"))

spec = importlib.util.spec_from_file_location("evidence", ROOT / "scripts/import-state.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
local_evidence = tempfile.TemporaryDirectory()
# Existing volume tests stay isolated from the operator's local evidence.
m.local_path = lambda target, namespace, deploy, context: Path(local_evidence.name) / target / "evidence.json"
sample = {"data": {"status": "ok", "manifest": "M users 1", "fingerprint": "digest", "argo_root": "off", "scaled_from": "0", "unexpected": "not-copied"}}
check("only durable evidence survives; no pause or arbitrary fields", m.baseline(json.dumps(sample)) == {"status": "ok", "manifest": "M users 1", "fingerprint": "digest"})
for target in m.TARGETS:
    calls = []
    def save(args, data=None):
        calls.append((args, data))
        return json.dumps(sample) if "get" in args else ""
    with patch.object(m, "run", save):
        check(target + " evidence saves atomically to backed-up /data", m.sync("save", target) == 0 and len(calls) == 2 and any('mv "$1.tmp" "$1"' in arg for arg in calls[1][0]) and 'argo_root' not in calls[1][1])
    calls = []
    def restore(args, data=None):
        calls.append((args, data))
        if "get" in args:
            return ""
        if "exec" in args:
            return json.dumps(sample)
        return ""
    with patch.object(m, "run", restore):
        result = m.sync("restore", target)
    applied = json.loads(calls[-1][1])
    check(target + " lost ConfigMap is restored from volume without re-import", result == 0 and applied["metadata"]["namespace"] == target and "scaled_from" not in applied["data"])
    with patch.object(m, "run", lambda *a, **kw: json.dumps(sample)):
        check(target + " existing evidence is idempotent", m.sync("restore", target) == 0)
    m.local_path(target, None, None, None).unlink()
    def absent(args, data=None):
        if "exec" in args:
            raise subprocess.CalledProcessError(44, args)
        return ""
    with patch.object(m, "run", absent):
        check(target + " legacy backup is SKIP, never a false PASS", m.sync("restore", target) == 3)
calls = []
def isolated(args, data=None):
    calls.append((args, data))
    if "get" in args:
        return ""
    if "exec" in args:
        return json.dumps(sample)
    return ""
with patch.object(m, "run", isolated):
    m.sync("restore", "matrix", "isolated", "test-synapse", "box-fixture")
check("evidence never escapes the explicitly selected Kubernetes context",
      all(args[:2] == ["--context", "box-fixture"] for args, _ in calls))
check("evidence inherits custom namespace and deployment",
      "deploy/test-synapse" in calls[1][0] and json.loads(calls[-1][1])["metadata"]["namespace"] == "isolated")
try:
    m.baseline('{"data":{"status":"running","manifest":"M users 1"}}')
    valid = False
except ValueError:
    valid = True
check("incomplete import cannot become a successful restored baseline", valid)

build = (ROOT / 'docs/build.sh').read_text()
import re
url_pin = re.search(r'^ZG_URL=\$\{ZG_URL:-(.+)\}$', build, re.M)
commit_pin = re.search(r'^ZG_COMMIT=\$\{ZG_COMMIT:-(.+)\}$', build, re.M)
# The private tree supports the graph; the public export deliberately removes the feature.
# Test the feature contract rather than the private operator's account name.
plugin = "zensical" + "-graph"
from urllib.parse import urlparse
import tomllib
config = tomllib.loads((ROOT / "zensical.toml").read_text())
graph = config.get("project", {}).get("plugins", {}).get("graph")
if isinstance(graph, dict):
    check('docs build pins the GitHub graph mirror by default',
          bool(url_pin) and urlparse(url_pin.group(1)).hostname == "github.com"
          and urlparse(url_pin.group(1)).path.endswith("/" + plugin + ".git"))
    check('docs build pins an exact graph commit',
          bool(commit_pin) and commit_pin.group(1) == '93b8a4ce481d3f3cd72a6829c92f01e0ec00c10e')
    check('docs build has no silent private Gitea default for the plugin',
          bool(url_pin) and urlparse(url_pin.group(1)).hostname == "github.com")
else:
    check('docs build without graph has no plugin source or commit', not url_pin and not commit_pin)
    check('docs build without graph does not invoke the plugin', 'zensical_graph' not in build)
check('docs build does not vendor the graph plugin in-tree',
      not (ROOT / 'docs' / 'vendor' / plugin).exists())
check('notes chart has no flat zg-* plugin copies',
      not any((ROOT / 'gitops/charts/notes-site/files').glob('zg-*')))

print(f'{count} checks, 0 failures')
