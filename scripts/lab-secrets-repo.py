#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
"""Copies the SOPS tree (ciphertext only) between the code repo and a separate private secrets repo.

Why (ADR 0022): the public code repo carries no secrets/ at all. Argo CD reads the apps secrets-*
from a private secrets repo (lab.yaml: secrets_repo_url). This script fills that repo from the
secrets/ tree of the working copy (export) or puts the tree back into a fresh clone (import).

Usage (done by scripts/lab.sh secrets-repo, see there):
  lab-secrets-repo.py export --repo REPO --target DIR [--dry-run] [--prune]
  lab-secrets-repo.py import --repo REPO --source DIR [--dry-run]

Rules:
  - Never decrypts and never prints content: only paths, sizes and line numbers.
  - Copies only the managed files: .sops.yaml, secrets/README.md and under secrets/:
    kustomization.yaml, ksops.yaml, *.sops.yaml, *.sops.yaml.example.
  - Every *.sops.yaml must be SOPS ciphertext (sops metadata, every value under data/stringData
    ENC[...]; empty strings stay empty). One file that is not: ABORT, nothing is written.
  - The target of an export must be a git work tree of its own, not a code repo (gitops/ or
    scripts/ present there) and not the source. Otherwise ABORT.
  - Idempotent: an equal file is SKIP. Files in the target that the source no longer has are
    reported (STALE); --prune deletes them (the target is git-tracked, so this is reversible).
  - No commit, no push: the script prints the next git commands.
Exit codes: 0 ok (also: all SKIP), 1 ABORT, 3 usage error.
"""
import argparse
import fnmatch
import os
import re
import subprocess
import sys

MANAGED_TOP = [".sops.yaml", "secrets/README.md"]
MANAGED_NAMES = ["kustomization.yaml", "ksops.yaml", "*.sops.yaml", "*.sops.yaml.example"]
CODE_MARKERS = ["gitops", "scripts", "ansible"]
ENC = re.compile(r"^ENC\[[A-Z0-9_]+,data:")


class Abort(Exception):
    pass


def managed(rel):
    if rel in MANAGED_TOP:
        return True
    if not rel.startswith("secrets/") or rel.count("/") < 2:
        return False
    name = rel.rsplit("/", 1)[1]
    return any(fnmatch.fnmatchcase(name, p) for p in MANAGED_NAMES)


def tree(root):
    """Managed files below root (relative paths, sorted). Symlinks are an ABORT."""
    found = []
    for rel in MANAGED_TOP:
        p = os.path.join(root, rel)
        if os.path.islink(p):
            raise Abort("%s is a symlink (refused)" % rel)
        if os.path.isfile(p):
            found.append(rel)
    base = os.path.join(root, "secrets")
    if os.path.isdir(base) and not os.path.islink(base):
        for dp, dn, fn in os.walk(base):
            dn[:] = sorted(d for d in dn if not d.startswith("."))
            for n in sorted(fn):
                full = os.path.join(dp, n)
                rel = os.path.relpath(full, root).replace(os.sep, "/")
                if not managed(rel) or rel in MANAGED_TOP:
                    continue
                if os.path.islink(full):
                    raise Abort("%s is a symlink (refused)" % rel)
                found.append(rel)
    return sorted(found)


def plaintext_problems(rel, data):
    """Line numbers where a *.sops.yaml is not ciphertext. Never returns content."""
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        return ["%s: not UTF-8 text" % rel]
    lines = text.splitlines()
    problems = []
    if not any(z.startswith("sops:") for z in lines):
        problems.append("%s: no sops: metadata (not encrypted)" % rel)
    block = None
    values = 0
    for i, z in enumerate(lines, 1):
        if not z.strip() or z.lstrip().startswith("#"):
            continue
        if not z.startswith((" ", "\t", "-")):
            block = z.split(":", 1)[0] if re.match(r"^(data|stringData):\s*$", z) else None
            continue
        if block is None:
            continue
        m = re.match(r"^\s+[^\s:][^:]*:\s*(.*)$", z)
        if not m:
            problems.append("%s:%d: value under %s is not a single ENC[...] value" % (rel, i, block))
            continue
        values += 1
        v = m.group(1).strip()
        if v in ('""', "''", ""):
            continue  # sops leaves empty strings as they are (nothing to hide)
        if not ENC.match(v.strip("'\"")):
            problems.append("%s:%d: value under %s is not ENC[...] (plaintext?)" % (rel, i, block))
    if values == 0 and not problems:
        problems.append("%s: no data/stringData values found" % rel)
    return problems


def read(path):
    with open(path, "rb") as f:
        return f.read()


def git_top(path):
    r = subprocess.run(["git", "-C", path, "rev-parse", "--show-toplevel"], capture_output=True, text=True, check=False)
    return os.path.realpath(r.stdout.strip()) if r.returncode == 0 else None


def write(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".secrets-repo.tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
    with os.fdopen(fd, "wb") as f:
        f.write(data)
    os.replace(tmp, path)


def check_source(src):
    if not os.path.isfile(os.path.join(src, ".sops.yaml")) or not os.path.isdir(os.path.join(src, "secrets")):
        raise Abort("%s has no .sops.yaml or no secrets/ (not a k8s-lab repo or secrets repo)" % src)
    files = tree(src)
    problems = []
    for rel in files:
        if rel.endswith(".sops.yaml") and rel != ".sops.yaml":
            problems += plaintext_problems(rel, read(os.path.join(src, rel)))
    if problems:
        raise Abort("not ciphertext, nothing copied:\n  " + "\n  ".join(problems))
    if not any(r.endswith(".sops.yaml") and r != ".sops.yaml" for r in files):
        print("NOTE: %s has no *.sops.yaml yet (only templates); run lab.sh init first for a working lab." % src)
    return files


def copy(src, dst, files, dry_run, prune, label):
    counts = {"SKIP": 0, "COPY": 0, "UPDATE": 0, "STALE": 0, "DELETE": 0}
    for rel in files:
        data = read(os.path.join(src, rel))
        target = os.path.join(dst, rel)
        if os.path.islink(target):
            raise Abort("%s in %s is a symlink (refused)" % (rel, label))
        if os.path.isfile(target) and read(target) == data:
            counts["SKIP"] += 1
            continue
        what = "UPDATE" if os.path.exists(target) else "COPY"
        counts[what] += 1
        print("%s%s: %s (%d bytes)" % ("WOULD " if dry_run else "", what, rel, len(data)))
        if not dry_run:
            write(target, data)
    for rel in tree(dst):
        if rel in files:
            continue
        if prune and rel != ".sops.yaml":
            counts["DELETE"] += 1
            print("%sDELETE: %s (no longer in the source)" % ("WOULD " if dry_run else "", rel))
            if not dry_run:
                os.remove(os.path.join(dst, rel))
        else:
            counts["STALE"] += 1
            print("STALE: %s (not in the source; --prune deletes it)" % rel)
    print("Summary: " + ", ".join("%s %d" % (k, v) for k, v in counts.items()))
    return counts


def export(repo, target, dry_run, prune):
    repo, target = os.path.realpath(repo), os.path.realpath(target)
    if not os.path.isdir(target):
        raise Abort("target %s does not exist (clone the private secrets repo there first)" % target)
    top = git_top(target)
    if top != target:
        raise Abort("target %s is not the root of a git work tree (clone the private secrets repo there)" % target)
    if top == git_top(repo) or target == repo:
        raise Abort("target is the source repo itself")
    code = [m for m in CODE_MARKERS if os.path.isdir(os.path.join(target, m))]
    if code:
        raise Abort("target looks like a code repo (%s present): secrets go only into the private secrets repo"
                    % ", ".join(code))
    files = check_source(repo)
    counts = copy(repo, target, files, dry_run, prune, "target")
    if not dry_run and (counts["COPY"] or counts["UPDATE"] or counts["DELETE"]):
        print("Next: git -C %s add -A && git -C %s commit -m 'Update SOPS files' && git -C %s push" % (target, target, target))
    elif not dry_run:
        print("SKIP: the secrets repo already has this state.")
    return 0


def do_import(repo, source, dry_run):
    repo, source = os.path.realpath(repo), os.path.realpath(source)
    if not os.path.isdir(os.path.join(repo, "gitops")):
        raise Abort("%s is not a k8s-lab code repo (gitops/ is missing)" % repo)
    if source == repo:
        raise Abort("source is the repo itself")
    files = check_source(source)
    counts = copy(source, repo, files, dry_run, False, "repo")
    if not dry_run and (counts["COPY"] or counts["UPDATE"]):
        print("Done. In a public clone secrets/ is in .gitignore: never commit it there.")
    elif not dry_run:
        print("SKIP: secrets/ already has this state.")
    return 0


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("command", choices=["export", "import"])
    ap.add_argument("--repo", required=True)
    ap.add_argument("--target")
    ap.add_argument("--source")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--prune", action="store_true")
    try:
        a = ap.parse_args()
    except SystemExit as x:
        return 3 if x.code else 0
    try:
        if a.command == "export":
            if not a.target or a.source:
                print("usage: export needs --target (and no --source)", file=sys.stderr)
                return 3
            return export(a.repo, a.target, a.dry_run, a.prune)
        if not a.source or a.target or a.prune:
            print("usage: import needs --source (no --target, no --prune)", file=sys.stderr)
            return 3
        return do_import(a.repo, a.source, a.dry_run)
    except Abort as x:
        print("ABORT: %s" % x)
        return 1


if __name__ == "__main__":
    sys.exit(main())
