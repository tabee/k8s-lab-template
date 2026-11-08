#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
"""Wait until the latest completed CNPG backup can be restored.

A Backup phase of "completed" means the base backup is in the bucket.
Recovery also needs the WAL segment named by status.endWal. Postgres
uploads that segment only once it is full or switched. This command
writes one tiny WAL record (pg_logical_emit_message, so that an idle
cluster has something to switch), switches WAL and waits until
pg_stat_archiver.last_archived_wal is at least that name. lab.sh down, lab.sh export and lab.sh rebuild --restore
call it before they stop a running VM. A cluster that exists and has no
completed backup is a failure. An empty cluster list is success: there is
nothing to protect yet. There is no flag to skip the check.
"""
import argparse
import json
import subprocess
import sys
import time

WAL_LEN = 24
WAL_MARKER = "lab-wal-ready"
HEX = set("0123456789ABCDEFabcdef")


def covers(archived, needed):
    """True when archived is a WAL name at or after needed.

    Names are the 24-character PostgreSQL WAL file names. Lexicographic
    order matches WAL order, including the timeline prefix. Anything
    else is not covered: a short or empty name must not pass.
    """
    if not isinstance(archived, str) or not isinstance(needed, str):
        return False
    if len(archived) != WAL_LEN or len(needed) != WAL_LEN:
        return False
    if any(char not in HEX for char in archived + needed):
        return False
    return archived >= needed


def select_backup(items, namespace, cluster):
    """Latest completed Backup for one cluster, or None.

    stoppedAt is RFC3339, so the greatest string is the newest.
    """
    best = None
    best_time = ""
    for item in items:
        meta = item.get("metadata") or {}
        spec = item.get("spec") or {}
        target = (spec.get("cluster") or {}).get("name")
        if meta.get("namespace") != namespace or target != cluster:
            continue
        status = item.get("status") or {}
        if status.get("phase") != "completed":
            continue
        stopped = status.get("stoppedAt") or ""
        if best is None or stopped >= best_time:
            best = item
            best_time = stopped
    return best


def kubectl_json(args):
    result = subprocess.run(
        ["kubectl", *args, "-o", "json"],
        check=False,
        capture_output=True,
        text=True,
        timeout=60,
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "kubectl failed").strip().splitlines()
        raise RuntimeError(detail[-1][:200] if detail else "kubectl failed")
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError("kubectl returned no JSON") from exc


def psql(namespace, pod, sql):
    result = subprocess.run(
        [
            "kubectl", "exec", "-n", namespace, pod, "-c", "postgres", "--",
            "psql", "-U", "postgres", "-d", "postgres", "-Atc", sql,
        ],
        check=False,
        capture_output=True,
        text=True,
        timeout=60,
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "psql failed").strip().splitlines()
        raise RuntimeError(detail[-1][:200] if detail else "psql failed")
    lines = [line.strip() for line in result.stdout.splitlines() if line.strip()]
    return lines[-1] if lines else ""


def load_world():
    clusters = kubectl_json(["get", "clusters.postgresql.cnpg.io", "-A"]).get("items") or []
    backups = kubectl_json(["get", "backups.postgresql.cnpg.io", "-A"]).get("items") or []
    return clusters, backups


def one_cluster(cluster, backups, attempts, interval):
    """Seal one cluster. Returns a result line and True on success."""
    meta = cluster.get("metadata") or {}
    namespace = meta.get("namespace") or "?"
    name = meta.get("name") or "?"
    label = "%s/%s" % (namespace, name)
    status = cluster.get("status") or {}
    primary = status.get("currentPrimary") or ""
    backup = select_backup(backups, namespace, name)
    if backup is None:
        return "FAIL %s no completed backup" % label, False
    end_wal = ((backup.get("status") or {}).get("endWal")) or ""
    if not primary:
        return "FAIL %s no primary, endWal=%s" % (label, end_wal or "-"), False
    if not covers(end_wal, end_wal):
        return "FAIL %s completed backup has no endWal" % label, False
    try:
        archived = psql(namespace, primary, "SELECT COALESCE(last_archived_wal, '') FROM pg_stat_archiver")
    except RuntimeError as exc:
        return "FAIL %s cannot read archiver (%s)" % (label, exc), False
    if covers(archived, end_wal):
        return "OK   %s endWal=%s archived=%s" % (label, end_wal, archived), True
    # On an idle cluster the current segment can be empty: pg_switch_wal() then does nothing and the end
    # WAL is never archived. A tiny non-transactional logical message writes one WAL record (no table, no
    # xid, no effect on any data) so that the switch really closes the segment.
    try:
        psql(namespace, primary, "SELECT pg_logical_emit_message(false, '%s', 'wal-ready')" % WAL_MARKER)
    except RuntimeError as exc:
        return "FAIL %s cannot write the WAL marker (%s)" % (label, exc), False
    try:
        switched = psql(namespace, primary, "SELECT pg_walfile_name(pg_switch_wal())")
    except RuntimeError as exc:
        return "FAIL %s cannot switch WAL (%s)" % (label, exc), False
    needed = end_wal if covers(end_wal, switched) else switched
    if not covers(needed, end_wal):
        needed = end_wal
    for _ in range(attempts):
        time.sleep(interval)
        try:
            archived = psql(namespace, primary, "SELECT COALESCE(last_archived_wal, '') FROM pg_stat_archiver")
        except RuntimeError as exc:
            return "FAIL %s cannot read archiver (%s)" % (label, exc), False
        if covers(archived, needed) and covers(archived, end_wal):
            return "OK   %s endWal=%s archived=%s" % (label, end_wal, archived), True
    return "FAIL %s endWal=%s archived=%s" % (label, end_wal, archived or "-"), False


def run(only, attempts, interval):
    try:
        clusters, backups = load_world()
    except RuntimeError as exc:
        print("FAIL kubectl (%s)" % exc, file=sys.stderr)
        return 1
    chosen = []
    for cluster in clusters:
        meta = cluster.get("metadata") or {}
        label = "%s/%s" % (meta.get("namespace") or "?", meta.get("name") or "?")
        if only and label not in only:
            continue
        chosen.append(cluster)
    if only:
        found = {
            "%s/%s" % ((c.get("metadata") or {}).get("namespace"), (c.get("metadata") or {}).get("name"))
            for c in chosen
        }
        missing = [label for label in only if label not in found]
        if missing:
            print("FAIL missing cluster %s" % ", ".join(missing))
            return 1
    if not chosen:
        print("OK   no CNPG clusters")
        return 0
    failed = False
    for cluster in chosen:
        line, ok = one_cluster(cluster, backups, attempts, interval)
        print(line)
        if not ok:
            failed = True
    return 1 if failed else 0


def self_test():
    assert covers("000000010000000000000008", "000000010000000000000005")
    assert not covers("000000010000000000000005", "000000010000000000000008")
    assert covers("000000010000000000000005", "000000010000000000000005")
    assert covers("000000020000000000000001", "0000000100000000000000FF")
    assert not covers("", "000000010000000000000001")
    assert not covers("000000010000000000000001", "short")
    assert not covers("000000010000000000000001", "00000001000000000000000g")
    items = [
        {"metadata": {"namespace": "matrix", "name": "old"},
         "spec": {"cluster": {"name": "matrix-db"}},
         "status": {"phase": "completed", "stoppedAt": "2026-11-01T13:00:00Z",
                    "endWal": "000000010000000000000003"}},
        {"metadata": {"namespace": "matrix", "name": "new"},
         "spec": {"cluster": {"name": "matrix-db"}},
         "status": {"phase": "completed", "stoppedAt": "2026-11-01T14:00:00Z",
                    "endWal": "000000010000000000000005"}},
        {"metadata": {"namespace": "matrix", "name": "bad"},
         "spec": {"cluster": {"name": "matrix-db"}},
         "status": {"phase": "failed", "stoppedAt": "2026-11-01T15:00:00Z",
                    "endWal": "000000010000000000000009"}},
        {"metadata": {"namespace": "gitea", "name": "other"},
         "spec": {"cluster": {"name": "gitea-db"}},
         "status": {"phase": "completed", "stoppedAt": "2026-11-01T16:00:00Z",
                    "endWal": "000000010000000000000001"}},
    ]
    picked = select_backup(items, "matrix", "matrix-db")
    assert picked["metadata"]["name"] == "new", picked
    assert select_backup(items, "db-lab", "pg-lab") is None
    print("OK   self-test")
    return 0


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n", 1)[0])
    parser.add_argument("--cluster", action="append", default=[], metavar="NS/NAME",
                        help="limit to this cluster (repeatable). Default: every cluster")
    parser.add_argument("--attempts", type=int, default=36, help="polls after the WAL switch (default 36)")
    parser.add_argument("--interval", type=float, default=5, help="seconds between polls (default 5)")
    parser.add_argument("--self-test", action="store_true", help="check the comparison and exit")
    args = parser.parse_args(argv)
    if args.self_test:
        return self_test()
    if args.attempts < 1:
        print("FAIL --attempts must be at least 1", file=sys.stderr)
        return 2
    return run(args.cluster, args.attempts, args.interval)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
