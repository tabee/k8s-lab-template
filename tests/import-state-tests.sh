#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
python3 - "$R" <<'PYTEST'
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from unittest.mock import patch

root = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("evidence", root / "scripts/import-state.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
checks = 0

def check(name, condition):
    global checks
    checks += 1
    assert condition, name
    print("OK   " + name)

sample = {"data": {"status": "ok", "manifest": "M users 5", "fingerprint": "hash", "password": "not-durable"}}
with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {"LAB_IMPORT_STATE_DIR": directory}):
    for target in m.TARGETS:
        calls = []
        values = {"users": 5, "organisations": 1, "repositories": 3} if target == "gitea" else {"users": 5, "rooms": 2, "events": 100, "media": 7}
        def fake(args, data=None):
            calls.append((args, data))
            if args[:2] == ["config", "current-context"]:
                return "fixture-context"
            if "get" in args and "cluster" in args:
                return json.dumps({"status": {"currentPrimary": "db-1"}})
            if "patch" in args:
                sample["data"].update(json.loads(args[-1])["data"])
            if "get" in args:
                return json.dumps(sample)
            if "psql" in args:
                return json.dumps(values)
            return ""
        with patch.object(m, "run", fake):
            check(target + " captures live pre-destroy counts", m.sync("capture", target) == 0)
            path = m.local_path(target, target, m.TARGETS[target][0], None)
            saved = json.loads(path.read_text())["data"]
            check(target + " local delivery note is private", path.stat().st_mode & 0o777 == 0o600 and path.parent.stat().st_mode & 0o777 == 0o700 and path.parent.parent.stat().st_mode & 0o777 == 0o700)
            check(target + " allowlist excludes arbitrary fields", "password" not in saved)
            check(target + " captures durable counts", json.loads(saved["restore_counts"]) == values)
            check(target + " subsequent backup preserves pre-destroy counts", m.sync("save", target) == 0 and json.loads(path.read_text())["data"]["restore_counts"] == saved["restore_counts"])
            check(target + " context isolation", path != m.local_path(target, target, m.TARGETS[target][0], "another-context"))
            check(target + " namespace isolation", path != m.local_path(target, "another-namespace", m.TARGETS[target][0], None))
        def lost(args, data=None):
            calls.append((args, data))
            if args[:2] == ["config", "current-context"]:
                return "fixture-context"
            if "get" in args:
                return ""
            if "exec" in args:
                raise subprocess.CalledProcessError(44, args)
            return ""
        with patch.object(m, "run", lost):
            check(target + " missing ConfigMap and volume use local fallback", m.sync("restore", target) == 0)
        check(target + " fallback recreates only durable ConfigMap data", json.loads(calls[-1][1])["data"] == saved)
        def verified(args, data=None):
            if "get" in args and "cm" in args:
                return json.dumps({"data": saved})
            return fake(args, data)
        with patch.object(m, "run", verified):
            check(target + " restored counts compare with pre-destroy baseline", m.sync("verify", target) == 0)
            values["users"] -= 1
            check(target + " missing restored objects fail closed", m.sync("verify", target) == 1)
            values["users"] += 2
            check(target + " new objects after resume are allowed", m.sync("verify", target) == 0)
        def unreadable_volume(args, data=None):
            if "exec" in args:
                raise subprocess.CalledProcessError(1, args)
            return lost(args, data)
        with patch.object(m, "run", unreadable_volume):
            try:
                m.sync("restore", target)
                valid = False
            except subprocess.CalledProcessError:
                valid = True
            check(target + " API errors cannot be hidden by a valid local fallback", valid)
        # Invalid local evidence must never become a successful import baseline.
        path.write_text('{"data":{"status":"running","manifest":"M users 5"}}')
        with patch.object(m, "run", lost):
            try:
                m.sync("restore", target)
                valid = False
            except ValueError:
                valid = True
            check(target + " incomplete local import fails closed", valid)
            path.unlink()
            check(target + " no baseline remains SKIP, not PASS", m.sync("restore", target) == 3)

with tempfile.TemporaryDirectory() as directory:
    path = Path(directory) / "scope" / "evidence.json"
    m.write_local(path, {"manifest": "old"})
    with patch.object(m.os, "replace", side_effect=OSError("fixture failure")):
        try:
            m.write_local(path, {"manifest": "new"})
        except OSError:
            pass
    check("failed local rename preserves the last complete delivery note", json.loads(path.read_text())["data"]["manifest"] == "old")
    check("failed local rename removes its temporary file", list(path.parent.iterdir()) == [path])

source = (root / "scripts/lab.sh").read_text()
start = source.index("import_accept_restored() {")
end = source.index("\n}", start) + 2
function = source[start:end]
script = "set -euo pipefail\n" + function + "\nREPO=/unused; python3() { return 0; }; bash() { echo failed-$*; return 1; }; import_accept_restored"
r = subprocess.run(["bash", "-c", script], capture_output=True, text=True)
check("automatic import failures warn and still check both services", r.returncode == 0 and r.stdout.count("failed-") == 2 and r.stderr.count("NOT accepted") == 2)
check("capture precedes fresh backups and destruction", source.index('phase "Capture pre-destroy import counts"') < source.index('phase "Fresh backups before the VM is destroyed"') < source.index('  restore_marker_set\n'))
print(f"{checks} checks, 0 failures")
PYTEST
