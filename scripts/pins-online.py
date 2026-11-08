#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
"""Check the image pins of the lab against the registries (issue #10). Needs network for the online part.

Offline (always, also with --offline): reads every pinned image of the lab, checks the format
(tag + @sha256:<64 hex>) and the Traefik pair digest + versionOverride, prints the list.
Online (default): asks each registry
  - does the pinned digest still exist?                    (missing = ERROR)
  - does the tag still point to the pinned digest?         (moved = INFO: a re-pushed tag; the pin keeps
                                                            running the old image, bump on purpose)
  - does the Traefik chart's appVersion equal versionOverride?  (helm show chart; helm missing = SKIP)
The tests (tests/pins-tests.sh) never need the network. This script is the manual / CI-less proof.

Usage: python3 scripts/pins-online.py --check [--offline] [--repo DIR]
Exit code: 0 = no ERROR, 1 = at least one ERROR.
"""
import argparse
import fnmatch
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
from pathlib import Path

REF_RE = re.compile(r"^(?P<host>[a-z0-9.-]+\.[a-z]+(?::\d+)?)/(?P<repo>[a-z0-9._/-]+):(?P<tag>[A-Za-z0-9._-]+)@(?P<digest>sha256:[a-f0-9]{64})$")
ACCEPT = ", ".join([
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json",
])
errors = []


def error(text):
    errors.append(text)
    print("ERROR " + text)


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


def collect(repo):
    """Return a list of (name, ref) for every pinned image reference of the lab."""
    refs = []
    group_vars = repo / "ansible/inventory/group_vars/all"
    for path in sorted(group_vars.glob("*.yml")):
        for m in re.finditer(r"^(\w*image\w*):\s*(\S+@sha256:[a-f0-9]{64})\s*$", path.read_text(encoding="utf-8"), flags=re.M):
            refs.append(("%s:%s" % (path.name, m.group(1)), m.group(2)))
    for path in repo_files(repo, "gitops", "*.yaml"):
        text = path.read_text(encoding="utf-8")
        for m in re.finditer(r"^\s*(?:image:|builder:|web:|proxy:)\s*(\S+@sha256:[a-f0-9]{64})\s*$", text, flags=re.M):
            refs.append((str(path.relative_to(repo)), m.group(1)))
    return sorted(set(refs))


def traefik_pair(repo):
    """Return (digest, versionOverride, chart revision) of the Traefik pin, or raise ValueError."""
    values = (repo / "gitops/platform/traefik/values.yaml").read_text(encoding="utf-8")
    digest = re.search(r"^  digest: (sha256:[a-f0-9]{64})", values, flags=re.M)
    version = re.search(r"^versionOverride: (\S+)\s*$", values, flags=re.M)
    app = (repo / "gitops/apps/traefik.yaml").read_text(encoding="utf-8")
    chart = re.search(r"chart: traefik\n\s+targetRevision: (\S+)", app)
    if not (digest and version and chart):
        raise ValueError("Traefik digest, versionOverride or chart revision not found")
    if not re.fullmatch(r"v\d+\.\d+\.\d+", version.group(1)):
        raise ValueError("versionOverride %r is not of the form vX.Y.Z" % version.group(1))
    return digest.group(1), version.group(1), chart.group(1)


def registry_digest(host, repo, reference):
    """HEAD the manifest and return its Docker-Content-Digest (anonymous token if the registry asks for one)."""
    api_host = "registry-1.docker.io" if host == "docker.io" else host
    if host == "docker.io" and "/" not in repo:
        repo = "library/" + repo  # official image: docker.io/traefik is library/traefik
    url = "https://%s/v2/%s/manifests/%s" % (api_host, repo, reference)
    token = None
    for _ in range(2):
        req = urllib.request.Request(url, method="HEAD", headers={"Accept": ACCEPT})
        if token:
            req.add_header("Authorization", "Bearer " + token)
        try:
            with urllib.request.urlopen(req, timeout=20) as resp:
                return resp.headers.get("Docker-Content-Digest")
        except urllib.error.HTTPError as err:
            if err.code == 404:
                return None
            if err.code != 401 or token:
                raise
            challenge = err.headers.get("WWW-Authenticate", "")
            fields = dict(re.findall(r'(\w+)="([^"]*)"', challenge))
            if "realm" not in fields:
                raise
            query = "service=%s&scope=%s" % (fields.get("service", ""), fields.get("scope", "repository:%s:pull" % repo))
            with urllib.request.urlopen("%s?%s" % (fields["realm"], query), timeout=20) as tok:
                body = json.load(tok)
            token = body.get("token") or body.get("access_token")
    return None


def online_refs(refs):
    for name, ref in refs:
        m = REF_RE.match(ref)
        if not m:
            error("%s: %s is not host/repo:tag@sha256:<64 hex>" % (name, ref))
            continue
        try:
            by_digest = registry_digest(m["host"], m["repo"], m["digest"])
            by_tag = registry_digest(m["host"], m["repo"], m["tag"])
        except (urllib.error.URLError, OSError) as err:
            print("SKIP  %s: registry not reachable (%s)" % (name, err))
            continue
        if by_digest is None:
            error("%s: digest %s is gone from %s" % (name, m["digest"], m["host"]))
        elif by_tag is not None and by_tag != m["digest"]:
            print("INFO  %s: tag %s now points to %s (pin keeps %s; bump on purpose)" % (name, m["tag"], by_tag, m["digest"][:19]))
        else:
            print("OK    %s: %s exists, tag unchanged" % (name, m["digest"][:19]))


def online_chart(chart_rev, version):
    helm = shutil.which("helm")
    if not helm:
        print("SKIP  traefik chart appVersion: helm is not installed")
        return
    cmd = [helm, "show", "chart", "traefik", "--repo", "https://traefik.github.io/charts", "--version", chart_rev]
    try:
        # Private helm state: a stale repository list of the user must not break the check.
        with tempfile.TemporaryDirectory() as tmp:
            env = dict(os.environ, HELM_REPOSITORY_CONFIG=tmp + "/repositories.yaml", HELM_REPOSITORY_CACHE=tmp + "/cache",
                       HELM_CACHE_HOME=tmp + "/home-cache", HELM_CONFIG_HOME=tmp + "/config")
            out = subprocess.run(cmd, capture_output=True, text=True, timeout=120, check=True, env=env).stdout
    except (subprocess.SubprocessError, OSError) as err:
        print("SKIP  traefik chart appVersion: helm show chart failed (%s)" % type(err).__name__)
        return
    m = re.search(r"^appVersion:\s*\"?(\S+?)\"?\s*$", out, flags=re.M)
    if not m:
        error("traefik chart %s: no appVersion in `helm show chart`" % chart_rev)
    elif m.group(1) != version:
        error("traefik chart %s has appVersion %s but values.yaml versionOverride is %s (bump both together)" % (chart_rev, m.group(1), version))
    else:
        print("OK    traefik chart %s: appVersion %s equals versionOverride" % (chart_rev, version))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--repo", default=str(Path(__file__).resolve().parent.parent))
    ap.add_argument("--check", action="store_true", help="run the checks (the only mode)")
    ap.add_argument("--offline", action="store_true", help="skip every network access")
    args = ap.parse_args()
    repo = Path(args.repo)
    refs = collect(repo)
    for name, ref in refs:
        print("PIN   %s  %s" % (name, ref))
    try:
        digest, version, chart_rev = traefik_pair(repo)
        print("PIN   traefik  docker.io/traefik@%s  (%s, chart %s)" % (digest, version, chart_rev))
        refs.append(("traefik (values.yaml)", "docker.io/traefik:%s@%s" % (version, digest)))
    except ValueError as err:
        error(str(err))
        digest = version = chart_rev = None
    if args.offline:
        print("SKIP  online checks (--offline)")
    else:
        online_refs(refs)
        if version:
            online_chart(chart_rev, version)
    print("%s: %d pins, %d errors" % ("RED" if errors else "OK", len(refs), len(errors)))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
