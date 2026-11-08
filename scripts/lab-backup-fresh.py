#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
"""Fresh CNPG and K8up backups before rebuild --restore destroys a running VM.

A missing or stale backup is a failure, not a reason to skip the check.
--force-all creates one base backup per database and one file backup per
volume, then waits until each one is new enough. There is no flag to skip
the check. lab.sh calls this only while the VM is running. down and export
do not: they only refuse to stop when a cluster has no completed backup
(scripts/lab-wal-ready.py).

--guard runs before --force-all in rebuild --restore: it refuses (exit 1) when
the running VM looks half restored, because a "fresh backup" of an empty VM
would become the newest backup and bury the good ones. It checks the marker
file of an unfinished rebuild --restore (--marker), the four database
clusters, auto-sync of root, gitea and matrix, and that the Gitea and Matrix
volumes really hold data (same test as the restore uses to accept a restored
volume). LAB_RESTORE_GUARD_FORCE=1 skips the live checks, never the marker.

--prefix names the Backup objects (default pre-restore). lab.sh uses
post-restore after rebuild --restore: the new cluster has no Backup objects,
so CNPG reports "no completed backup" until a new one exists.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timedelta, timezone

# The four databases. Tests compare these names with the Git manifests.
# keycloak-db has no PVC, so it appears here and not in FILE_VOLUMES.
CLUSTERS = (
    ("db-lab", "pg-lab"),
    ("gitea", "gitea-db"),
    ("matrix", "matrix-db"),
    ("keycloak", "keycloak-db"),
)
# File volumes. The claim names are copied from Git; backup-fresh-tests.sh
# fails when the chart or the PVC manifest drifts away from this tuple.
FILE_VOLUMES = (
    ("gitea", "gitea-shared-storage"),
    ("matrix", "matrix-data"),
)
# Where the guard looks for data: namespace, claim, Deployment and the shell test
# that must succeed inside the running pod (volume mounted at /data). The test
# is the content_test of ansible/tasks/recover-load.yml; tests compare both.
GUARD_VOLUMES = (
    ("gitea", "gitea-shared-storage", "gitea",
     "test -d /data/git/gitea-repositories && find /data/git/gitea-repositories -mindepth 1 -print -quit | grep -q ."),
    ("matrix", "matrix-data", "synapse", "test -s /data/signing.key"),
)
# Argo CD applications whose auto-sync the file restore turns off (recover-files.yml --tags pause).
GUARD_APPS = ("root", "gitea", "matrix")
WAL_LEN = 24
PREFIX_RE = re.compile(r"^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$")
HEX = set("0123456789ABCDEFabcdef")
SNAPSHOT_SLACK = timedelta(seconds=120)


def parse_time(text):
    """RFC3339 to an aware UTC datetime, or None."""
    if not isinstance(text, str) or not text.strip():
        return None
    raw = text.strip()
    if raw.endswith("Z"):
        raw = raw[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(raw)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return None
    return parsed.astimezone(timezone.utc)


def hours_old(stamp, now):
    parsed = parse_time(stamp)
    if parsed is None:
        return None
    return (now - parsed).total_seconds() / 3600.0


def is_fresh(stamp, now, max_h):
    age = hours_old(stamp, now)
    return age is not None and age <= max_h


def age_text(stamp, now):
    age = hours_old(stamp, now)
    if age is None:
        return "unreadable time"
    if age < 0:
        return "0h old"
    return "%dh old" % int(round(age))


def wal_name(text):
    if not isinstance(text, str) or len(text) != WAL_LEN:
        return False
    return all(char in HEX for char in text)


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


def kubectl_apply(doc):
    result = subprocess.run(
        ["kubectl", "apply", "-f", "-"],
        input=json.dumps(doc),
        check=False,
        capture_output=True,
        text=True,
        timeout=60,
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "kubectl apply failed").strip().splitlines()
        raise RuntimeError(detail[-1][:200] if detail else "kubectl apply failed")


def items_of(doc):
    if isinstance(doc, dict):
        found = doc.get("items")
        if isinstance(found, list):
            return found
    return []


def newest_completed(backups, namespace, cluster):
    """Latest completed Backup for one cluster, or None.

    stoppedAt is RFC3339, so the greatest string is the newest. The same
    rule is in scripts/lab-wal-ready.py.
    """
    best = None
    best_time = ""
    for item in backups:
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


def one_scheduled(scheduled, namespace, cluster):
    found = []
    for item in scheduled:
        meta = item.get("metadata") or {}
        spec = item.get("spec") or {}
        target = (spec.get("cluster") or {}).get("name")
        if meta.get("namespace") == namespace and target == cluster:
            found.append(item)
    return found


def one_schedule(schedules, namespace):
    return [
        item for item in schedules
        if (item.get("metadata") or {}).get("namespace") == namespace
    ]


def newest_snapshot(snapshots, namespace, claim):
    """Newest Snapshot whose paths list contains /data/<claim>, or None."""
    path = "/data/" + claim
    best = None
    best_dt = None
    for item in snapshots:
        meta = item.get("metadata") or {}
        if meta.get("namespace") != namespace:
            continue
        spec = item.get("spec") or {}
        paths = spec.get("paths") or []
        if not isinstance(paths, list) or path not in paths:
            continue
        when = parse_time(spec.get("date") or "")
        if when is None:
            continue
        if best_dt is None or when >= best_dt:
            best = item
            best_dt = when
    return best


def snapshot_after(snapshots, namespace, claim, started):
    path = "/data/" + claim
    best = None
    best_dt = None
    for item in snapshots:
        meta = item.get("metadata") or {}
        if meta.get("namespace") != namespace:
            continue
        spec = item.get("spec") or {}
        paths = spec.get("paths") or []
        if not isinstance(paths, list) or path not in paths:
            continue
        when = parse_time(spec.get("date") or "")
        if when is None or when < started - SNAPSHOT_SLACK:
            continue
        if best_dt is None or when >= best_dt:
            best = item
            best_dt = when
    return best


def kubectl_exec_ok(namespace, deploy, script):
    """True when `sh -c script` succeeds in a pod of the Deployment, False when it fails, None when kubectl cannot run it."""
    try:
        result = subprocess.run(
            ["kubectl", "exec", "-n", namespace, "deploy/" + deploy, "--", "sh", "-c", script],
            check=False, capture_output=True, text=True, timeout=60,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if result.returncode == 0:
        return True
    # kubectl itself failed (no pod, no shell): the test did not run. A failed test exits 1 without kubectl noise.
    err = (result.stderr or "").lower()
    if result.returncode == 1 and not any(w in err for w in ("error from server", "unable to", "executable file", "not found", "cannot exec")):
        return False
    return None


def read_marker(path):
    """The marker of an unfinished rebuild --restore as a dict, or None when there is none."""
    if not path or not os.path.exists(path):
        return None
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def guard(marker_path, live=True):
    """Refuse to back up a running VM that is (or may be) half restored. Returns 0 when it is fine."""
    problems = []
    marker = read_marker(marker_path)
    if marker is not None:
        when = marker.get("started") or "unknown time"
        problems.append(
            "an earlier rebuild --restore did not finish (marker %s, started %s, log %s)"
            % (marker_path, when, marker.get("log") or "unknown")
        )
    if live:
        try:
            present = {
                "%s/%s" % ((i.get("metadata") or {}).get("namespace"), (i.get("metadata") or {}).get("name"))
                for i in items_of(kubectl_json(["get", "clusters.postgresql.cnpg.io", "-A"]))
            }
            apps = items_of(kubectl_json(["get", "applications.argoproj.io", "-n", "argocd"]))
        except RuntimeError as exc:
            print("FAIL guard: kubectl cannot read the cluster (%s)" % exc)
            return 1
        for namespace, cluster in CLUSTERS:
            if "%s/%s" % (namespace, cluster) not in present:
                problems.append("database cluster %s/%s is missing" % (namespace, cluster))
        by_name = {(a.get("metadata") or {}).get("name"): a for a in apps}
        for name in GUARD_APPS:
            app = by_name.get(name)
            if app is None:
                problems.append("Argo CD application %s does not exist" % name)
            elif "automated" not in ((app.get("spec") or {}).get("syncPolicy") or {}):
                problems.append("auto-sync of the Argo CD application %s is off (the file restore pause was not resumed)" % name)
        for namespace, claim, deploy, script in GUARD_VOLUMES:
            label = "%s/%s" % (namespace, claim)
            try:
                dep = kubectl_json(["get", "deployment", "-n", namespace, deploy])
            except RuntimeError:
                problems.append("%s: Deployment %s does not exist" % (label, deploy))
                continue
            ready = ((dep.get("status") or {}).get("readyReplicas")) or 0
            if ready < 1:
                problems.append("%s: Deployment %s has no ready pod (scaled to zero or not started)" % (label, deploy))
                continue
            found = kubectl_exec_ok(namespace, deploy, script)
            if found is None:
                problems.append("%s: could not look into the volume (kubectl exec failed)" % label)
            elif not found:
                problems.append("%s: the volume holds no data" % label)
    if not problems:
        print("OK   guard: the running VM looks complete")
        return 0
    print("REFUSE: the running VM looks half restored. No fresh backups were taken, the VM was not touched.")
    for line in problems:
        print("  - %s" % line)
    print("A backup now could snapshot EMPTY volumes and make them the newest backup (K8up keeps the newest snapshot of a day).")
    print("Your options:")
    print("  1. Finish the restore by hand (docs/how-to/rebuild.md, 'rebuild --restore stopped halfway'):")
    print("       cd ansible && ansible-playbook recover-files.yml --tags pause,restore,resume,verify")
    if marker is not None:
        print("     The verify step removes the marker %s." % marker_path)
    print("  2. Start over from the backups that exist (this VM is destroyed, NO new backup is taken):")
    print("       LAB_RESTORE_START_OVER=1 bash scripts/lab.sh rebuild --restore")
    if marker is None:
        print("  3. False alarm and the data is complete: LAB_RESTORE_GUARD_FORCE=1 bash scripts/lab.sh rebuild --restore")
    else:
        print("  3. Data is complete and the marker is stale: rm %s, then run rebuild --restore again." % marker_path)
    return 1


def load_world(need_backups):
    clusters = items_of(kubectl_json(["get", "clusters.postgresql.cnpg.io", "-A"]))
    scheduled = items_of(kubectl_json(["get", "scheduledbackups.postgresql.cnpg.io", "-A"]))
    schedules = items_of(kubectl_json(["get", "schedules.k8up.io", "-A"]))
    snapshots = items_of(kubectl_json(["get", "snapshots.k8up.io", "-A"]))
    backups = []
    if need_backups:
        backups = items_of(kubectl_json(["get", "backups.postgresql.cnpg.io", "-A"]))
    present = {
        "%s/%s" % ((item.get("metadata") or {}).get("namespace"), (item.get("metadata") or {}).get("name"))
        for item in clusters
    }
    return present, scheduled, schedules, snapshots, backups


def require_sources(present, scheduled, schedules):
    """Clusters and their backup schedules must exist. Returns 1 on a gap."""
    failed = False
    for namespace, cluster in CLUSTERS:
        label = "%s/%s" % (namespace, cluster)
        if label not in present:
            print("FAIL missing cluster %s" % label)
            failed = True
            continue
        found = one_scheduled(scheduled, namespace, cluster)
        if len(found) != 1:
            print("FAIL %s needs exactly one ScheduledBackup (found %d)" % (label, len(found)))
            failed = True
            continue
        spec = found[0].get("spec") or {}
        if not spec.get("method") or not spec.get("pluginConfiguration"):
            print("FAIL %s ScheduledBackup has no plugin method" % label)
            failed = True
    for namespace, _claim in FILE_VOLUMES:
        found = one_schedule(schedules, namespace)
        if len(found) != 1:
            print("FAIL missing schedule %s (found %d)" % (namespace, len(found)))
            failed = True
            continue
        spec = found[0].get("spec") or {}
        if not spec.get("backend") or not spec.get("podConfigRef"):
            print("FAIL %s schedule has no backend" % namespace)
            failed = True
    return 1 if failed else 0


def check_age(now, max_h, backups, snapshots):
    failed = False
    for namespace, cluster in CLUSTERS:
        label = "%s/%s" % (namespace, cluster)
        backup = newest_completed(backups, namespace, cluster)
        if backup is None:
            print("FAIL %s no completed backup" % label)
            failed = True
            continue
        stopped = (backup.get("status") or {}).get("stoppedAt") or ""
        if not is_fresh(stopped, now, max_h):
            print("FAIL %s backup is %s (allowed %dh)" % (label, age_text(stopped, now), max_h))
            failed = True
            continue
        print("OK   %s backup %s" % (label, age_text(stopped, now)))
    for namespace, claim in FILE_VOLUMES:
        label = "%s/%s" % (namespace, claim)
        snap = newest_snapshot(snapshots, namespace, claim)
        if snap is None:
            print("FAIL %s no snapshot" % label)
            failed = True
            continue
        when = (snap.get("spec") or {}).get("date") or ""
        if not is_fresh(when, now, max_h):
            print("FAIL %s snapshot is %s (allowed %dh)" % (label, age_text(when, now), max_h))
            failed = True
            continue
        print("OK   %s snapshot %s" % (label, age_text(when, now)))
    return 1 if failed else 0


def poll_until(args, accept, reject, attempts, interval):
    last = {}
    for attempt in range(attempts):
        if attempt:
            time.sleep(interval)
        last = kubectl_json(args)
        if accept(last):
            return last
        reason = reject(last)
        if reason:
            raise RuntimeError(reason)
    phase = ((last.get("status") or {}).get("phase")) or "-"
    raise RuntimeError("timed out (phase %s)" % phase)


def cnpg_failed(obj):
    status = obj.get("status") or {}
    if status.get("phase") == "failed":
        return str(status.get("error") or "failed")[:200]
    return ""


def k8up_done(obj):
    for cond in (obj.get("status") or {}).get("conditions") or []:
        if cond.get("type") == "Completed" and cond.get("reason") == "Succeeded" and cond.get("status") == "True":
            return True
    return False


def k8up_failed(obj):
    for cond in (obj.get("status") or {}).get("conditions") or []:
        if cond.get("type") == "Completed" and cond.get("reason") == "Failed":
            return str(cond.get("message") or "failed")[:200]
    return ""


def force_all(now, max_h, scheduled, schedules, attempts, interval, prefix="pre-restore"):
    stamp = now.strftime("%Y%m%d%H%M%S")
    for namespace, cluster in CLUSTERS:
        label = "%s/%s" % (namespace, cluster)
        spec = one_scheduled(scheduled, namespace, cluster)[0].get("spec") or {}
        name = "%s-%s-%s" % (prefix, cluster, stamp)
        try:
            kubectl_apply({
                "apiVersion": "postgresql.cnpg.io/v1",
                "kind": "Backup",
                "metadata": {
                    "name": name,
                    "namespace": namespace,
                    "labels": {"app.kubernetes.io/managed-by": "lab-backup-fresh"},
                },
                "spec": {
                    "cluster": {"name": cluster},
                    "method": spec.get("method"),
                    "pluginConfiguration": spec.get("pluginConfiguration"),
                },
            })
            obj = poll_until(
                ["get", "backups.postgresql.cnpg.io", "-n", namespace, name],
                lambda item: (item.get("status") or {}).get("phase") == "completed",
                cnpg_failed,
                attempts,
                interval,
            )
        except RuntimeError as exc:
            print("FAIL %s backup %s (%s)" % (label, name, exc))
            return 1
        end_wal = (obj.get("status") or {}).get("endWal") or ""
        stopped = (obj.get("status") or {}).get("stoppedAt") or ""
        if not wal_name(end_wal):
            print("FAIL %s backup %s has no endWal" % (label, name))
            return 1
        if not is_fresh(stopped, now, max_h):
            print("FAIL %s backup %s is %s (allowed %dh)" % (label, name, age_text(stopped, now), max_h))
            return 1
        print("OK   %s backup %s" % (label, name))
    for namespace, claim in FILE_VOLUMES:
        label = "%s/%s" % (namespace, claim)
        spec = one_schedule(schedules, namespace)[0].get("spec") or {}
        name = "%s-%s-%s" % (prefix, claim, stamp)
        started = now
        try:
            kubectl_apply({
                "apiVersion": "k8up.io/v1",
                "kind": "Backup",
                "metadata": {
                    "name": name,
                    "namespace": namespace,
                    "labels": {"app.kubernetes.io/managed-by": "lab-backup-fresh"},
                },
                "spec": {
                    "podConfigRef": spec.get("podConfigRef"),
                    "backend": spec.get("backend"),
                    "successfulJobsHistoryLimit": 1,
                    "failedJobsHistoryLimit": 1,
                },
            })
            poll_until(
                ["get", "backups.k8up.io", "-n", namespace, name],
                k8up_done,
                k8up_failed,
                attempts,
                interval,
            )
        except RuntimeError as exc:
            print("FAIL %s backup %s (%s)" % (label, name, exc))
            return 1
        snap = None
        for attempt in range(attempts):
            if attempt:
                time.sleep(interval)
            try:
                shots = items_of(kubectl_json(["get", "snapshots.k8up.io", "-A"]))
            except RuntimeError as exc:
                print("FAIL %s snapshots (%s)" % (label, exc))
                return 1
            snap = snapshot_after(shots, namespace, claim, started)
            if snap is not None:
                break
        if snap is None:
            print("FAIL %s no snapshot from backup %s" % (label, name))
            return 1
        print("OK   %s snapshot %s" % (label, (snap.get("metadata") or {}).get("name") or "-"))
    return 0


def run(mode, max_h, attempts, interval, now_text, prefix="pre-restore"):
    now = parse_time(now_text) if now_text else datetime.now(timezone.utc)
    if now is None:
        print("FAIL --now is not RFC3339", file=sys.stderr)
        return 2
    if max_h <= 0:
        print("FAIL --max-age-h must be at least 1", file=sys.stderr)
        return 2
    try:
        present, scheduled, schedules, snapshots, backups = load_world(mode == "check")
    except RuntimeError as exc:
        print("FAIL kubectl (%s)" % exc, file=sys.stderr)
        return 1
    if require_sources(present, scheduled, schedules) != 0:
        return 1
    if mode == "check":
        return check_age(now, max_h, backups, snapshots)
    return force_all(now, max_h, scheduled, schedules, attempts, interval, prefix)


def self_test():
    now = parse_time("2026-11-01T12:00:00Z")
    assert is_fresh("2026-11-01T10:00:00Z", now, 30)
    assert not is_fresh("2026-10-30T12:00:00Z", now, 30)
    assert not is_fresh("", now, 30)
    assert not is_fresh("nope", now, 30)
    assert is_fresh("2099-01-01T00:00:00Z", now, 30)
    assert age_text("2026-10-30T12:00:00Z", now) == "48h old"
    items = [
        {"metadata": {"namespace": "gitea", "name": "old"},
         "spec": {"date": "2026-11-01T08:00:00Z", "paths": ["/data/gitea-shared-storage"]}},
        {"metadata": {"namespace": "gitea", "name": "other"},
         "spec": {"date": "2026-11-01T11:00:00Z", "paths": ["/data/other"]}},
        {"metadata": {"namespace": "matrix", "name": "m"},
         "spec": {"date": "2026-11-01T11:30:00Z", "paths": ["/data/matrix-data"]}},
    ]
    got = newest_snapshot(items, "gitea", "gitea-shared-storage")
    assert got["metadata"]["name"] == "old", got
    assert newest_snapshot(items, "gitea", "no-such-claim") is None
    bad = [{"metadata": {"namespace": "gitea", "name": "x"},
            "spec": {"date": "2026-11-01T11:00:00Z", "paths": "/data/gitea-shared-storage"}}]
    assert newest_snapshot(bad, "gitea", "gitea-shared-storage") is None
    after = snapshot_after(items, "gitea", "gitea-shared-storage", now)
    assert after is None
    later = [{"metadata": {"namespace": "gitea", "name": "new"},
              "spec": {"date": "2026-11-01T12:00:00Z", "paths": ["/data/gitea-shared-storage"]}}]
    assert snapshot_after(later, "gitea", "gitea-shared-storage", now)["metadata"]["name"] == "new"
    assert not wal_name("")
    assert not wal_name("00000001000000000000000g")
    assert wal_name("000000010000000000000005")
    print("OK   self-test")
    return 0


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n", 1)[0])
    parser.add_argument("--check", action="store_true", help="fail when a backup or snapshot is missing or older than --max-age-h")
    parser.add_argument("--guard", action="store_true", help="refuse when the running VM looks half restored (before --force-all)")
    parser.add_argument("--marker", default="", help="marker file of an unfinished rebuild --restore (with --guard)")
    parser.add_argument("--force-all", action="store_true", help="create a new backup for every database and file volume, then wait")
    parser.add_argument("--max-age-h", type=float, default=0, help="maximum age in hours")
    parser.add_argument("--attempts", type=int, default=90, help="polls per object (default 90)")
    parser.add_argument("--interval", type=float, default=10, help="seconds between polls (default 10)")
    parser.add_argument("--prefix", default="pre-restore", help="name prefix of the created Backup objects (default pre-restore)")
    parser.add_argument("--now", default="", help="RFC3339 clock for tests")
    parser.add_argument("--self-test", action="store_true", help="check the age and path rules and exit")
    args = parser.parse_args(argv)
    if args.self_test:
        return self_test()
    if args.guard:
        if args.check or args.force_all:
            print("FAIL --guard runs alone", file=sys.stderr)
            return 2
        return guard(args.marker, live=os.environ.get("LAB_RESTORE_GUARD_FORCE", "") != "1")
    if args.check == args.force_all:
        print("FAIL pass exactly one of --check, --force-all or --guard", file=sys.stderr)
        return 2
    if not PREFIX_RE.match(args.prefix):
        print("FAIL --prefix must be a short DNS-style name (a-z, 0-9, -)", file=sys.stderr)
        return 2
    if args.attempts < 1:
        print("FAIL --attempts must be at least 1", file=sys.stderr)
        return 2
    mode = "check" if args.check else "force"
    return run(mode, args.max_age_h, args.attempts, args.interval, args.now, args.prefix)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
