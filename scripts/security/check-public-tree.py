#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
"""Positive-list check of a repository tree for the public (GitHub) version.

Fails (exit 1) on:
  - file names that must never be public (real SOPS secrets, keys, state files, disk images, dumps)
  - content that must never be public (SOPS ciphertext, age keys, PEM private keys, the PRIVATE block markers of
    the export, JWTs, kubeconfig credentials)
  - e-mail addresses, URL hosts and host names with a real top-level domain that are not in allowed-hosts.txt
  - public (globally routable) IPv4 addresses that are not documentation ranges

The check never prints the finding itself, only path:line and the rule id (the log of a public CI is public).
It needs no private list, so it runs in the public repository. The private deny list is a second layer (scripts/public/
and the optional CI secret PII_DENYLIST, see docs/concepts/public-release-security.md).

  python3 scripts/security/check-public-tree.py [--root DIR] [--allowed-hosts FILE] [--files-from-git|--walk]
Exit code: 0 clean, 1 findings, 2 usage or read error.
"""
import argparse
import fnmatch
import ipaddress
import os
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent

# Parts are joined at runtime, so that this file does not trip the very rules it implements.
PEM = "-----BEGIN [A-Z ]*PRIVATE" + " KEY-----"
AGE_SECRET = "AGE-SECRET" + "-KEY-1[QPZRY9X8GF2TVDW0S3JN54KHCE6MUA7L]{58}"
NAME_RULES = [
    ("real-sops-secret", "*.sops.yaml", "*.sops.yml", "*.sops.json", "*.sops.env"),
    ("key-or-certificate-file", "*.pem", "*.key", "*.p12", "*.pfx", "*.jks", "*.kdbx", "id_rsa", "id_rsa.*", "id_ed25519", "id_ed25519.*", "id_ecdsa", "id_ecdsa.*"),
    ("credentials-file", ".env", ".env.*", ".netrc", ".pgpass", "kubeconfig", "*.kubeconfig", "keys.txt", "*.age", "credentials.json"),
    ("state-or-image-or-dump", "*.tfstate", "*.tfstate.*", "*.qcow2", "*.vmdk", "*.dump", "*.sql.gz", "*.bak"),
]
# .sops.yaml (no prefix) is the SOPS configuration with the public age recipients, not a secret.
NAME_EXCEPTIONS = ("*.example", "*.sample", "*.template", ".sops.yaml")
CONTENT_RULES = [
    ("sops-ciphertext", re.compile(r"ENC\[AES256_GCM,data:[A-Za-z0-9+/=]{8,}")),
    ("age-secret-key", re.compile(AGE_SECRET)),
    ("pem-private-key", re.compile(PEM)),
    ("private-block-marker", re.compile(r"PRIVATE-(?:BEGIN|END)")),
    ("jwt", re.compile(r"\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.")),
    ("kubeconfig-credentials", re.compile(r"\b(?:client-key-data|client-certificate-data|certificate-authority-data):\s*[A-Za-z0-9+/=]{40,}")),
]
EMAIL = re.compile(r"(?<![A-Za-z0-9._%+-])[A-Za-z0-9._%+-]+@([A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,})\b")
URL_HOST = re.compile(r"\b(?:https?|ssh|git|wss?|ftp)://(?:[^/\s@'\"]+@)?([A-Za-z0-9.-]+)")
TLDS = "dev ch eu de com net org io cloud me xyz ai fr it uk nl ru cn jp".split()
BARE_HOST = re.compile(r"\b((?:[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?\.)+(?:%s))\b(?![A-Za-z0-9_-])" % "|".join(TLDS))
IPV4 = re.compile(r"(?<![0-9.])(?:(?:25[0-5]|2[0-4][0-9]|1?[0-9]{1,2})\.){3}(?:25[0-5]|2[0-4][0-9]|1?[0-9]{1,2})(?![0-9])(?!\.[0-9])")
DOC_NETS = [ipaddress.ip_network(n) for n in ("192.0.2.0/24", "198.51.100.0/24", "203.0.113.0/24", "198.18.0.0/15")]


ALLOWED_IPS = set()


def load_patterns(path):
    """Host patterns; lines "ip:ADDRESS" allow one public IPv4 address (e.g. a public DNS resolver in a probe)."""
    out = []
    for line in Path(path).read_text().splitlines():
        line = line.strip().lower()
        if not line or line.startswith("#"):
            continue
        if line.startswith("ip:"):
            ALLOWED_IPS.add(line[3:].strip())
        else:
            out.append(line)
    return out


def host_allowed(host, patterns):
    host = host.lower().rstrip(".")
    return any(fnmatch.fnmatchcase(host, p) for p in patterns)


def list_files(root, mode):
    if mode != "walk" and (root / ".git").exists():
        r = subprocess.run(["git", "-C", str(root), "ls-files", "-z"], capture_output=True)
        if r.returncode == 0:
            return [p for p in r.stdout.decode("utf-8", "surrogateescape").split("\0") if p]
    out = []
    # A public clone may hold the imported, git-ignored secrets/ (ADR 0022, lab.sh secrets-repo import):
    # it never goes public, so the walk leaves it out, but only when git really ignores it.
    skip_secrets = (root / ".git").exists() and (root / "secrets").is_dir() and subprocess.run(
        ["git", "-C", str(root), "check-ignore", "-q", "secrets/"], capture_output=True).returncode == 0
    if skip_secrets:
        print("check-public-tree: secrets/ is git-ignored (private secrets repo, ADR 0022), not walked")
    for dp, dn, fn in os.walk(root):
        dn[:] = [d for d in dn if d != ".git" and not (skip_secrets and Path(dp) == root and d == "secrets")]
        out += [str((Path(dp) / f).relative_to(root)) for f in fn]
    return sorted(out)


def name_findings(rel):
    # The top-level secrets/ folder lives only in the private secrets repo (ADR 0022).
    if rel.replace(os.sep, "/").split("/", 1)[0] == "secrets":
        return ["secrets-dir"]
    base = os.path.basename(rel)
    if any(fnmatch.fnmatchcase(base, x) for x in NAME_EXCEPTIONS):
        return []
    hits = []
    for rule in NAME_RULES:
        if any(fnmatch.fnmatchcase(base, pat) for pat in rule[1:]):
            hits.append(rule[0])
    return hits


def check_line(line, patterns):
    hits = []
    for rid, rx in CONTENT_RULES:
        if rx.search(line):
            hits.append(rid)
    for m in EMAIL.finditer(line):
        if not IPV4.fullmatch(m.group(1)) and not host_allowed(m.group(1), patterns):
            hits.append("email-domain-not-allowed")
    seen = set()
    for m in URL_HOST.finditer(line):
        h = m.group(1).lower().rstrip(".")
        seen.add(h)
        if IPV4.fullmatch(h):
            continue
        if "." in h and not host_allowed(h, patterns) and re.search(r"\.(%s)$" % "|".join(TLDS), h):
            hits.append("url-host-not-allowed")
    for m in BARE_HOST.finditer(line):
        h = m.group(1).lower()
        if h in seen or host_allowed(h, patterns):
            continue
        # file names such as foo.sh or a Python module chain are not in TLDS; real names with a TLD must be listed
        hits.append("host-not-allowed")
    for m in IPV4.finditer(line):
        try:
            ip = ipaddress.ip_address(m.group(0))
        except ValueError:
            continue
        if ip.is_global and not ip.is_multicast and m.group(0) not in ALLOWED_IPS and not any(ip in n for n in DOC_NETS):
            hits.append("public-ipv4")
    return sorted(set(hits))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--root", default=".")
    ap.add_argument("--allowed-hosts", default=str(HERE / "allowed-hosts.txt"))
    ap.add_argument("--walk", action="store_true", help="walk the folder instead of git ls-files")
    ap.add_argument("--summary", action="store_true", help="print only the count per rule")
    a = ap.parse_args()
    root = Path(a.root).resolve()
    if not root.is_dir() or not Path(a.allowed_hosts).is_file():
        print("check-public-tree: root or allowed-hosts file missing", file=sys.stderr)
        return 2
    patterns = load_patterns(a.allowed_hosts)
    findings = []
    files = list_files(root, "walk" if a.walk else "git")
    for rel in files:
        for rid in name_findings(rel):
            findings.append((rel, 0, rid))
        p = root / rel
        if not p.is_file() or p.is_symlink():
            continue
        try:
            data = p.read_bytes()
        except OSError:
            continue
        if b"\0" in data[:8192]:
            continue
        for nr, line in enumerate(data.decode("utf-8", "replace").splitlines(), 1):
            for rid in check_line(line, patterns):
                findings.append((rel, nr, rid))
    if not findings:
        print("check-public-tree: clean (%d files)" % len(files))
        return 0
    if a.summary:
        counts = {}
        for _, _, rid in findings:
            counts[rid] = counts.get(rid, 0) + 1
        for rid, c in sorted(counts.items()):
            print("  %-26s %d" % (rid, c))
    else:
        for rel, nr, rid in findings[:200]:
            print("  %s%s  [%s]" % (rel, ":%d" % nr if nr else "", rid))
        if len(findings) > 200:
            print("  ... and %d more" % (len(findings) - 200))
    print("check-public-tree: %d finding(s) in %d files (the text itself is never printed)" % (len(findings), len(files)))
    return 1


if __name__ == "__main__":
    sys.exit(main())
