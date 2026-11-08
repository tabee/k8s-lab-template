#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
"""Memory budget of the lab VM (issue #9): check the limits, measure peaks, adopt measured limits.

Subcommands
  check   Pod and node JSON on stdin. Sums the memory limits of all work pods (every namespace except
          kube-system), compares the sum plus the reserve with the VM memory, fails when a container has no
          limit, the sum breaks the budget or a node reports memory pressure. With periodic_stagger_enforce,
          --repo validates the bounded calendar and actual job overlap is an error. Active pod sums are never
          discounted to max(single job). Used by ansible/verify-budget.yml.
  sample  Loops `kubectl top` and records the peak memory of every container (and the node) into a JSON file.
          Run it while the acceptance checks and one backup/restore run. Stop with --duration or --stop-file.
  report  Compares the peaks with the limits found in the repo (marker comments) and prints a proposal.
  apply   Writes the proposed limits into the marker lines (idempotent). Never raises a limit; only the
          reserve in lab.yaml may rise. Also refreshes the measured table in docs/reference/memory-budget.md.

Marker comment on every adoptable limit line:   memory: 256Mi   # lab-limit: <namespace>/<workload>/<container> [more]
  Every part may be a glob (*). <workload> is the pod name without the ReplicaSet hash or the -N suffix.

Adopt rule (apply):  new = min(current, max(64Mi, ceil32(peak * 1.5))).
  - never raises a limit, never lowers it when the peak is over 70 % of the current limit,
  - a limit below peak * 1.2 is flagged (FLAG): raising it is a human decision.
Exit codes: 0 = ok, 1 = a check failed, 2 = usage or input error.
"""
import argparse
import fnmatch
import json
import math
import os
import re
import subprocess
import sys
import time
from pathlib import Path

EXCLUDED_NAMESPACES = ("kube-system",)  # counted by the reserve, not by the sum of limits
FLOOR_MIB = 64
STEP_MIB = 32
HEADROOM_FACTOR = 1.5
KEEP_ABOVE_RATIO = 0.7
FLAG_BELOW_FACTOR = 1.2
RESERVE_STEP_MIB = 64
RESERVE_COMMENT = "measured peaks, see docs/reference/memory-budget.md"
DOC_BEGIN = "<!-- memory-budget:begin -->"
DOC_END = "<!-- memory-budget:end -->"
MARKER_RE = re.compile(r"^(?P<head>.*?\bmemory:\s*)(?P<val>\d+(?:Mi|Gi))(?P<tail>[^#]*?)(?P<comment>#\s*lab-limit:\s*(?P<spec>\S.*?))\s*$")
RESERVE_RE = re.compile(r"^(?P<key>memory_reserve_mib:\s*)(?P<val>\d+)(?P<rest>.*)$")
UNITS = {"Ki": 1 / 1024, "Mi": 1, "Gi": 1024, "Ti": 1024 * 1024, "K": 1000 / 1048576, "M": 1000000 / 1048576,
         "G": 1000000000 / 1048576, "": 1 / 1048576}


def parse_mib(text):
    """'256Mi' -> 256.0, '1Gi' -> 1024.0, '123456' (bytes) -> MiB. Raises ValueError for anything else."""
    m = re.fullmatch(r"(\d+(?:\.\d+)?)(Ki|Mi|Gi|Ti|K|M|G)?", str(text).strip())
    if not m:
        raise ValueError("not a memory quantity: %r" % (text,))
    return float(m.group(1)) * UNITS[m.group(2) or ""]


def fmt_mib(value):
    value = int(round(value))
    return "%dGi" % (value // 1024) if value >= 1024 and value % 1024 == 0 else "%dMi" % value


def ceil_to(value, step):
    return int(math.ceil(value / step) * step)


def normalize_pod(name):
    """Pod name without the ReplicaSet hash (-<hash>-<5 chars>), the Job hash or the StatefulSet index (-N)."""
    for pattern in (r"-[0-9a-z]{6,10}-[0-9a-z]{5}$", r"-\d+$", r"-[0-9a-z]{5}$"):
        stripped = re.sub(pattern, "", name)
        if stripped != name:
            return stripped
    return name


def fail(text, code=2):
    print("ERROR: " + text, file=sys.stderr)
    sys.exit(code)


# ------------------------------------------------------------------ bounded periodic projection
WEEK_SECONDS = 7 * 86400
PERIODIC_DELAY_SECONDS = 300  # includes the 30-second termination grace; validate this allowance live


def weekly_starts(cron):
    """Fixed UTC minutes/hours, every day or one weekday; reject random/interval schedules."""
    fields = str(cron).split()
    if len(fields) != 5 or fields[2:4] != ["*", "*"]:
        raise ValueError("expected fixed five-field daily/weekly cron")
    minute, hour = int(fields[0]), int(fields[1])
    if not 0 <= minute < 60 or not 0 <= hour < 24:
        raise ValueError("invalid cron time")
    days = range(7) if fields[4] == "*" else [int(fields[4])]
    if any(not 0 <= day <= 6 for day in days):
        raise ValueError("invalid cron weekday")
    return [day * 86400 + hour * 3600 + minute * 60 for day in days]


def duration_seconds(value):
    match = re.fullmatch(r"(?:(\d+)h)?(?:(\d+)m)?", str(value))
    if not match or not any(match.groups()):
        raise ValueError("expected a duration such as 6h30m")
    return int(match[1] or 0) * 3600 + int(match[2] or 0) * 60


def periodic_pod(pod):
    """Classify active K8up backup/prune/check/restore pods and the realm hook, not CNPG sidecars."""
    ns = pod.get("metadata", {}).get("namespace", "")
    name = pod.get("metadata", {}).get("name", "")
    if ns in ("gitea", "matrix") and name.startswith(("backup-", "prune-", "check-", "restore-", "archive-")):
        return True
    return ns == "keycloak" and any(c.get("name") == "config-cli" for c in pod.get("spec", {}).get("containers", []))


def stagger_problems(repo, live=None):
    """Validate the repository's bounded calendar, not a distributed mutual exclusion lock.

    Operators must keep manual jobs and in-flight syncs out of these slots. The
    live check below rejects actual overlap; it never replaces real pod sums by max().
    """
    import yaml
    repo = Path(repo)
    def load(rel):
        doc = yaml.safe_load((repo / rel).read_text(encoding="utf-8"))
        if live is not None and isinstance(doc, dict) and doc.get("kind") in ("Schedule", "PodConfig"):
            expected = doc["metadata"]
            found = [item for item in live if item.get("kind") == doc["kind"]
                     and item.get("metadata", {}).get("name") == expected["name"]
                     and item.get("metadata", {}).get("namespace") == expected["namespace"]]
            if len(found) != 1:
                raise ValueError("live %s %s/%s is missing or ambiguous" % (doc["kind"], expected["namespace"], expected["name"]))
            return found[0]
        return doc
    def walk(value):
        if isinstance(value, dict):
            yield value
            for item in value.values():
                yield from walk(item)
        elif isinstance(value, list):
            for item in value:
                yield from walk(item)
    problems, slots = [], []
    try:
        expected = {("gitea", "gitea-files"), ("matrix", "matrix-files")}
        for path in repo_files(repo, "gitops", "*.yaml"):
            text = path.read_text(encoding="utf-8")
            if re.search(r"^kind: (Schedule|CronJob)$", text, re.M):
                doc = yaml.safe_load(text)
                key = (doc["metadata"].get("namespace"), doc["metadata"]["name"])
                if doc["kind"] != "Schedule" or key not in expected:
                    problems.append("STAGGER unmodelled periodic manifest: " + str(path.relative_to(repo)))
        if live is not None:
            for item in live:
                if item.get("kind") == "Schedule":
                    key = (item["metadata"].get("namespace"), item["metadata"]["name"])
                    if key not in expected:
                        problems.append("STAGGER unmodelled live K8up schedule: %s/%s" % key)
        if load("gitops/platform/k8up/values.yaml")["k8up"]["timezone"] != "UTC":
            problems.append("STAGGER K8up timezone must be UTC")
        for ns in ("gitea", "matrix"):
            rel = "gitops/workloads/%s/manifests/" % ns
            spec = load(rel + "k8up-schedule.yaml")["spec"]
            pod = load(rel + "k8up-podconfig.yaml")["spec"]["template"]["spec"]
            grace = int(pod["terminationGracePeriodSeconds"])
            if len(pod.get("containers", [])) != 1:
                problems.append("STAGGER %s PodConfig must have exactly one budgeted container" % ns)
            if live is not None:
                expected_pod = yaml.safe_load((repo / (rel + "k8up-podconfig.yaml")).read_text(encoding="utf-8"))["spec"]["template"]["spec"]
                real_limit = sum(parse_mib(c["resources"]["limits"]["memory"]) for c in pod["containers"])
                expected_limit = sum(parse_mib(c["resources"]["limits"]["memory"]) for c in expected_pod["containers"])
                if real_limit > expected_limit:
                    problems.append("STAGGER %s live PodConfig exceeds the projected job limit" % ns)
            if not 0 <= grace < PERIODIC_DELAY_SECONDS:
                problems.append("STAGGER %s termination grace exceeds the delay allowance" % ns)
            if spec["podConfigRef"]["name"] != "k8up-restricted":
                problems.append("STAGGER %s must use the budgeted PodConfig" % ns)
            for action, cfg in spec.items():
                if not isinstance(cfg, dict) or "schedule" not in cfg:
                    continue
                if action not in ("backup", "prune", "check"):
                    problems.append("STAGGER unmodelled scheduled action %s/%s" % (ns, action))
                deadline = int(cfg["activeDeadlineSeconds"])
                if deadline <= 0 or cfg.get("concurrentRunsAllowed") is not False:
                    problems.append("STAGGER %s/%s needs a positive deadline and concurrentRunsAllowed=false" % (ns, action))
                for start in weekly_starts(cfg["schedule"]):
                    slots.append((start, start + deadline + PERIODIC_DELAY_SECONDS, ns + "/" + action))
        slots.sort()
        for first, second in zip(slots, slots[1:] + [(slots[0][0] + WEEK_SECONDS, 0, slots[0][2])]):
            if first[1] > second[0]:
                problems.append("STAGGER overlapping slots: %s and %s" % (first[2], second[2]))
        hook = load("gitops/workloads/keycloak/manifests/job-config.yaml")
        deadline = int(hook["spec"]["activeDeadlineSeconds"])
        if hook["spec"].get("parallelism", 1) != 1 or hook["spec"].get("completions", 1) != 1:
            problems.append("STAGGER realm hook must run one pod")
        if deadline <= 0 or hook["metadata"]["annotations"]["argocd.argoproj.io/hook"] != "PostSync":
            problems.append("STAGGER realm job needs a bounded PostSync hook")
        projects = load("ansible/roles/argocd_bootstrap/tasks/gitops.yml") if live is None else live
        windows = [window for obj in walk(projects) if obj.get("kind") == "AppProject"
                   for window in obj.get("spec", {}).get("syncWindows", [])
                   if window.get("kind") == "deny" and window.get("timeZone") == "UTC"
                   and window.get("manualSync") is False and window.get("syncOverrun") is False
                   and "keycloak" in window.get("applications", [])]
        fences = [(start + shift, start + shift + duration_seconds(w["duration"])) for w in windows
                  for start in weekly_starts(w["schedule"]) for shift in (-WEEK_SECONDS, 0, WEEK_SECONDS)]
        for start, end, label in slots:
            if not any(left <= start - deadline - PERIODIC_DELAY_SECONDS and end <= right for left, right in fences):
                problems.append("STAGGER Keycloak sync deny window does not fence %s (including hook lead-in)" % label)
        # CNPG plugin backups execute inside the already-budgeted native sidecars.
        for rel in ("db-lab/", "gitea/manifests/", "matrix/manifests/", "keycloak/manifests/"):
            spec = load("gitops/workloads/" + rel + "scheduledbackup.yaml")["spec"]
            if spec.get("method") != "plugin" or spec.get("pluginConfiguration", {}).get("name") != "barman-cloud.cloudnative-pg.io":
                problems.append("STAGGER CNPG backup no longer uses the counted Barman sidecar: " + rel)
    except (OSError, KeyError, TypeError, ValueError, IndexError, yaml.YAMLError) as err:
        problems.append("STAGGER incomplete or unsupported periodic policy: %s" % err)
    return sorted(set(problems))


def staggered_projection(pods, repo):
    """Project steady + largest single job ONLY for a valid bounded calendar.

    This helper is offline-only. Actual Running/Pending pods always all count.
    Invalid policy falls back to the conservative sum and returns errors.
    """
    problems = stagger_problems(repo)
    if problems:
        return pods, problems
    periodic = [pod for pod in pods if periodic_pod(pod)]
    def limit(pod):
        return sum(parse_mib(c["resources"]["limits"]["memory"]) for c in pod["spec"]["containers"])
    largest = [max(periodic, key=limit)] if periodic else []
    return [pod for pod in pods if not periodic_pod(pod)] + largest, []


# ------------------------------------------------------------------ check
def cmd_check(args):
    try:
        data = json.load(sys.stdin)
        total_mib = float(data["memory_mib"])
        reserve_mib = float(data["reserve_mib"])
        pods = data.get("pods", [])
        nodes = data.get("nodes", [])
    except (ValueError, KeyError, TypeError) as err:
        fail("stdin must be JSON with memory_mib, reserve_mib, pods, nodes (%s)" % err)
    disk_gb = data.get("disk_gb")
    excluded = tuple(data.get("excluded_namespaces", EXCLUDED_NAMESPACES))
    per_ns = {}
    problems = []
    active_periodic = [pod for pod in pods if pod.get("status", {}).get("phase") in ("Running", "Pending") and periodic_pod(pod)]
    if data.get("periodic_stagger_enforce", False):
        if not args.repo:
            problems.append("STAGGER --repo is required to validate the periodic calendar")
        else:
            problems.extend(stagger_problems(args.repo, data.get("periodic_resources")))
        if len(active_periodic) > 1:
            names = [p["metadata"]["namespace"] + "/" + p["metadata"]["name"] for p in active_periodic]
            problems.append("STAGGER active periodic pods overlap: " + ", ".join(names))
    elif len(active_periodic) > 1:
        print("WARNING stagger: %d active periodic pods (not enforcing this profile)" % len(active_periodic))
    for pod in pods:
        meta, status = pod.get("metadata", {}), pod.get("status", {})
        ns = meta.get("namespace", "?")
        if ns in excluded or status.get("phase") not in ("Running", "Pending"):
            continue
        spec = pod.get("spec", {})
        # A native sidecar (init container with restartPolicy Always, e.g. the Barman plugin of a CNPG pod) runs for
        # the whole life of the pod, so its limit counts. Plain init containers run before the others and do not.
        running = list(spec.get("containers", [])) + [c for c in spec.get("initContainers", []) if c.get("restartPolicy") == "Always"]
        for ctr in running:
            limit = ((ctr.get("resources") or {}).get("limits") or {}).get("memory")
            where = "%s/%s/%s" % (ns, meta.get("name", "?"), ctr.get("name", "?"))
            entry = per_ns.setdefault(ns, {"containers": 0, "mib": 0.0})
            entry["containers"] += 1
            if limit is None:
                problems.append("NOLIMIT %s has no memory limit (a LimitRange default does not count, set it in git)" % where)
                continue
            try:
                entry["mib"] += parse_mib(limit)
            except ValueError:
                problems.append("BADLIMIT %s has the memory limit %r" % (where, limit))
    total_limits = sum(e["mib"] for e in per_ns.values())
    available = total_mib - reserve_mib
    print("%-28s %10s %12s" % ("namespace", "containers", "limits MiB"))
    for ns in sorted(per_ns):
        print("%-28s %10d %12d" % (ns, per_ns[ns]["containers"], per_ns[ns]["mib"]))
    print("%-28s %10d %12d" % ("SUM of work pods", sum(e["containers"] for e in per_ns.values()), total_limits))
    print("VM memory (memory_mib)       %12d" % total_mib)
    print("reserve (memory_reserve_mib) %12d   kube-system, OS and kubelet, one backup/restore pod" % reserve_mib)
    print("budget for limits            %12d" % available)
    print("headroom                     %12d" % (available - total_limits))
    if disk_gb:
        print("VM disk: %s GB (disk_gb in lab.yaml; the disk threshold of issue #8 builds on this value)" % disk_gb)
    if total_limits > available:
        problems.append("OVERBUDGET the memory limits add up to %d MiB, the budget is %d MiB (memory_mib %d - reserve %d): "
                        "lower a limit from measured peaks (bash scripts/lab.sh budget) or enlarge the VM"
                        % (total_limits, available, total_mib, reserve_mib))
    for node in nodes:
        conds = {c.get("type"): c.get("status") for c in node.get("status", {}).get("conditions", [])}
        name = node.get("metadata", {}).get("name", "?")
        print("node %s: MemoryPressure=%s DiskPressure=%s" % (name, conds.get("MemoryPressure", "?"), conds.get("DiskPressure", "?")))
        if conds.get("MemoryPressure") != "False":
            problems.append("PRESSURE node %s reports MemoryPressure=%s" % (name, conds.get("MemoryPressure", "missing")))
    for line in problems:
        print(line)
    print("BUDGET %s: %d problem(s)" % ("RED" if problems else "OK", len(problems)))
    return 1 if problems else 0


# ------------------------------------------------------------------ sample
def kubectl(*argv):
    cmd = os.environ.get("KUBECTL", "kubectl").split() + list(argv)
    return subprocess.run(cmd, capture_output=True, text=True, timeout=60, check=False)


def load_peaks(path):
    if path.exists():
        return json.loads(path.read_text(encoding="utf-8"))
    return {"containers": {}, "node": {"used_mib_max": 0, "overhead_mib_max": 0, "kube_system_mib_max": 0, "pressure_seen": False},
            "samples": 0, "measured": ""}


def sample_once(peaks):
    top = kubectl("top", "pods", "-A", "--containers", "--no-headers")
    if top.returncode != 0:
        return False
    pods_total = 0.0
    kube_system = 0.0
    for line in top.stdout.splitlines():
        parts = line.split()
        if len(parts) < 5:
            continue
        ns, pod, ctr, _cpu, mem = parts[:5]
        try:
            mib = parse_mib(mem)
        except ValueError:
            continue
        pods_total += mib
        if ns == "kube-system":
            kube_system += mib
        key = "%s/%s/%s" % (ns, normalize_pod(pod), ctr)
        entry = peaks["containers"].setdefault(key, {"peak_mib": 0, "samples": 0})
        entry["peak_mib"] = max(entry["peak_mib"], mib)
        entry["samples"] += 1
    node = peaks["node"]
    node["kube_system_mib_max"] = max(node["kube_system_mib_max"], kube_system)
    nodes = kubectl("top", "nodes", "--no-headers")
    for line in nodes.stdout.splitlines() if nodes.returncode == 0 else []:
        parts = line.split()
        if len(parts) >= 4:
            try:
                used = parse_mib(parts[3])
            except ValueError:
                continue
            node["used_mib_max"] = max(node["used_mib_max"], used)
            node["overhead_mib_max"] = max(node["overhead_mib_max"], used - pods_total)
    cond = kubectl("get", "nodes", "-o", "json")
    try:
        items = json.loads(cond.stdout).get("items", []) if cond.returncode == 0 else []
    except ValueError:
        items = []  # a node condition that cannot be read is not a reason to lose the sample
    if items:
        for item in items:
            for c in item.get("status", {}).get("conditions", []):
                if c.get("type") == "MemoryPressure" and c.get("status") != "False":
                    node["pressure_seen"] = True
    peaks["samples"] += 1
    peaks["measured"] = time.strftime("%Y-%m-%d")
    return True


def cmd_sample(args):
    path = Path(args.out)
    peaks = load_peaks(path)
    stop = Path(args.stop_file) if args.stop_file else None
    deadline = time.monotonic() + args.duration
    failures = 0
    while time.monotonic() < deadline and not (stop and stop.exists()):
        if sample_once(peaks):
            failures = 0
            tmp = path.with_suffix(".tmp")
            tmp.write_text(json.dumps(peaks, indent=1, sort_keys=True), encoding="utf-8")
            os.replace(tmp, path)
        else:
            failures += 1
            if failures >= 10:
                print("ERROR: kubectl top failed 10 times in a row (metrics-server not ready?)", file=sys.stderr)
                return 1
        # Sleep in small steps so that --stop-file ends the loop quickly.
        wake = time.monotonic() + args.interval
        while time.monotonic() < wake and not (stop and stop.exists()):
            time.sleep(min(0.2, args.interval))
    print("sampled %d times, %d containers, peaks in %s" % (peaks["samples"], len(peaks["containers"]), path))
    return 0 if peaks["samples"] else 1


# ------------------------------------------------------------------ markers, report, apply
def repo_files(repo, sub, pattern="*"):
    """Sorted files below repo/sub that belong to the lab: what git tracks or would track (git ls-files,
    when repo is the git top level), otherwise a walk that skips every folder starting with a dot (export
    tree, test copies). Ignored folders such as ansible/.ansible/collections (installed third-party
    collections, present on every operator machine) are never scanned."""
    repo = Path(repo)
    try:
        top = subprocess.run(["git", "-C", str(repo), "rev-parse", "--show-toplevel"], capture_output=True, text=True, check=True).stdout.strip()
        if top and Path(top).resolve() == repo.resolve():
            out = subprocess.run(["git", "-C", str(repo), "ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", sub], capture_output=True, check=True).stdout
            names = [n for n in out.decode("utf-8").split("\0") if n]
            return sorted(p for p in (repo / n for n in names) if p.is_file() and fnmatch.fnmatch(p.name, pattern))
    except (OSError, subprocess.CalledProcessError):
        pass
    found = []
    for dirpath, dirs, files in os.walk(repo / sub):
        dirs[:] = sorted(d for d in dirs if not d.startswith("."))
        found += [Path(dirpath) / f for f in files if fnmatch.fnmatch(f, pattern)]
    return sorted(found)


def find_markers(repo):
    """Every marker line of the repo: (file, line index, current MiB, [(ns, workload, container) globs])."""
    found = []
    for sub in ("gitops", "ansible"):
        for path in repo_files(repo, sub):
            if path.suffix not in (".yaml", ".yml", ".j2", ".tpl"):
                continue
            for idx, line in enumerate(path.read_text(encoding="utf-8").split("\n")):
                m = MARKER_RE.match(line)
                if not m:
                    continue
                specs = []
                for word in m.group("spec").split():
                    parts = word.split("/")
                    if len(parts) != 3:
                        fail("%s:%d: marker %r is not <namespace>/<workload>/<container>" % (path, idx + 1, word))
                    specs.append(tuple(parts))
                found.append((path, idx, parse_mib(m.group("val")), specs))
    return found


def match_peak(specs, peaks):
    best = None
    for key, entry in peaks["containers"].items():
        ns, wl, ct = key.split("/")
        if any(fnmatch.fnmatchcase(ns, s[0]) and fnmatch.fnmatchcase(wl, s[1]) and fnmatch.fnmatchcase(ct, s[2]) for s in specs):
            best = max(best or 0, entry["peak_mib"])
    return best


def propose(limit, peak):
    """Return (status, new limit MiB). status: NOPEAK, KEEP, LOWER, FLAG."""
    if peak is None:
        return "NOPEAK", limit
    if limit < peak * FLAG_BELOW_FACTOR:
        return "FLAG", limit
    if peak > limit * KEEP_ABOVE_RATIO:
        return "KEEP", limit
    new = min(limit, max(FLOOR_MIB, ceil_to(peak * HEADROOM_FACTOR, STEP_MIB)))
    return ("LOWER", new) if new < limit else ("KEEP", limit)


def rows(repo, peaks):
    out = []
    for path, idx, limit, specs in find_markers(repo):
        peak = match_peak(specs, peaks)
        status, new = propose(limit, peak)
        out.append({"file": path, "idx": idx, "specs": specs, "limit": limit, "peak": peak, "status": status, "new": new})
    return out


def needed_reserve(repo, peaks, rows_):
    node = peaks["node"]
    base = node["kube_system_mib_max"] + max(0.0, node["overhead_mib_max"])
    jobs = [r["limit"] for r in rows_ if any(s[1].startswith(("backup", "restore")) for s in r["specs"])]
    job = max(jobs) if jobs else 0
    return ceil_to(base, RESERVE_STEP_MIB) + int(job), base, job


def current_reserve(repo):
    path = repo / "infra/envs/local/lab.yaml"
    for line in path.read_text(encoding="utf-8").split("\n"):
        m = RESERVE_RE.match(line)
        if m:
            return int(m.group("val"))
    fail("memory_reserve_mib is missing in %s" % path)


def cmd_report(args):
    repo = Path(args.repo)
    peaks = load_peaks(Path(args.peaks))
    rs = rows(repo, peaks)
    print("%-44s %8s %8s %6s  %-7s %s" % ("namespace/workload/container", "limit", "peak", "%", "status", "proposal"))
    for r in rs:
        label = " ".join("/".join(s) for s in r["specs"])
        pct = "%d" % (100 * r["peak"] / r["limit"]) if r["peak"] is not None else "-"
        peak = fmt_mib(r["peak"]) if r["peak"] is not None else "-"
        prop = "-> %s" % fmt_mib(r["new"]) if r["status"] == "LOWER" else ""
        print("%-44s %8s %8s %6s  %-7s %s" % (label[:44], fmt_mib(r["limit"]), peak, pct, r["status"], prop))
        if r["status"] == "FLAG":
            print("    FLAG: the limit is below peak x %.1f; raise it by hand if the workload really needs it" % FLAG_BELOW_FACTOR)
    marked = [s for r in rs for s in r["specs"]]
    for key in sorted(peaks["containers"]):
        ns, wl, ct = key.split("/")
        if ns == "kube-system":
            continue
        if not any(fnmatch.fnmatchcase(ns, s[0]) and fnmatch.fnmatchcase(wl, s[1]) and fnmatch.fnmatchcase(ct, s[2]) for s in marked):
            print("NOMARKER %s (peak %s): no marker line, its limit is not adopted automatically" % (key, fmt_mib(peaks["containers"][key]["peak_mib"])))
    need, base, job = needed_reserve(repo, peaks, rs)
    have = current_reserve(repo)
    print("reserve: kube-system + OS/kubelet measured %s, one backup/restore pod %s -> needed %s, lab.yaml has %s%s"
          % (fmt_mib(base), fmt_mib(job), fmt_mib(need), fmt_mib(have), "  (RAISE)" if need > have else ""))
    print("node memory pressure seen while sampling: %s" % ("YES" if peaks["node"]["pressure_seen"] else "no"))
    print("%d markers, %d to lower, %d flagged, %d without a peak" % (len(rs), sum(r["status"] == "LOWER" for r in rs),
                                                                    sum(r["status"] == "FLAG" for r in rs), sum(r["status"] == "NOPEAK" for r in rs)))
    return 0


def table_markdown(repo, peaks):
    rs = rows(repo, peaks)
    need, base, job = needed_reserve(repo, peaks, rs)
    # lang-allow-begin: the table goes into the German docs
    lines = ["Stand der Messung: %s (%d Messungen, `kubectl top`)." % (peaks["measured"] or "unbekannt", peaks["samples"]), "",
             "| Arbeitslast (Namespace/Pod/Container) | Limit | Spitze | Spitze in % |", "|---|---|---|---|"]
    for r in rs:
        label = " ".join("`%s`" % "/".join(s) for s in r["specs"])
        peak = fmt_mib(r["peak"]) if r["peak"] is not None else "nicht gemessen"
        pct = "%d" % (100 * r["peak"] / r["limit"]) if r["peak"] is not None else "-"
        lines.append("| %s | %s | %s | %s |" % (label, fmt_mib(r["limit"]), peak, pct))
    lines += ["", "Gemessen für die Reserve: kube-system und Betriebssystem zusammen %s, ein Backup-/Restore-Pod %s, ergibt %s."
              % (fmt_mib(base), fmt_mib(job), fmt_mib(need))]
    # lang-allow-end
    return "\n".join(lines)


def update_doc(repo, peaks):
    path = repo / "docs/reference/memory-budget.md"
    text = path.read_text(encoding="utf-8")
    if DOC_BEGIN not in text or DOC_END not in text:
        fail("%s lacks the markers %s ... %s" % (path, DOC_BEGIN, DOC_END))
    head, rest = text.split(DOC_BEGIN, 1)
    tail = rest.split(DOC_END, 1)[1]
    new = head + DOC_BEGIN + "\n" + table_markdown(repo, peaks) + "\n" + DOC_END + tail
    if new == text:
        return False
    path.write_text(new, encoding="utf-8")
    return True


def cmd_apply(args):
    repo = Path(args.repo)
    peaks = load_peaks(Path(args.peaks))
    if not peaks["containers"]:
        fail("no peaks in %s (run: sample)" % args.peaks)
    rs = rows(repo, peaks)
    by_file = {}
    changed = 0
    for r in rs:
        label = " ".join("/".join(s) for s in r["specs"])
        where = "%s:%d" % (r["file"].relative_to(repo), r["idx"] + 1)
        if r["status"] == "LOWER":
            by_file.setdefault(r["file"], []).append(r)
            print("EDIT  %s %s %s -> %s (peak %s)" % (where, label, fmt_mib(r["limit"]), fmt_mib(r["new"]), fmt_mib(r["peak"])))
            changed += 1
        else:
            print("SKIP  %s %s %s (%s)" % (where, label, fmt_mib(r["limit"]), r["status"]))
    if not args.dry_run:
        for path, items in by_file.items():
            lines = path.read_text(encoding="utf-8").split("\n")
            for r in items:
                m = MARKER_RE.match(lines[r["idx"]])
                lines[r["idx"]] = m.group("head") + fmt_mib(r["new"]) + m.group("tail") + m.group("comment")
            path.write_text("\n".join(lines), encoding="utf-8")
    need, _base, _job = needed_reserve(repo, peaks, rs)
    have = current_reserve(repo)
    lab_yaml = repo / "infra/envs/local/lab.yaml"
    if need > have:
        print("EDIT  infra/envs/local/lab.yaml memory_reserve_mib %d -> %d" % (have, need))
        changed += 1
        if not args.dry_run:
            lines = lab_yaml.read_text(encoding="utf-8").split("\n")
            for i, line in enumerate(lines):
                m = RESERVE_RE.match(line)
                if m:
                    lines[i] = "%s%d  # %s" % (m.group("key"), need, RESERVE_COMMENT)
            lab_yaml.write_text("\n".join(lines), encoding="utf-8")
    else:
        print("SKIP  infra/envs/local/lab.yaml memory_reserve_mib %d (needed %d)" % (have, need))
    if not args.dry_run and (repo / "docs/reference/memory-budget.md").exists():
        print("%s docs/reference/memory-budget.md (measured table)" % ("EDIT " if update_doc(repo, peaks) else "SKIP "))
    print("%d change(s)%s" % (changed, " (dry run, nothing written)" if args.dry_run else ""))
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    check = sub.add_parser("check", help="pod and node JSON on stdin; actual pods always all count")
    check.add_argument("--repo", help="validate the bounded calendar when periodic_stagger_enforce is true")
    check.set_defaults(fn=cmd_check)
    p = sub.add_parser("sample", help="record peaks from kubectl top")
    p.add_argument("--out", required=True)
    p.add_argument("--duration", type=float, default=600)
    p.add_argument("--interval", type=float, default=15)
    p.add_argument("--stop-file")
    p.set_defaults(fn=cmd_sample)
    for name, fn in (("report", cmd_report), ("apply", cmd_apply)):
        p = sub.add_parser(name)
        p.add_argument("--peaks", required=True)
        p.add_argument("--repo", default=str(Path(__file__).resolve().parent.parent))
        if name == "apply":
            p.add_argument("--dry-run", action="store_true")
        p.set_defaults(fn=fn)
    args = ap.parse_args()
    sys.exit(args.fn(args))


if __name__ == "__main__":
    main()
