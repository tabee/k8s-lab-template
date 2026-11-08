#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
"""Offline drift check: values that are copied into gitops/ must equal their source.

Argo CD reads only Git, so some values of lab.yaml and group_vars exist twice. This
script compares the copies in gitops/ with the expected values and prints one
MISMATCH line per deviation. It reads files only (no cluster, no network).

Usage:
  consistency-check.py --repo DIR --expect FILE      # FILE: JSON object, or "-" for stdin
Exit code: 0 = no deviation, 1 = at least one MISMATCH, 2 = bad input.

Expected JSON keys (ansible/verify-consistency.yml builds them from lab.yaml and group_vars):
  vm_ip, gateway, s3_port, repo_cidrs (list), repo_port, domain,
  probe_image, revision, gateway_files (list of paths relative to --repo),
  matrix_server_name

Checks (the number in brackets is the check id in the output):
  [gateway]   gateway files name http://<gateway>:<s3_port>
  [netpol]    every allow-list ipBlock (no "except") of the NetworkPolicies in gitops/ is one of
              vm_ip/32:6443, gateway/32:s3_port or repo_cidrs x {repo_port, 443}; gitea, db-lab and
              matrix keep the API and the S3 rule
  [traefik]   ingress ports of the Traefik NetworkPolicy equal the container ports in the values
  [domain]    gitea.config.server.DOMAIN lies below the lab domain
  [matrix]    chart serverName equals matrix_server_name, chart domain equals the lab domain,
              certificate dnsNames are exactly matrix.<domain> and element.<domain>
  [images]    probe image == builder images of docs and notes; docs web image == notes web image
  [revision]  every git source of gitops/apps/*.yaml (and the ApplicationSet generator) uses the revision
"""
import argparse
import fnmatch
import json
import os
import re
import subprocess
import sys
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover - the message is the point
    print("ERROR: PyYAML is missing (python3-yaml, or run with the Python of ansible-core).", file=sys.stderr)
    sys.exit(2)

problems = []
checks = 0


def check(ok, check_id, text):
    """Count one check; record a MISMATCH line when it fails."""
    global checks
    checks += 1
    if not ok:
        problems.append("MISMATCH [%s] %s" % (check_id, text))


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


def load_all(path):
    with open(path, encoding="utf-8") as fh:
        return [d for d in yaml.safe_load_all(fh) if d is not None]


def as_cidr(value):
    """A single address becomes /32 (IPv4), like the group_vars of the lab."""
    value = str(value).strip()
    return value if "/" in value else value + "/32"


def check_gateway(repo, exp):
    want = "http://%s:%s" % (exp["gateway"], exp["s3_port"])
    for rel in exp["gateway_files"]:
        text = (repo / rel).read_text(encoding="utf-8")
        check(want in text, "gateway", "%s does not contain %s" % (rel, want))


def netpol_rules(repo):
    """Yield (relpath, policy name, cidr, sorted ports) for every ipBlock without 'except'."""
    for sub in ("gitops/workloads", "gitops/platform"):
        for path in repo_files(repo, sub, "*.yaml"):
            text = path.read_text(encoding="utf-8")
            if "kind: NetworkPolicy" not in text or "{{" in text:
                continue
            rel = str(path.relative_to(repo))
            for doc in load_all(path):
                if not isinstance(doc, dict) or doc.get("kind") != "NetworkPolicy":
                    continue
                name = doc.get("metadata", {}).get("name", "?")
                for rule in doc.get("spec", {}).get("egress", []) or []:
                    ports = sorted(int(p["port"]) for p in rule.get("ports", []) or [])
                    for peer in rule.get("to", []) or []:
                        block = peer.get("ipBlock")
                        if block and not block.get("except"):
                            yield rel, name, block["cidr"], ports


def check_netpol(repo, exp):
    api = (as_cidr(exp["vm_ip"]), [6443])
    s3 = (as_cidr(exp["gateway"]), [int(exp["s3_port"])])
    # Git server: its SSH port, and 443 for the HTTPS clone of the docs plugin (see the comment in the policies).
    repo_ports = sorted({int(exp["repo_port"]), 443})
    repo_pairs = [(as_cidr(c), repo_ports) for c in exp["repo_cidrs"]]
    allowed = [api, s3] + repo_pairs
    seen = {}
    for rel, name, cidr, ports in netpol_rules(repo):
        pair = (cidr, ports)
        check(pair in allowed, "netpol", "%s (%s): ipBlock %s ports %s is not vm_ip:6443, gateway:%s or a repo address"
              % (rel, name, cidr, ports, exp["s3_port"]))
        seen.setdefault(rel, []).append(pair)
    for rel in (
        "gitops/workloads/gitea/manifests/networkpolicy.yaml",
        "gitops/workloads/db-lab/networkpolicy.yaml",
        "gitops/workloads/matrix/manifests/networkpolicy.yaml",
        "gitops/workloads/keycloak/manifests/networkpolicy.yaml",
    ):
        pairs = seen.get(rel, [])
        check(api in pairs, "netpol", "%s has no API rule (%s, 6443)" % (rel, api[0]))
        check(s3 in pairs, "netpol", "%s has no S3 rule (%s, %s)" % (rel, s3[0], s3[1][0]))


def check_traefik(repo):
    values = yaml.safe_load((repo / "gitops/platform/traefik/values.yaml").read_text(encoding="utf-8"))
    ports = values.get("ports", {})
    want = []
    for name in ("web", "websecure", "admin"):
        port = ports.get(name, {}).get("port")
        check(port is not None, "traefik", "ports.%s.port is not set explicitly in the Traefik values" % name)
        if port is not None:
            want.append(int(port))
    policy = None
    for doc in load_all(repo / "gitops/platform/traefik/manifests/networkpolicy.yaml"):
        if doc.get("kind") == "NetworkPolicy" and doc["metadata"]["name"] == "traefik-ingress":
            policy = doc
    check(policy is not None, "traefik", "NetworkPolicy traefik-ingress is missing")
    if policy is not None and len(want) == 3:
        got = sorted(int(p["port"]) for r in policy["spec"].get("ingress", []) for p in r.get("ports", []))
        check(got == sorted(want), "traefik", "NetworkPolicy traefik-ingress allows ports %s, the Traefik values open %s"
              % (got, sorted(want)))


def check_domain(repo, exp):
    values = yaml.safe_load((repo / "gitops/workloads/gitea/values-gitea.yaml").read_text(encoding="utf-8"))
    host = values["gitea"]["config"]["server"]["DOMAIN"]
    check(host.endswith("." + exp["domain"]), "domain", "gitea DOMAIN %s is not below the lab domain %s" % (host, exp["domain"]))


def check_matrix(repo, exp):
    """server_name is one variable. Public certificate names follow the lab domain."""
    values = yaml.safe_load((repo / "gitops/charts/matrix/values.yaml").read_text(encoding="utf-8"))
    check(values.get("serverName") == exp["matrix_server_name"], "matrix",
          "serverName is %s, lab.yaml says %s" % (values.get("serverName"), exp["matrix_server_name"]))
    check(values.get("domain") == exp["domain"], "matrix",
          "matrix chart domain %s, lab domain %s" % (values.get("domain"), exp["domain"]))
    names = []
    for doc in load_all(repo / "gitops/workloads/matrix/manifests/certificate.yaml"):
        if isinstance(doc, dict) and doc.get("kind") == "Certificate":
            names = list(doc.get("spec", {}).get("dnsNames") or [])
    want = sorted(["matrix." + exp["domain"], "element." + exp["domain"]])
    check(sorted(names) == want, "matrix", "certificate dnsNames %s, expected %s" % (sorted(names), want))


def images_of(path, prefix):
    """Sorted, unique image references of a manifest that start with the prefix."""
    found = re.findall(r"image:\s*(\S+)", path.read_text(encoding="utf-8"))
    return sorted({i for i in found if i.startswith(prefix)})


def check_images(repo, exp):
    docs_file = repo / "gitops/workloads/docs/deployment.yaml"
    notes = yaml.safe_load((repo / "gitops/charts/notes-site/values.yaml").read_text(encoding="utf-8"))["images"]
    builders = images_of(docs_file, "docker.io/library/python:")
    check(builders == [exp["probe_image"]], "images", "builder image(s) of the docs site %s differ from the probe image %s"
          % (builders, exp["probe_image"]))
    check(notes["builder"] == exp["probe_image"], "images", "notes builder image %s differs from the probe image %s"
          % (notes["builder"], exp["probe_image"]))
    webs = images_of(docs_file, "docker.io/joseluisq/static-web-server:")
    check(webs == [notes["web"]], "images", "web image(s) of the docs site %s differ from the notes web image %s"
          % (webs, notes["web"]))


def check_revision(repo, exp):
    want = exp["revision"]
    for path in sorted((repo / "gitops/apps").glob("*.yaml")):
        rel = str(path.relative_to(repo))
        for doc in load_all(path):
            spec = doc.get("spec", {})
            sources = list(spec.get("sources", []) or [])
            sources += [spec["source"]] if spec.get("source") else []
            tmpl = spec.get("template", {}).get("spec", {})
            sources += [tmpl["source"]] if tmpl.get("source") else []
            for src in sources:
                if str(src.get("repoURL", "")).startswith("ssh://"):
                    check(src.get("targetRevision") == want, "revision", "%s: git source targetRevision %s, expected %s"
                          % (rel, src.get("targetRevision"), want))
            for gen in spec.get("generators", []) or []:
                if "git" in gen:
                    check(gen["git"].get("revision") == want, "revision", "%s: generator revision %s, expected %s"
                          % (rel, gen["git"].get("revision"), want))


def check_kustomization(repo):
    """Issue 71: the root app builds gitops/apps with Kustomize; a file missing from the list would not be deployed."""
    apps = repo / "gitops/apps"
    kfile = apps / "kustomization.yaml"
    try:
        listed = [str(r) for r in (load_all(kfile)[0].get("resources") or [])]
    except (OSError, IndexError, AttributeError, yaml.YAMLError):
        check(False, "kustomization", "gitops/apps/kustomization.yaml is missing or has no resources")
        return
    present = sorted(p.name for p in apps.glob("*.yaml") if p.name != "kustomization.yaml")
    check(sorted(listed) == present, "kustomization", "gitops/apps/kustomization.yaml: listed but missing %s, present but not listed %s"
          % (sorted(set(listed) - set(present)), sorted(set(present) - set(listed))))
    check(len(listed) == len(set(listed)), "kustomization", "gitops/apps/kustomization.yaml lists a file twice")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--repo", required=True)
    ap.add_argument("--expect", required=True, help='JSON file, or "-" for stdin')
    args = ap.parse_args()
    repo = Path(args.repo)
    try:
        raw = sys.stdin.read() if args.expect == "-" else Path(args.expect).read_text(encoding="utf-8")
        exp = json.loads(raw)
        for key in ("vm_ip", "gateway", "s3_port", "repo_cidrs", "repo_port", "domain", "probe_image", "revision",
                    "gateway_files", "matrix_server_name"):
            if key not in exp:
                raise KeyError(key)
    except (OSError, ValueError, KeyError) as err:
        print("ERROR: bad expectation input: %r" % (err,), file=sys.stderr)
        return 2
    check_gateway(repo, exp)
    check_netpol(repo, exp)
    check_traefik(repo)
    check_domain(repo, exp)
    check_matrix(repo, exp)
    check_images(repo, exp)
    check_revision(repo, exp)
    check_kustomization(repo)
    for line in problems:
        print(line)
    print("%s: %d checks, %d mismatches" % ("RED" if problems else "OK", checks, len(problems)))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
