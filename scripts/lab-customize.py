#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
"""Writes your own values (lab.yaml / lab.local.yaml) into the files that Argo CD reads from Git.

Why: Argo CD only reads Git. Domain, repo address, gateway and VM network are therefore also hard-coded in
gitops/ (and the domain in zensical.toml). The source stays lab.yaml. gitops/values-state.yaml remembers
which values currently stand in these files; the change goes from that state to the values from lab.yaml.

Usage (done by scripts/lab.sh customize, the values come from there):
  lab-customize.py --repo REPO --domain D --repo-url U [--secrets-repo-url S] --gateway G --vm-cidr C --vm-ip I
                  [--edge-ingress-cidrs "A,B"] [--server-name NAME] [--dry-run | --check]
  lab-customize.py --repo REPO --fetch-host-keys --repo-url U --local-file lab.local.yaml [--yes] [--github]

Rules: only whole words are replaced (never part of a longer name or an IP). Everything in
one pass (no chained replacing). The ingress networks (edge_ingress_cidrs, a list) stand
between two markers in gitops/platform/traefik/values.yaml and are rewritten as a block.
--server-name is optional. When it is set, the serverName line in the Matrix chart values
is written AFTER the domain replacement, so the Matrix identity does not follow the lab
domain. Repeating changes nothing. The state is written last:
if a run aborts, the next one continues. No secrets, only public values.
--secrets-repo-url (default: --repo-url) is the repo of the apps that read secrets/ (path: secrets/...
in gitops/apps/*.yaml, ADR 0022). Their repoURL line is written AFTER the word replacement. It must have
the same host and port as --repo-url (the egress policies allow one Git server).
--fetch-host-keys --github (source: github, ADR 0024): scans github.com (ed25519, ecdsa, rsa), accepts only keys whose
SHA-256 fingerprint is one GitHub publishes (GITHUB_FINGERPRINTS below, from docs.github.com "GitHub's SSH key
fingerprints") and writes them as github_known_hosts. A key that is not on the list aborts; nothing is written.
"""
import argparse
import os
import re
import subprocess
import sys

STATE = "gitops/values-state.yaml"
# Fingerprints GitHub publishes for github.com
# (https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints,
# the same keys as ssh_key_fingerprints of https://api.github.com/meta). tests/trust-tests.sh compares them with
# github_known_hosts in infra/envs/local/lab.yaml.
GITHUB_FINGERPRINTS = {
    "ssh-ed25519": "SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU",
    "ecdsa-sha2-nistp256": "SHA256:p2QAMXNIC1TJYWeIOttrVc98/R1BUFWu3/LiyKgUfQM",
    "ssh-rsa": "SHA256:uNiVztksCsDhcc0u9e8BujQXVUpKZIDTMczCvj3tD2s",
}
# Places that Argo CD or the docs build read from Git and that contain the values hard-coded.
PLACES = ["gitops", "zensical.toml"]
KEYS = ["domain", "repo_url", "gateway", "vm_cidr", "vm_ip"]
# List (comma separated, in this order), no word replacement: it is written as a block.
# If the key is missing in an old state, vm_cidr applies (that was hard-wired like this up to wave 1).
ITEMS = "edge_ingress_cidrs"
# Repo of the SOPS apps (path: secrets/...). Missing in an old state = repo_url.
SECRETS = "secrets_repo_url"
APPS = "gitops/apps"
SECRETS_PATH = re.compile(r"^\s*path:\s*secrets/", re.M)
REPO_LINE = re.compile(r"^(\s*(?:-\s+)?repoURL:\s*)(ssh://\S+)(\s*)$", re.M)
TRAEFIK_VALUES = "gitops/platform/traefik/values.yaml"
BLOCK_BEGIN = "# lab-customize:edge-ingress-cidrs BEGIN"
BLOCK_END = "# lab-customize:edge-ingress-cidrs END"
# Matrix identity. Not part of the word replacement: a domain change would rewrite it,
# and phase 2 sets it to the name of the server being imported.
SERVER_VALUES = "gitops/charts/matrix/values.yaml"
SERVER_LINE = re.compile(r"^serverName:\s*(\S+)\s*$", re.M)
HEADER = (
    "# Maintained by \"bash scripts/lab.sh customize\", do not edit by hand.\n"
    "# These values are currently hard-coded in gitops/ and zensical.toml (Argo CD only reads Git).\n"
    "# Source of the values: infra/envs/local/lab.yaml and lab.local.yaml. If a value there\n"
    "# differs, \"customize\" writes it into the files and in here. Then commit and push.\n"
)


class LabError(Exception):
    pass


def read_state(fpath):
    values = {}
    with open(fpath, encoding="utf-8") as f:
        for z in f:
            z = z.rstrip("\n")
            if not z.strip() or z.lstrip().startswith("#"):
                continue
            m = re.match(r"^([a-z_]+): (.+)$", z)
            if not m:
                raise LabError("%s: line not readable: %s" % (fpath, z))
            values[m.group(1)] = m.group(2).strip()
    is_missing = [k for k in KEYS if k not in values]
    if is_missing:
        raise LabError("%s: keys missing: %s" % (fpath, ", ".join(is_missing)))
    values.setdefault(ITEMS, values["vm_cidr"])
    values.setdefault(SECRETS, values["repo_url"])
    return values


def state_text(values):
    return HEADER + "".join("%s: %s\n" % (k, values[k]) for k in KEYS + [ITEMS, SECRETS])


def pattern(value, kind):
    """Regex for a value as a whole word. kind: name (domain), ip, url."""
    raw = re.escape(value)
    if kind == "ip":  # not part of a longer number/IP
        return r"(?<![0-9.])" + raw + r"(?![0-9])(?!\.[0-9])"
    if kind == "url":
        return r"(?<![A-Za-z0-9_/.:@-])" + raw + r"(?![A-Za-z0-9_/.:@-])"
    return r"(?<![A-Za-z0-9_-])" + raw + r"(?![A-Za-z0-9_-])"


KINDS = {"domain": "name", "repo_url": "url", "gateway": "ip", "vm_cidr": "ip", "vm_ip": "ip"}


def files(repo):
    for place in PLACES:
        p = os.path.join(repo, place)
        if os.path.islink(p):
            continue
        if os.path.isfile(p):
            yield place
        elif os.path.isdir(p):
            for root, folder, names in os.walk(p):
                folder.sort()
                for n in sorted(names):
                    if not os.path.islink(os.path.join(root, n)):
                        yield os.path.relpath(os.path.join(root, n), repo)


def read_text(fpath):
    try:
        with open(fpath, encoding="utf-8") as f:
            return f.read()
    except UnicodeDecodeError:
        return None


def rewrite(repo, old, new_values, dry_run):
    """Replaces all old values with the new ones in one pass. Returns a list (file, count)."""
    pairs = {old[k]: new_values[k] for k in KEYS if old[k] != new_values[k]}
    if not pairs:
        return []
    # Longest first: 192.168.122.0/24 before 192.168.122.1, the URL before the domain.
    parts = []
    for k in sorted((k for k in KEYS if old[k] != new_values[k]), key=lambda k: -len(old[k])):
        parts.append("(?P<%s>%s)" % (k, pattern(old[k], KINDS[k])))
    rx = re.compile("|".join(parts))

    def replacement(m):
        return new_values[m.lastgroup]

    result = []
    for rel in files(repo):
        if rel == STATE:
            continue
        fpath = os.path.join(repo, rel)
        if os.path.islink(fpath):
            continue
        text = read_text(fpath)
        if text is None:
            continue
        new_value, n = rx.subn(replacement, text)
        if n == 0:
            continue
        result.append((rel, n))
        if not dry_run:
            tmp = fpath + ".customize.tmp"
            with open(tmp, "w", encoding="utf-8", newline="") as f:
                f.write(new_value)
            os.chmod(tmp, os.stat(fpath).st_mode & 0o777)
            os.replace(tmp, fpath)
    return result


def host_port(url):
    m = re.match(r"^ssh://(?:[^@/]+@)?([^:/]+)(?::(\d+))?/", url or "")
    return (m.group(1), m.group(2) or "22") if m else None


def secrets_apps(repo):
    """gitops/apps/*.yaml that read secrets/ (path: secrets/...), relative paths."""
    d = os.path.join(repo, APPS)
    found = []
    if os.path.isdir(d):
        for n in sorted(os.listdir(d)):
            rel = APPS + "/" + n
            text = read_text(os.path.join(repo, rel)) if n.endswith(".yaml") else None
            if text and SECRETS_PATH.search(text):
                found.append(rel)
    return found


def rewrite_secrets_apps(repo, url, dry_run):
    """Sets the ssh repoURL of every secrets app to url. Returns a list (file, count)."""
    result = []
    for rel in secrets_apps(repo):
        fpath = os.path.join(repo, rel)
        text = read_text(fpath)
        new_value, n = REPO_LINE.subn(lambda m: m.group(1) + url + m.group(3), text)
        if new_value == text:
            continue
        result.append((rel, n))
        if not dry_run:
            tmp = fpath + ".customize.tmp"
            with open(tmp, "w", encoding="utf-8", newline="") as f:
                f.write(new_value)
            os.chmod(tmp, os.stat(fpath).st_mode & 0o777)
            os.replace(tmp, fpath)
    return result


def split_list(text):
    return [e.strip() for e in text.split(",") if e.strip()]


def read_block(text):
    """Returns (start, end, indent, list) of the block between the markers, else None."""
    m = re.search(
        r"^([ \t]*)" + re.escape(BLOCK_BEGIN) + r"\n(.*?)^[ \t]*" + re.escape(BLOCK_END) + r"[ \t]*$",
        text,
        re.M | re.S,
    )
    if not m:
        return None
    entries = re.findall(r"^\s*-\s+(\S+)\s*$", m.group(2), re.M)
    return m, m.group(1), entries


def block_text(indent, items):
    text_lines = [indent + BLOCK_BEGIN, indent + "loadBalancerSourceRanges:"]
    text_lines += [indent + "  - " + c for c in items]
    text_lines.append(indent + BLOCK_END)
    return "\n".join(text_lines)


def rewrite_block(repo, items, dry_run):
    """Writes the ingress networks between the markers. Returns 1 on change, else 0."""
    fpath = os.path.join(repo, TRAEFIK_VALUES)
    text = read_text(fpath)
    if text is None:
        raise LabError("%s is missing or is not text." % TRAEFIK_VALUES)
    b = read_block(text)
    if b is None:
        raise LabError("%s: markers '%s' ... '%s' are missing." % (TRAEFIK_VALUES, BLOCK_BEGIN, BLOCK_END))
    m, indent, _ = b
    new_value = text[: m.start()] + block_text(indent, items) + text[m.end() :]
    if new_value == text:
        return 0
    if not dry_run:
        tmp = fpath + ".customize.tmp"
        with open(tmp, "w", encoding="utf-8", newline="") as f:
            f.write(new_value)
        os.chmod(tmp, os.stat(fpath).st_mode & 0o777)
        os.replace(tmp, fpath)
    return 1


def server_name_problems(repo, server_name):
    """Empty server_name means the caller did not pass --server-name."""
    if not server_name:
        return []
    if re.search(r"[\s'\"]", server_name):
        return ["server_name: value contains whitespace or quotes"]
    text = read_text(os.path.join(repo, SERVER_VALUES))
    if text is None:
        return ["%s is missing" % SERVER_VALUES]
    found = SERVER_LINE.findall(text)
    if len(found) != 1:
        return ["%s: expected exactly one serverName line, found %d" % (SERVER_VALUES, len(found))]
    if found[0] != server_name:
        return ["%s: serverName is '%s', lab.yaml says '%s'" % (SERVER_VALUES, found[0], server_name)]
    return []


def apply_server_name(repo, server_name, dry_run):
    """Pin serverName after the domain replacement. Returns 1 when the line changes."""
    problems = server_name_problems(repo, server_name)
    if not problems:
        return 0
    if not any("lab.yaml says" in p for p in problems):
        raise LabError(problems[0])
    fpath = os.path.join(repo, SERVER_VALUES)
    text = read_text(fpath)
    new_value, n = SERVER_LINE.subn("serverName: %s" % server_name, text, count=1)
    if n != 1 or new_value == text:
        raise LabError("%s: serverName line could not be replaced" % SERVER_VALUES)
    if not dry_run:
        tmp = fpath + ".customize.tmp"
        with open(tmp, "w", encoding="utf-8", newline="") as f:
            f.write(new_value)
        os.chmod(tmp, os.stat(fpath).st_mode & 0o777)
        os.replace(tmp, fpath)
    return 1


def check(repo, old, new_values, server_name=""):
    """Quiet check for the preflight: state = configuration, and the ssh addresses in gitops/ are correct."""
    problems = []
    problems.extend(server_name_problems(repo, server_name))
    for k in KEYS:
        if old[k] != new_values[k]:
            problems.append("%s: gitops/ has '%s', lab.yaml says '%s'" % (k, old[k], new_values[k]))
    if old[SECRETS] != new_values[SECRETS]:
        problems.append("%s: gitops/ has '%s', lab.yaml says '%s'" % (SECRETS, old[SECRETS], new_values[SECRETS]))
    if split_list(old[ITEMS]) != split_list(new_values[ITEMS]):
        problems.append("%s: gitops/ has '%s', lab.yaml says '%s'" % (ITEMS, old[ITEMS], new_values[ITEMS]))
    text = read_text(os.path.join(repo, TRAEFIK_VALUES))
    b = read_block(text) if text else None
    if b is None:
        problems.append("%s: markers for %s are missing" % (TRAEFIK_VALUES, ITEMS))
    elif b[2] != split_list(new_values[ITEMS]):
        problems.append("%s: loadBalancerSourceRanges %s, lab.yaml says %s" % (TRAEFIK_VALUES, b[2], split_list(new_values[ITEMS])))
    # Every ssh:// repo address in gitops/ must be the source (Argo CD, ApplicationSet);
    # the apps that read secrets/ use the secrets repo.
    sec = set(secrets_apps(repo))
    for rel in files(repo):
        if rel == STATE:
            continue
        text = read_text(os.path.join(repo, rel))
        if not text:
            continue
        want, key = (new_values[SECRETS], SECRETS) if rel in sec else (new_values["repo_url"], "repo_url")
        for m in re.finditer(r"^\s*(?:-\s+)?(?:repoURL|url):\s*(ssh://\S+)\s*$", text, re.M):
            if m.group(1) != want:
                problems.append("%s: repo address '%s' is not %s from lab.yaml" % (rel, m.group(1), key))
    # The domain must occur somewhere (otherwise state and content have drifted apart).
    found_items = False
    for rel in files(repo):
        if rel == STATE:
            continue
        text = read_text(os.path.join(repo, rel))
        if text and re.search(pattern(new_values["domain"], "name"), text):
            found_items = True
            break
    if not found_items:
        problems.append("domain: '%s' does not occur in gitops/ and zensical.toml" % new_values["domain"])
    return problems


def fingerprint(line):
    """SHA-256 fingerprint of a known_hosts line (host keytype key), '' if ssh-keygen cannot read it."""
    r = subprocess.run(["ssh-keygen", "-lf", "-", "-E", "sha256"], input=line + "\n", capture_output=True, text=True, check=False)
    m = re.search(r"\bSHA256:\S+", r.stdout)
    return m.group(0) if m else ""


def fetch_host_keys(url, local_file, yes, github=False):
    m = re.match(r"^ssh://(?:[^@/]+@)?([^:/]+)(?::(\d+))?/", url)
    if not m:
        raise LabError("repo_url not readable (expected ssh://git@HOST[:PORT]/PATH): %s" % url)
    host, port = m.group(1), m.group(2) or "22"
    if host.endswith("example.org") or "YOUR-NAME" in url:
        raise LabError("repo_url is still the placeholder: set repo_url in lab.local.yaml first.")
    key_name = "github_known_hosts" if github else "repo_known_hosts"
    if github and (host != "github.com" or port != "22"):
        raise LabError("github_repo_url must point at github.com on port 22 (is %s:%s)." % (host, port))
    types = "ed25519,ecdsa,rsa" if github else "ed25519,ecdsa"
    try:
        r = subprocess.run(["ssh-keyscan", "-T", "10", "-p", port, "-t", types, host], capture_output=True, text=True, check=False)
    except OSError as x:
        raise LabError("ssh-keyscan cannot be started: %s" % x)
    text_lines = [z for z in r.stdout.splitlines() if z and not z.startswith("#")]
    if r.returncode != 0 or not text_lines:
        raise LabError("ssh-keyscan returned no keys from %s:%s (network? VPN?)." % (host, port))
    print("Host keys of %s:%s (public parts only):" % (host, port))
    for z in text_lines:
        f = subprocess.run(["ssh-keygen", "-lf", "-"], input=z + "\n", capture_output=True, text=True, check=False)
        print("  " + (f.stdout.strip() or z.split()[1]))
    if github:
        bad = []
        for z in text_lines:
            parts = z.split()
            if len(parts) < 3 or GITHUB_FINGERPRINTS.get(parts[1]) != fingerprint(z):
                bad.append(parts[1] if len(parts) > 1 else "?")
        if bad:
            raise LabError("host key(s) of github.com do not match the fingerprints GitHub publishes (%s): nothing written. "
                           "Network in the way? Check docs.github.com, 'GitHub's SSH key fingerprints'." % ", ".join(bad))
        print("All %d keys match the fingerprints GitHub publishes (GITHUB_FINGERPRINTS in this script)." % len(text_lines))
    else:
        print("Compare the fingerprint with the one the Git server shows (or whatever else you trust).")
        print("Keys come from the network: an attacker on the path could swap them.")
    if not yes and not github:
        try:
            a = input("Enter into %s as repo_known_hosts? [y/N] " % local_file)
        except EOFError:
            a = "n"
        if a.strip().lower() not in ("y", "yes", "j", "yes"):
            print("ABORT: nothing written.")
            return 1
    line = "%s: [%s]\n" % (key_name, ", ".join('"%s"' % z for z in text_lines))
    old = ""
    if os.path.exists(local_file):
        with open(local_file, encoding="utf-8") as f:
            old = f.read()
    if re.search(r"^%s:" % key_name, old, re.M):
        new_values = re.sub(r"^%s:.*\n?" % key_name, lambda _: line, old, count=1, flags=re.M)
    else:
        new_values = old + ("" if old.endswith("\n") or not old else "\n") + line
    if new_values == old:
        print("SKIP: %s in %s is already like this." % (key_name, local_file))
        return 0
    os.makedirs(os.path.dirname(os.path.abspath(local_file)), exist_ok=True)
    tmp = local_file + ".new"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(new_values)
    if os.path.exists(local_file):
        os.chmod(tmp, os.stat(local_file).st_mode & 0o777)
    os.replace(tmp, local_file)
    print("EDIT: %s (%s, %d entries)" % (local_file, key_name, len(text_lines)))
    return 0


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True)
    ap.add_argument("--domain")
    ap.add_argument("--repo-url")
    ap.add_argument("--secrets-repo-url", help="repo of the apps with path secrets/..., default: --repo-url")
    ap.add_argument("--gateway")
    ap.add_argument("--vm-cidr")
    ap.add_argument("--vm-ip")
    ap.add_argument("--edge-ingress-cidrs", help="comma separated, default: --vm-cidr")
    ap.add_argument("--server-name", default="", help="Matrix server_name, pinned after the domain replacement")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--fetch-host-keys", action="store_true")
    ap.add_argument("--local-file")
    ap.add_argument("--yes", action="store_true")
    ap.add_argument("--github", action="store_true", help="with --fetch-host-keys: github.com, fingerprints checked, key github_known_hosts")
    a = ap.parse_args()
    repo = os.path.abspath(a.repo)
    try:
        if a.fetch_host_keys:
            if not a.repo_url or not a.local_file:
                raise LabError("--repo-url and --local-file are missing")
            return fetch_host_keys(a.repo_url, a.local_file, a.yes, a.github)
        new_values = {"domain": a.domain, "repo_url": a.repo_url, "gateway": a.gateway, "vm_cidr": a.vm_cidr, "vm_ip": a.vm_ip}
        empty = [k for k, v in new_values.items() if not v]
        if empty:
            raise LabError("values missing: %s" % ", ".join(empty))
        sp = os.path.join(repo, STATE)
        if not os.path.isfile(sp):
            raise LabError("%s is missing (is this a k8s-lab repo?)." % STATE)
        new_values[ITEMS] = a.edge_ingress_cidrs or a.vm_cidr
        new_values[SECRETS] = a.secrets_repo_url or a.repo_url
        if host_port(new_values[SECRETS]) is None:
            raise LabError("secrets_repo_url not readable (expected ssh://git@HOST[:PORT]/PATH): %s" % new_values[SECRETS])
        if host_port(a.repo_url) is None:
            raise LabError("repo_url not readable (expected ssh://git@HOST[:PORT]/PATH): %s" % a.repo_url)
        if host_port(new_values[SECRETS]) != host_port(a.repo_url):
            raise LabError("secrets_repo_url must use the same host and port as repo_url (%s:%s): the egress "
                           "policies allow one Git server (ADR 0022)." % host_port(a.repo_url))
        old = read_state(sp)
        if a.check:
            problems = check(repo, old, new_values, a.server_name)
            for p in problems:
                print("DEVIATION: " + p)
            return 1 if problems else 0
        result = rewrite(repo, old, new_values, a.dry_run)
        for rel, n in result:
            print("%s: %s (%d replacement(s))" % ("WOULD CHANGE" if a.dry_run else "EDIT", rel, n))
        sec_result = rewrite_secrets_apps(repo, new_values[SECRETS], a.dry_run)
        for rel, n in sec_result:
            print("%s: %s (%s, %d line(s))" % ("WOULD CHANGE" if a.dry_run else "EDIT", rel, SECRETS, n))
        result += sec_result
        block_changed = rewrite_block(repo, split_list(new_values[ITEMS]), a.dry_run)
        if block_changed:
            print("%s: %s (%s)" % ("WOULD CHANGE" if a.dry_run else "EDIT", TRAEFIK_VALUES, ITEMS))
        # After the domain replacement: it rewrites serverName whenever the identity contains
        # the lab domain. Pin the identity back so phase 2 can set a name outside that domain.
        pinned = apply_server_name(repo, a.server_name, a.dry_run)
        if pinned:
            print("%s: %s (serverName)" % ("WOULD CHANGE" if a.dry_run else "EDIT", SERVER_VALUES))
        if old == new_values:
            if not result and not block_changed and not pinned:
                print("SKIP: gitops/ already matches lab.yaml (state equals configuration).")
            return 0
        for k in KEYS + [ITEMS, SECRETS]:
            if old[k] != new_values[k]:
                print("%s: %s -> %s" % ("WOULD REPLACE" if a.dry_run else "REPLACED", k, new_values[k]))
        if a.dry_run:
            return 0
        tmp = sp + ".new"
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(state_text(new_values))
        os.replace(tmp, sp)
        print("EDIT: %s" % STATE)
        print("Next steps: review git diff, commit, push (Argo CD only reads the state on the Git server).")
        return 0
    except (LabError, OSError) as x:
        print("ABORT: %s" % x)
        return 1


if __name__ == "__main__":
    sys.exit(main())
