#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
"""Builds the Kustomize patches that pin every git source of the root app to one commit.

Why (ADR 0023, issue 71): lab.sh checks the signatures of the remote head once, before the
bootstrap. Argo CD then reads the repo by itself, and a branch that moves in between would
bring in commits nobody checked. While a rebuild runs, the root application therefore points
at the verified commit, and so does every child application: the root app builds
gitops/apps with Kustomize, and these patches replace targetRevision (and the revision of
the git generator of an ApplicationSet) of every source that reads the code repo.

Usage:
  python3 scripts/pin-revision.py --repo-url URL --revision SHA [--repo DIR] [--apps gitops/apps]
                                  [--summary]

  --repo-url   the repoURL of the code repo (argocd_repo_url); only sources with exactly
               this URL are pinned, Helm chart sources and the secrets repo are not
  --revision   the verified commit, 40 hex characters (a branch name is refused on purpose)
  --repo       repo root (default: the one that holds this script)
  --apps       folder with kustomization.yaml and the application files
  --from-git   read the application files from this commit of --repo instead of the working tree
               (lab.sh passes the verified commit: uncommitted edits cannot hide an application)
  --summary    write what was pinned to stderr (stdout stays the JSON)

Output (stdout): a JSON list for source.kustomize.patches of the root Application:
  [{"target": {"group": ..., "version": ..., "kind": ..., "name": ...}, "patch": "<JSON6902>"}]

Exit codes: 0 ok, 2 misuse or a file that cannot be read or has no pinnable source.
"""
import argparse
import json
import os
import re
import subprocess
import sys

try:
    import yaml
except ImportError:  # pragma: no cover
    sys.stderr.write("ABORT PyYAML is missing (pip install pyyaml)\n")
    sys.exit(2)

SHA = re.compile(r"^[0-9a-f]{40}$")


def die(msg):
    sys.stderr.write("ABORT %s\n" % msg)
    sys.exit(2)


def pointer(parts):
    return "/" + "/".join(str(p).replace("~", "~0").replace("/", "~1") for p in parts)


def find_sources(node, url, path, parent_key=None):
    """Yield (path of the revision key) for every dict that reads `url`."""
    if isinstance(node, dict):
        if node.get("repoURL") == url:
            key = "revision" if parent_key == "git" else "targetRevision"
            yield path + [key]
        for k, v in node.items():
            yield from find_sources(v, url, path + [k], k)
    elif isinstance(node, list):
        for i, v in enumerate(node):
            yield from find_sources(v, url, path + [i], parent_key)


def reader(repo, from_git):
    """Returns read(relpath) -> text, from the working tree or from a commit."""
    if not from_git:
        def read_file(rel):
            with open(os.path.join(repo, rel), encoding="utf-8") as fh:
                return fh.read()
        return read_file

    def read_git(rel):
        proc = subprocess.run(["git", "-C", repo, "show", "%s:%s" % (from_git, rel)],
                              capture_output=True, text=True, check=False)
        if proc.returncode != 0:
            raise OSError("%s:%s is not in the repo" % (from_git, rel))
        return proc.stdout
    return read_git


def build(repo, apps, url, revision, from_git=None):
    read = reader(repo, from_git)
    base = apps.rstrip("/")
    kfile = base + "/kustomization.yaml"
    try:
        kust = yaml.safe_load(read(kfile)) or {}
    except (OSError, yaml.YAMLError) as exc:
        die("cannot read %s: %s" % (kfile, exc))
    resources = kust.get("resources") or []
    if not resources:
        die("%s lists no resources" % kfile)
    patches = []
    for res in resources:
        fpath = base + "/" + res
        try:
            docs = [d for d in yaml.safe_load_all(read(fpath)) if d]
        except (OSError, yaml.YAMLError) as exc:
            die("cannot read %s: %s" % (fpath, exc))
        for doc in docs:
            kind = doc.get("kind")
            if kind not in ("Application", "ApplicationSet"):
                continue
            ops = [
                {"op": "add", "path": pointer(p), "value": revision}
                for p in find_sources(doc.get("spec", {}), url, ["spec"])
            ]
            if not ops:
                continue
            group, _, version = doc["apiVersion"].partition("/")
            patches.append({
                "target": {"group": group, "version": version, "kind": kind, "name": doc["metadata"]["name"]},
                "patch": json.dumps(ops),
            })
    if not patches:
        die("no Application in %s reads %s: nothing to pin (wrong --repo-url?)" % (kfile, url))
    return patches


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--repo-url", required=True)
    ap.add_argument("--revision", required=True)
    ap.add_argument("--repo", default=os.path.dirname(here))
    ap.add_argument("--apps", default="gitops/apps")
    ap.add_argument("--from-git", default=None)
    ap.add_argument("--summary", action="store_true")
    args = ap.parse_args()
    if not SHA.match(args.revision):
        die("--revision must be a full commit hash (40 hex characters), not %r" % args.revision)
    if args.from_git and not SHA.match(args.from_git):
        die("--from-git must be a full commit hash")
    patches = build(args.repo, args.apps, args.repo_url, args.revision, args.from_git)
    json.dump(patches, sys.stdout, sort_keys=True)
    sys.stdout.write("\n")
    if args.summary:
        n = sum(len(json.loads(p["patch"])) for p in patches)
        sys.stderr.write("INFO pinned %d source(s) in %d object(s) to %s\n" % (n, len(patches), args.revision[:12]))


if __name__ == "__main__":
    main()
