#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
"""Render CNPG recovery specs for one rebuild --restore. Never writes the repo.

Git stays on bootstrap.initdb and the original serverName. CNPG will not archive
into a serverName that already has files, and it reads bootstrap only when the
cluster is created. This script picks the highest server generation whose newest
completed base backup has its end WAL on disk, and the next empty name as the
write target. A higher generation without that segment is skipped. It writes
those Cluster manifests to --out, which must be outside the repo.

backup.info may be a plain file or a rustfs directory whose xl.meta holds the
same text. A STARTED record with end_wal=None is ignored. A .backup history
file is not a WAL segment.

Prints one RENDER line per cluster (names only, never a secret). Exit 0 when
every cluster has a replayable base backup to read and an empty prefix to write.
Exit 1 otherwise, and then --out is left untouched.
"""
import argparse
import copy
import os
import re
import sys

import yaml

CLUSTERS = (
    "gitops/workloads/db-lab/cluster.yaml",
    "gitops/workloads/gitea/manifests/cluster.yaml",
    "gitops/workloads/matrix/manifests/cluster.yaml",
    "gitops/workloads/keycloak/manifests/cluster.yaml",
)
INITDB_KEYS = {"database", "owner", "secret"}


IDLE_HINT = " (idle database: its end WAL segment is still open. Seal it: bash scripts/lab.sh rebuild --restore does it on a running VM, or by hand: checkpoint, then select pg_switch_wal(), see #111)"

def next_name(name):
    match = re.fullmatch(r"(.+-r)(\d+)", name)
    if not match:
        return name + "-r2"
    return match.group(1) + str(int(match.group(2)) + 1)


def generation(base, name):
    if name == base:
        return 0
    match = re.fullmatch(re.escape(base) + r"-r(\d+)", name)
    if not match:
        return None
    return int(match.group(1))


def load_yaml(path):
    with open(path, encoding="utf-8") as handle:
        return yaml.safe_load(handle)


def archive_parent(data_dir, objectstore_path):
    doc = load_yaml(objectstore_path)
    dest = doc["spec"]["configuration"]["destinationPath"]
    if not str(dest).startswith("s3://"):
        raise ValueError("destinationPath is not s3://")
    rest = dest[len("s3://"):]
    bucket, _, prefix = rest.partition("/")
    parts = [data_dir, bucket]
    if prefix:
        parts.extend(piece for piece in prefix.strip("/").split("/") if piece)
    return os.path.join(*parts)


def occupied(path):
    try:
        with os.scandir(path) as scan:
            return any(True for _ in scan)
    except FileNotFoundError:
        return False


END_WAL = re.compile(r"[0-9A-Fa-f]{24}\Z")
INFO_TOKEN = re.compile(br"(status|end_wal)=([^\s\x00]*)")
INFO_LIMIT = 4 * 1024 * 1024


def info_bytes(path):
    """Plain backup.info, or the xl.meta inside a rustfs backup.info directory."""
    target = path
    if os.path.isdir(path):
        target = os.path.join(path, "xl.meta")
    if not os.path.isfile(target):
        return b""
    size = os.path.getsize(target)
    if size <= 0 or size > INFO_LIMIT:
        return b""
    with open(target, "rb") as handle:
        return handle.read()


def done_end_wal(blob):
    """Last DONE end_wal that is 24 hex digits. A STARTED record does not count."""
    pending = None
    chosen = None
    for key, raw in INFO_TOKEN.findall(blob):
        value = raw.decode("utf-8", "replace")
        if key == b"end_wal":
            pending = value
        elif key == b"status":
            if value == "DONE" and pending and END_WAL.fullmatch(pending):
                chosen = pending
            pending = None
    return chosen


def object_present(path):
    """A non-empty file, or a rustfs object directory that contains xl.meta."""
    if os.path.isfile(path) and os.path.getsize(path) > 0:
        return True
    meta = os.path.join(path, "xl.meta")
    return os.path.isdir(path) and os.path.isfile(meta) and os.path.getsize(meta) > 0


def wal_present(server, end_wal):
    """The segment lives at wals/<first 16 chars>/<name> with an optional .gz."""
    folder = os.path.join(server, "wals", end_wal[:16])
    plain = os.path.join(folder, end_wal)
    return object_present(plain) or object_present(plain + ".gz")


def backup_records(server):
    """(backup id, backup.info path) oldest first. Id '' is a backup.info directly in base/."""
    base = os.path.join(server, "base")
    found = []
    try:
        entries = list(os.scandir(base))
    except FileNotFoundError:
        return []
    for entry in entries:
        if entry.name == "backup.info":
            found.append(("", entry.path))
        elif entry.is_dir(follow_symlinks=False):
            info = os.path.join(entry.path, "backup.info")
            if os.path.lexists(info):
                found.append((entry.name, info))
    found.sort()
    return found


def replayable(server):
    """Newest backup id with a DONE end WAL must have that segment. Older ids are used
    only when every newer id has no DONE record."""
    for _bid, path in reversed(backup_records(server)):
        end = done_end_wal(info_bytes(path))
        if end is None:
            continue
        return wal_present(server, end)
    return False


def plan_one(repo, data_dir, rel):
    cluster_path = os.path.join(repo, rel)
    doc = load_yaml(cluster_path)
    spec = doc["spec"]
    boot = spec["bootstrap"]
    if "initdb" not in boot or "recovery" in boot:
        raise ValueError("Git must stay on bootstrap.initdb")
    extra = set(boot["initdb"]) - INITDB_KEYS
    if extra or "database" not in boot["initdb"] or "owner" not in boot["initdb"]:
        raise ValueError("initdb must name database and owner, and nothing else")
    base = spec["plugins"][0]["parameters"]["serverName"]
    if not base or generation(base, base) != 0 or re.fullmatch(r".+-r\d+", base):
        raise ValueError("Git serverName must be the original name")
    parent = archive_parent(data_dir, os.path.join(os.path.dirname(cluster_path), "objectstore.yaml"))
    found = []
    try:
        names = [entry.name for entry in os.scandir(parent)]
    except FileNotFoundError:
        names = []
    for name in names:
        gen = generation(base, name)
        if gen is None:
            continue
        server = os.path.join(parent, name)
        if replayable(server):
            found.append((gen, name))
    if not found:
        raise ValueError("no replayable base backup under %s%s" % (parent, IDLE_HINT))
    found.sort()
    read = found[-1][1]
    write = next_name(read)
    if occupied(os.path.join(parent, write)):
        raise ValueError("write prefix %s already has files: the newest generation is not sealed%s" % (write, IDLE_HINT))
    return {"file": rel, "cluster": doc["metadata"]["name"], "read": read, "write": write, "doc": doc}


def render(doc, read_name, write_name):
    out = copy.deepcopy(doc)
    initdb = out["spec"]["bootstrap"]["initdb"]
    recovery = {"source": "origin"}
    for key in ("database", "owner", "secret"):
        if key in initdb:
            recovery[key] = copy.deepcopy(initdb[key])
    out["spec"]["bootstrap"] = {"recovery": recovery}
    plugin = copy.deepcopy(out["spec"]["plugins"][0])
    plugin["enabled"] = True
    plugin["isWALArchiver"] = False
    plugin["parameters"]["serverName"] = read_name
    out["spec"]["externalClusters"] = [{"name": "origin", "plugin": plugin}]
    out["spec"]["plugins"][0]["parameters"]["serverName"] = write_name
    return out


def outside_repo(repo, out):
    repo = os.path.abspath(repo)
    out = os.path.abspath(out)
    return out != repo and not out.startswith(repo + os.sep)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--data-dir", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    repo = os.path.abspath(args.repo)
    if not outside_repo(repo, args.out):
        print("FAIL --out must be outside the repo", file=sys.stderr)
        return 1
    planned = []
    failed = False
    for rel in CLUSTERS:
        try:
            planned.append(plan_one(repo, args.data_dir, rel))
        except (OSError, ValueError, KeyError, IndexError, TypeError, yaml.YAMLError) as exc:
            print("FAIL %s: %s" % (rel, exc), file=sys.stderr)
            failed = True
    if failed:
        return 1
    os.makedirs(args.out, mode=0o700, exist_ok=True)
    os.chmod(args.out, 0o700)
    for item in planned:
        rendered = render(item["doc"], item["read"], item["write"])
        name = "%s-%s.yaml" % (rendered["metadata"]["namespace"], rendered["metadata"]["name"])
        path = os.path.join(args.out, name)
        with open(path, "w", encoding="utf-8") as handle:
            yaml.safe_dump(rendered, handle, sort_keys=False, allow_unicode=True)
        os.chmod(path, 0o600)
        print("RENDER %s read %s write %s" % (item["cluster"], item["read"], item["write"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
