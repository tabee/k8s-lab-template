#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
"""Keep non-secret import evidence on the control machine and backed-up volume.

Exit 3 means no baseline exists (legacy backup or no import), never a passed acceptance.
Only durable evidence is copied: pause/scale/recovery state must never survive a rebuild.
"""
import argparse
import json
import os
from pathlib import Path
import hashlib
import tempfile
import subprocess
import sys

FIELDS = frozenset("manifest status dump_hash fingerprint imported_at gitea_dump_version "
                   "server_name signing_sha verify_key_id verify_key source_host source_created "
                   "synapse_dump_version snapshot snapshot_post restore_counts".split())
TARGETS = {"gitea": ("gitea", "gitea"), "matrix": ("synapse", "synapse")}
PATH = "/data/.lab-import-state.json"


def run(args, data=None):
    return subprocess.run(["kubectl", *args], input=data, text=True, capture_output=True, check=True, timeout=120).stdout


def baseline(raw):
    obj = json.loads(raw)
    if not isinstance(obj, dict):
        raise ValueError("invalid import evidence object")
    data = obj.get("data", {})
    if not isinstance(data, dict) or any(not isinstance(v, str) for v in data.values()):
        raise ValueError("invalid import evidence")
    if not data.get("manifest"):
        return None
    if data.get("status") != "ok":
        raise ValueError("import evidence is not from a completed import")
    return {key: value for key, value in data.items() if key in FIELDS}


# Count only durable objects, not login tokens or background-job state.
COUNT_SQL = {
    "gitea": "SELECT json_build_object('users', (SELECT count(*) FROM \"user\" WHERE id > 0 AND type = 0), "
             "'organisations', (SELECT count(*) FROM \"user\" WHERE id > 0 AND type = 1), "
             "'repositories', (SELECT count(*) FROM repository))",
    "matrix": "SELECT json_build_object('users', (SELECT count(*) FROM users), "
              "'rooms', (SELECT count(*) FROM rooms), 'events', (SELECT count(*) FROM events), "
              "'media', (SELECT count(*) FROM local_media_repository))",
}


def local_path(target, namespace, deploy, context):
    # An implicit context must be resolved, otherwise a switched kubeconfig could
    # silently supply another cluster's delivery note.
    context = context or run(["config", "current-context"]).strip()
    if not context:
        raise ValueError("no Kubernetes context for local import evidence")
    scope = hashlib.sha256(json.dumps([context, namespace, deploy]).encode()).hexdigest()[:24]
    root = Path(os.environ.get("LAB_IMPORT_STATE_DIR", "~/k8s-lab-data/import-state")).expanduser()
    return root / scope / (target + ".json")


def write_local(path, data):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    path.parent.chmod(0o700)
    path.parent.parent.chmod(0o700)
    fd, temporary = tempfile.mkstemp(prefix=".import-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump({"data": data}, stream)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def counts(kubectl, ns, target):
    raw = kubectl([*ns, "get", "cluster", target + "-db", "-o", "json"])
    primary = json.loads(raw)["status"]["currentPrimary"]
    raw = kubectl([*ns, "exec", primary, "-c", "postgres", "--", "psql", "-X", "-q", "-At",
                   "-v", "ON_ERROR_STOP=1", "-d", os.environ.get(target.upper() + "_IMPORT_DB_NAME", target), "-c", COUNT_SQL[target]])
    result = json.loads(raw)
    if not isinstance(result, dict):
        raise ValueError("invalid restore count object")
    if set(result) != ({"users", "organisations", "repositories"} if target == "gitea" else {"users", "rooms", "events", "media"}):
        raise ValueError("invalid restore count keys")
    if any(type(value) is not int or value < 0 for value in result.values()):
        raise ValueError("invalid restore counts")
    return result


def sync(action, target, namespace=None, deployment=None, context=None):
    def kubectl(args, data=None):
        prefix = ["--context", context] if context else []
        return run([*prefix, *args], data)

    deploy, container = TARGETS[target]
    namespace = namespace or os.environ.get(target.upper() + "_IMPORT_NS", target)
    deploy = deployment or os.environ.get(target.upper() + "_IMPORT_DEPLOY", deploy)
    ns = ["-n", namespace]
    cm = target + "-import-state"
    live = kubectl([*ns, "get", "cm", cm, "--ignore-not-found", "-o", "json"])
    data = baseline(live) if live.strip() else None
    if action in ("save", "capture"):
        if data is None:
            print(f"SKIP: no {target} import evidence to save.")
            return 0
        if action == "capture":
            data["restore_counts"] = json.dumps(counts(kubectl, ns, target), sort_keys=True)
            kubectl([*ns, "patch", "cm", cm, "--type", "merge", "-p",
                     json.dumps({"data": {"restore_counts": data["restore_counts"]}})])
        write_local(local_path(target, namespace, deploy, context), data)
        # Same-volume rename: a killed write never replaces the last good baseline.
        command = ['sh', '-c', 'umask 077; cat > "$1.tmp" && mv "$1.tmp" "$1"', 'sh', PATH]
        kubectl([*ns, "exec", "-i", "deploy/" + deploy, "-c", container, "--", *command],
            json.dumps({"data": data}) + "\n")
        print(f"Saved {target} import evidence on the control machine and backed-up volume.")
        return 0
    if action == "verify":
        if data is None or not data.get("restore_counts"):
            print(f"SKIP: no pre-destroy {target} counts; import manifest checks still required.")
            return 0
        expected = json.loads(data["restore_counts"])
        actual = counts(kubectl, ns, target)
        if not isinstance(expected, dict):
            raise ValueError("invalid saved restore count object")
        if set(expected) != set(actual) or any(type(v) is not int or v < 0 for v in expected.values()):
            raise ValueError("invalid saved restore counts")
        failed = False
        for key, value in actual.items():
            ok = value >= expected[key]
            print(f"{'OK' if ok else 'FAIL'}: {target} {key}: {value}, pre-destroy {expected[key]}")
            failed |= not ok
        return int(failed)
    if data is not None:
        print(f"{target} import evidence already present.")
        return 0
    try:
        raw = kubectl([*ns, "exec", "deploy/" + deploy, "-c", container, "--", "sh", "-c",
                   'if [ -f "$1" ]; then cat "$1"; else exit 44; fi', 'sh', PATH])
    except subprocess.CalledProcessError as error:
        if error.returncode != 44:
            raise
        path = local_path(target, namespace, deploy, context)
        if not path.exists():
            print(f"SKIP: no saved {target} import baseline (volume or control machine).")
            return 3
        raw = path.read_text()
    data = baseline(raw)
    if data is None:
        raise ValueError("saved import evidence has no manifest")
    obj = {"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"namespace": namespace, "name": cm}, "data": data}
    kubectl(["apply", "-f", "-"], json.dumps(obj))
    print(f"Restored {target} import evidence; acceptance must still verify the data.")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["save", "restore", "capture", "verify"])
    parser.add_argument("target", choices=TARGETS)
    parser.add_argument("--namespace")
    parser.add_argument("--deployment")
    parser.add_argument("--context")
    args = parser.parse_args()
    try:
        return sync(args.action, args.target, args.namespace, args.deployment, args.context)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, ValueError, OSError, KeyError, TypeError):
        # No command output: the evidence contains private identifiers, never log it.
        print("ERROR: import evidence could not be saved/restored; no acceptance claimed.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
