#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
"""Keeps the git-server addresses in the egress NetworkPolicies in line with lab.yaml.

Why: a NetworkPolicy cannot name a host, only IP ranges (k3s/kube-router: ipBlock). Source access
(Argo CD repo-server, docs builder, notes builders) uses repo_egress_cidrs and the SSH port of repo_url.
Notes content hosts are independent: gitops/sites.yaml pins repo_egress_cidrs per site;
the chart derives their SSH ports from the site repo URLs. These site pins are never rewritten
by a source switch. A different content host/port without pins is rejected before policy writes.
Argo CD reads only Git, so the source values are written into files under gitops/, between markers:

  # lab-egress:repo-cidrs BEGIN ... END   list of "- ipBlock: cidr: X" entries (or the same list in a chart value)
  # lab-egress:repo-port BEGIN ... END    one line "port: N" (the key name is kept)

Usage (from the repo root; values come from infra/envs/local/lab.yaml and lab.local.yaml):
  python3 scripts/repo-egress.py              write the blocks (idempotent)
  python3 scripts/repo-egress.py --dry-run    show what would change
  python3 scripts/repo-egress.py --check      exit 1 on drift or while the value is still the placeholder
  bash scripts/lab.sh repo-egress --resolve    look up the git host of repo_url, show the address(es), write
                                              repo_egress_cidrs into lab.local.yaml (no question: reversible, local file)
  python3 scripts/repo-egress.py --check-live  source: github only: exit 1 when github.com resolves to an address
                                              outside the allowed ranges (exit 2: DNS did not answer)

source: github (ADR 0024): the effective repo_url and repo_egress_cidrs are github_repo_url and github_egress_cidrs.
GitHub names whole ranges for git over SSH (api.github.com/meta), so ranges down to /20 are accepted there (/24 for
every other server); --resolve then writes github_egress_cidrs: the ranges of the meta list that hold the addresses
github.com has now.
Options: --repo DIR, --repo-url URL and --cidrs "A,B" override the configuration (tests); --meta-file FILE and
--addrs "A,B" replace the GitHub meta document and the DNS answer (tests).
No secrets are read or printed; the values are public addresses.
"""
import argparse
import ipaddress
import json
import os
import re
import socket
import sys
import urllib.request

PLACEHOLDER = "203.0.113.10"  # TEST-NET-3 (documentation range): never a real server
CIDR_BEGIN = "# lab-egress:repo-cidrs BEGIN"
CIDR_END = "# lab-egress:repo-cidrs END"
PORT_BEGIN = "# lab-egress:repo-port BEGIN"
PORT_END = "# lab-egress:repo-port END"
FILES = [
    "gitops/workloads/argocd/networkpolicy.yaml",
    "gitops/workloads/docs/networkpolicy.yaml",
    "gitops/charts/notes-site/values.yaml",
]
LAB_BASE = "infra/envs/local/lab.yaml"
LAB_LOCAL = "infra/envs/local/lab.local.yaml"
MIN_PREFIX = 24
GITHUB_MIN_PREFIX = 20  # the narrowest range GitHub documents for git over SSH is a /20
META_URL = "https://api.github.com/meta"


class Fail(Exception):
    pass


def read_flat(path):
    values = {}
    if not os.path.isfile(path):
        return values
    with open(path, encoding="utf-8") as f:
        for line in f:
            m = re.match(r"^([a-z_0-9]+):[ \t]*(.*?)[ \t]*$", line.rstrip("\n"))
            if m and not m.group(2).startswith("#"):
                values[m.group(1)] = m.group(2).strip("\"'")
    return values


def load_config(repo):
    values = read_flat(os.path.join(repo, LAB_BASE))
    values.update(read_flat(os.path.join(repo, LAB_LOCAL)))
    source = values.get("source", "gitea")
    if source not in ("gitea", "github"):
        raise Fail("source must be gitea or github (is '%s')" % source)
    values["source"] = source
    if source == "github":
        # Same override as scripts/lab.sh (cfg_load) and ansible/inventory/group_vars/all/lab.yml (lab).
        values["repo_url"] = values.get("github_repo_url", "")
        values["repo_egress_cidrs"] = values.get("github_egress_cidrs", "")
    return values


def parse_repo_url(url):
    if not isinstance(url, str):
        raise Fail("repo URL must be a string")
    m = re.match(r"^ssh://(?:[^@/]+@)?([^:/]+)(?::(\d+))?/", url)
    if not m:
        raise Fail("repo_url not readable (expected ssh://git@HOST[:PORT]/PATH): %s" % url)
    port = int(m.group(2) or 22)
    if not 1 <= port <= 65535:
        raise Fail("repo URL SSH port must be between 1 and 65535")
    return m.group(1), port


def check_notes_content(repo, source_url):
    """Validate independent content pins offline; never rewrite sites.yaml on a source switch."""
    path = os.path.join(repo, "gitops/sites.yaml")
    if not os.path.isfile(path):
        return  # Minimal policy-only sandboxes need no sites list.
    import yaml  # System PyYAML is required by lab.sh; no DNS or secret access here.
    try:
        with open(path, encoding="utf-8") as f:
            sites = yaml.safe_load(f)
        if sites is None:
            sites = []
    except yaml.YAMLError as x:
        raise Fail("gitops/sites.yaml is not valid YAML") from x
    if not isinstance(sites, list):
        raise Fail("gitops/sites.yaml must be a list")
    for site in sites:
        if not isinstance(site, dict):
            raise Fail("gitops/sites.yaml entries must be mappings")
        content = parse_repo_url(site.get("repo", ""))
        pins = site.get("repo_egress_cidrs", [])
        label = "gitops/sites.yaml %s repo_egress_cidrs" % site.get("name", "?")
        if not isinstance(pins, list) or any(not isinstance(c, str) for c in pins):
            raise Fail("%s must be a list of IPv4 CIDRs" % label)
        if pins:
            normalize_cidrs(",".join(pins), key=label)
            if any("/" not in c for c in pins):
                raise Fail("%s requires explicit CIDRs (use /32 for one address)" % label)
        elif content != parse_repo_url(source_url):
            raise Fail("%s is required: the content host/port differs from the k8s-lab source" % label)


def normalize_cidrs(text, min_prefix=MIN_PREFIX, key="repo_egress_cidrs"):
    """Comma text -> list of IPv4 CIDRs (a single address becomes /32). Refuses wide or odd ranges."""
    out = []
    for item in [e.strip() for e in (text or "").split(",") if e.strip()]:
        try:
            net = ipaddress.ip_network(item, strict=False)
        except ValueError:
            raise Fail("%s: '%s' is not an IPv4 address or network" % (key, item))
        if net.version != 4:
            raise Fail("%s: '%s' is IPv6; only IPv4 is supported (the lab has no IPv6 egress)" % (key, item))
        if net.prefixlen < min_prefix:
            raise Fail("%s: '%s' is wider than /%d; list the git server's own address(es)" % (key, item, min_prefix))
        if net.is_loopback or net.is_unspecified or net.is_multicast or net.is_link_local:
            raise Fail("%s: '%s' is not a usable server address" % (key, item))
        c = str(net)
        if c not in out:
            out.append(c)
    if not out:
        raise Fail("%s is empty" % key)
    return out


def block_regex(begin, end):
    return re.compile(r"^([ \t]*)" + re.escape(begin) + r"\n(.*?)^[ \t]*" + re.escape(end) + r"[ \t]*$", re.M | re.S)


def cidr_block(indent, cidrs):
    lines = [indent + CIDR_BEGIN]
    for c in cidrs:
        lines.append(indent + "- ipBlock:")
        lines.append(indent + "    cidr: " + c)
    lines.append(indent + CIDR_END)
    return "\n".join(lines)


def read_text(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def rewrite(text, cidrs, port, rel):
    m = block_regex(CIDR_BEGIN, CIDR_END).search(text)
    if not m:
        raise Fail("%s: markers '%s' ... '%s' missing" % (rel, CIDR_BEGIN, CIDR_END))
    text = text[: m.start()] + cidr_block(m.group(1), cidrs) + text[m.end():]
    m = block_regex(PORT_BEGIN, PORT_END).search(text)
    if not m:
        raise Fail("%s: markers '%s' ... '%s' missing" % (rel, PORT_BEGIN, PORT_END))
    km = re.match(r"^\s*([A-Za-z]+): \d+\s*$", m.group(2))
    if not km:
        raise Fail("%s: the port block must hold exactly one line 'key: NUMBER'" % rel)
    block = m.group(1) + PORT_BEGIN + "\n" + m.group(1) + "%s: %d\n" % (km.group(1), port) + m.group(1) + PORT_END
    return text[: m.start()] + block + text[m.end():]


def current_values(text, rel):
    m = block_regex(CIDR_BEGIN, CIDR_END).search(text)
    p = block_regex(PORT_BEGIN, PORT_END).search(text)
    if not m or not p:
        raise Fail("%s: markers missing" % rel)
    cidrs = re.findall(r"^\s*cidr:\s*(\S+)\s*$", m.group(2), re.M)
    pm = re.search(r"([0-9]+)\s*$", p.group(2).strip())
    return cidrs, int(pm.group(1)) if pm else None


def write_atomic(path, text, mode=None):
    tmp = path + ".egress.tmp"
    with open(tmp, "w", encoding="utf-8", newline="") as f:
        f.write(text)
    os.chmod(tmp, mode if mode is not None else os.stat(path).st_mode & 0o777)
    os.replace(tmp, path)


def apply(repo, cidrs, port, dry_run):
    changed = 0
    for rel in FILES:
        path = os.path.join(repo, rel)
        if not os.path.isfile(path):
            raise Fail("%s is missing" % rel)
        old = read_text(path)
        new = rewrite(old, cidrs, port, rel)
        if new != old:
            changed += 1
            print("%s: %s" % ("WOULD CHANGE" if dry_run else "EDIT", rel))
            if not dry_run:
                write_atomic(path, new)
    if changed == 0:
        print("SKIP: the git-server blocks already match (%s port %d)." % (",".join(cidrs), port))
    return 0


def check(repo, cidrs, port, placeholder_ok=False):
    problems = []
    if not placeholder_ok and any(c.split("/")[0] == PLACEHOLDER for c in cidrs):
        problems.append("repo_egress_cidrs is still the placeholder %s: run bash scripts/lab.sh repo-egress --resolve" % PLACEHOLDER)
    for rel in FILES:
        path = os.path.join(repo, rel)
        if not os.path.isfile(path):
            problems.append("%s is missing" % rel)
            continue
        have, have_port = current_values(read_text(path), rel)
        if have != cidrs:
            problems.append("%s: has %s, lab.yaml says %s (run bash scripts/lab.sh repo-egress)" % (rel, have, cidrs))
        if have_port != port:
            problems.append("%s: has port %s, repo_url says %d (run bash scripts/lab.sh repo-egress)" % (rel, have_port, port))
    for p in problems:
        print("DRIFT: " + p)
    return 1 if problems else 0


def lookup(host, port, addrs=None):
    """IPv4 addresses of the git host (public, usable ones only). addrs replaces the DNS answer (tests)."""
    if addrs is not None:
        found = [ipaddress.ip_address(a.strip()) for a in addrs.split(",") if a.strip()]
    else:
        try:
            found = [ipaddress.ip_address(host)]
        except ValueError:
            try:
                infos = socket.getaddrinfo(host, port, socket.AF_INET, socket.SOCK_STREAM)
            except OSError as x:
                raise Fail("cannot resolve %s: %s (network? VPN?)" % (host, x))
            found = sorted({ipaddress.ip_address(i[4][0]) for i in infos})
    found = [a for a in found if a.version == 4 and not (a.is_loopback or a.is_unspecified or a.is_multicast or a.is_link_local)]
    if not found:
        raise Fail("%s resolves to no usable IPv4 address (loopback or link-local only?)." % host)
    return found


def github_ranges(meta_file=None):
    """IPv4 networks GitHub documents for git over SSH (api.github.com/meta, field "git")."""
    try:
        if meta_file:
            with open(meta_file, encoding="utf-8") as f:
                doc = json.load(f)
        else:
            with urllib.request.urlopen(META_URL, timeout=15) as r:  # nosec: public document, https
                doc = json.load(r)
        nets = [ipaddress.ip_network(c, strict=False) for c in doc["git"]]
    except (OSError, ValueError, KeyError, TypeError) as x:
        raise Fail("cannot read the git ranges from %s: %s (network?)" % (meta_file or META_URL, x))
    return [n for n in nets if n.version == 4]


def write_local_key(repo, key, value):
    local = os.path.join(repo, LAB_LOCAL)
    line = "%s: %s\n" % (key, value)
    old = read_text(local) if os.path.exists(local) else ""
    if re.search(r"^%s:" % re.escape(key), old, re.M):
        new = re.sub(r"^%s:.*\n?" % re.escape(key), lambda _: line, old, count=1, flags=re.M)
    else:
        new = old + ("" if old.endswith("\n") or not old else "\n") + line
    if new == old:
        print("SKIP: %s in %s is already so." % (key, LAB_LOCAL))
        return 0
    os.makedirs(os.path.dirname(local), exist_ok=True)
    fd = os.open(local + ".egress.tmp", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(new)
    if os.path.exists(local):
        os.chmod(local + ".egress.tmp", os.stat(local).st_mode & 0o777)
    os.replace(local + ".egress.tmp", local)
    print("EDIT: %s (%s)" % (LAB_LOCAL, key))
    return 0


def resolve(repo, url, source="gitea", addrs=None, meta_file=None):
    host, port = parse_repo_url(url)
    if host.endswith("example.org") or "YOUR-NAME" in url:
        raise Fail("repo_url is still the placeholder: set repo_url in lab.local.yaml first.")
    if source == "github" and host != "github.com":
        raise Fail("source: github supports github.com only (is %s)" % host)
    found = lookup(host, port, addrs)
    key = "repo_egress_cidrs"
    if source == "github":
        key = "github_egress_cidrs"
        ranges = github_ranges(meta_file)
        # Keep previously approved regions: DNS on one machine is not the cluster's DNS.
        cfg = load_config(repo)
        existing = normalize_cidrs(cfg["repo_egress_cidrs"], GITHUB_MIN_PREFIX, key)
        cidrs = [c for c in existing if c != PLACEHOLDER]
        for a in found:
            hit = sorted((n for n in ranges if a in n), key=lambda n: n.prefixlen)
            c = str(hit[0]) if hit else str(a)
            if not hit:
                print("WARNING: %s is in none of the git ranges GitHub documents; only the address itself is allowed." % a)
            if c not in cidrs:
                cidrs.append(c)
        print("%s:%d resolves (on this machine) to: %s" % (host, port, ", ".join(str(a) for a in found)))
        print("Ranges GitHub documents for git over SSH that hold them (api.github.com/meta): %s" % ", ".join(cidrs))
    else:
        cidrs = [str(a) for a in found]
        print("%s:%d resolves (on this machine) to: %s" % (host, port, ", ".join(cidrs)))
    print("Pods may then reach the git server only at these address(es), port %d (and the docs/notes builders 443 to the internet)." % port)
    print("If the server's address changes, Git access of the lab stops until you run this again.")
    return write_local_key(repo, key, ",".join(cidrs))


def check_live(cfg, addrs=None):
    """source: github: does github.com resolve into the allowed ranges right now? 0 ok, 1 drift, 2 no DNS answer."""
    if cfg["source"] != "github":
        print("SKIP: source is gitea, no live check.")
        return 0
    host, port = parse_repo_url(cfg["repo_url"])
    cidrs = normalize_cidrs(cfg["repo_egress_cidrs"], GITHUB_MIN_PREFIX, "github_egress_cidrs")
    try:
        found = lookup(host, port, addrs)
    except Fail as x:
        print("SKIP: %s" % x)
        return 2
    nets = [ipaddress.ip_network(c) for c in cidrs]
    out = [str(a) for a in found if not any(a in n for n in nets)]
    if out:
        print("DRIFT: %s resolves to %s, outside github_egress_cidrs (%s): run bash scripts/lab.sh repo-egress --resolve, "
              "then bash scripts/lab.sh repo-egress, commit and push" % (host, ", ".join(out), ",".join(cidrs)))
        return 1
    print("OK: %s resolves into github_egress_cidrs (%s)." % (host, ", ".join(str(a) for a in found)))
    return 0


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
    ap.add_argument("--repo-url")
    ap.add_argument("--cidrs")
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--dry-run", action="store_true")
    mode.add_argument("--check", action="store_true")
    mode.add_argument("--resolve", action="store_true")
    mode.add_argument("--check-live", action="store_true")
    ap.add_argument("--allow-placeholder", action="store_true", help="tests only")
    ap.add_argument("--meta-file", help="tests only: GitHub meta document instead of api.github.com")
    ap.add_argument("--addrs", default=os.environ.get("LAB_EGRESS_ADDRS"),
                    help="tests only: addresses instead of the DNS answer (env LAB_EGRESS_ADDRS)")
    a = ap.parse_args()
    repo = os.path.abspath(a.repo)
    try:
        cfg = load_config(repo)
        url = a.repo_url or cfg.get("repo_url", "")
        github = cfg["source"] == "github"
        if a.repo_url:
            cfg["repo_url"] = a.repo_url
        if a.check_live:
            return check_live(cfg, a.addrs)
        if a.resolve:
            return resolve(repo, url, cfg["source"], a.addrs, a.meta_file)
        host, port = parse_repo_url(url)
        if github and host != "github.com":
            raise Fail("source: github supports github.com only (is %s)" % host)
        cidrs = normalize_cidrs(a.cidrs if a.cidrs is not None else cfg.get("repo_egress_cidrs", ""),
                                GITHUB_MIN_PREFIX if github else MIN_PREFIX,
                                "github_egress_cidrs" if github else "repo_egress_cidrs")
        check_notes_content(repo, url)
        if a.check:
            return check(repo, cidrs, port, a.allow_placeholder)
        if not a.allow_placeholder and any(c.split("/")[0] == PLACEHOLDER for c in cidrs):
            raise Fail("repo_egress_cidrs is still the placeholder %s: run bash scripts/lab.sh repo-egress --resolve first." % PLACEHOLDER)
        return apply(repo, cidrs, port, a.dry_run)
    except (Fail, OSError) as x:
        print("ABORT: %s" % x)
        return 1


if __name__ == "__main__":
    sys.exit(main())
