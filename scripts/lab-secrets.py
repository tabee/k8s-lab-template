#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
"""Secrets of the lab: map (never shows values), init (builds your own key ring)
and generate (creates single missing files, for Ansible).

Usage (called by scripts/lab.sh, source of the list: ansible/inventory/group_vars/all/secrets.yml):
  lab-secrets.py map    --json FILE
  lab-secrets.py init     --json FILE --repo REPO [--dry-run] [--new-age-key] [--yes]
                              [--break-glass | --break-glass-delete]
  lab-secrets.py generate --json FILE --name NAME [--name NAME ...]
  lab-secrets.py ca-rotation --json FILE --repo REPO [--dry-run] [--yes]
(FILE may be - : then the JSON comes from stdin.)

This is the ONLY place that creates secret files. The Ansible roles backup_s3 and
notes_sites call "generate" (ansible/tasks/secrets-generate.yml) instead of rolling
the dice themselves. File format and randomness source are therefore always the same.

ca-rotation replaces the lab CA with one with nameConstraints (runbook docs/how-to/ca-rotation.md,
section "Introduce a CA with nameConstraints"). It is the only command that replaces existing files:
first a backup to <directory of the CA>/ca-old-TIMESTAMP, only after [y/N], never a commit or push.

Rules: an existing file is never overwritten (SKIP). New files are created
with mode 0600 (directory 0700), via O_EXCL. Values are never printed. Plain text for
SOPS only goes through a pipe to ansible/scripts/sops-secret.sh from-json.
"""
import argparse
import base64
import glob
import json
import os
import re
import secrets
import stat
import string
import subprocess
import sys
import time

HOME = os.path.expanduser("~")
CHARS = string.ascii_letters + string.digits
LOWER = string.ascii_lowercase + string.digits
ABORT_COUNT = [0]
# age recipient (bech32: without 1, b, i, o in the data part). Anything else in .sops.yaml counts as a placeholder.
AGE_PUB = re.compile(r"^age1[02-9ac-hj-np-z]{58}$")


class LabError(Exception):
    pass


def short(fpath):
    if fpath == HOME:
        return "~"
    if fpath.startswith(HOME + "/"):
        return "~" + fpath[len(HOME):]
    return fpath


def report(status, text):
    print("%s: %s" % (status, text), flush=True)
    if status == "ABORT":
        ABORT_COUNT[0] += 1


def load_json(fpath):
    if fpath == "-":
        o = json.load(sys.stdin)
    else:
        with open(fpath, encoding="utf-8") as f:
            o = json.load(f)
    if isinstance(o, str):
        o = json.loads(o)
    return o


def mode_of(fpath):
    try:
        return stat.S_IMODE(os.stat(fpath).st_mode)
    except OSError:
        return None


# ------------------------------------------------------------------ Map
def print_map(payload):
    print("Secrets map (never shows values). Source: ansible/inventory/group_vars/all/secrets.yml")
    print("  Permissions: expected 600. ❌ = missing or wrong permissions.  ★ = put it into the password manager.")
    print()
    for e in payload["entries"]:
        fpath = e.get("path")
        if fpath:
            m = mode_of(fpath)
            if m is None and e["kind"] == "break-glass":
                perms = "- absent by design (optional; the file is deleted once the key is in the password manager)"
            elif m is None:
                perms = "❌ missing" + {"derived": " (created by up)", "external": " (optional, you create it yourself)"}.get(e["kind"], "")
            elif m != 0o600:
                perms = "❌ %o" % m
            else:
                perms = "600"
            where = short(fpath)
        else:
            perms = "- (cluster only)"
            where = "-"
        copy = e.get("copy") or ("wl-copy < %s" % where)
        star = " ★ password manager" if e.get("password_manager") else ""
        print("%s%s" % (e["name"], star))
        print("  Purpose:  %s" % e["purpose"])
        print("  Path:     %s" % where)
        print("  Perms:    %s" % perms)
        print("  Copy:     %s" % copy)
    print()


# ------------------------------------------------------------------ Files
def backup_dir(fpath, dry_run):
    missing_names = []
    p = os.path.dirname(fpath)
    while p and not os.path.isdir(p):
        missing_names.append(p)
        p = os.path.dirname(p)
    if dry_run:
        return
    for d in reversed(missing_names):
        os.mkdir(d, 0o700)
        os.chmod(d, 0o700)


def write_new(fpath, content, mode=0o600):
    """Creates a new file (O_EXCL: fails if it exists)."""
    fd = os.open(fpath, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
    try:
        os.fchmod(fd, mode)
        os.write(fd, content if isinstance(content, bytes) else content.encode())
    finally:
        os.close(fd)


def run(args, stdin_text=None, env=None):
    r = subprocess.run(args, input=stdin_text, capture_output=True, env=env, check=False)
    if r.returncode != 0:
        raise LabError("%s failed (exit %d): %s" % (args[0], r.returncode, r.stderr.decode(errors="replace").strip()[:300]))
    return r.stdout


def tool(name):
    for d in os.environ.get("PATH", "").split(os.pathsep):
        p = os.path.join(d, name)
        if os.path.isfile(p) and os.access(p, os.X_OK):
            return True
    return False


def random_string(length, alphabet=CHARS):
    return "".join(secrets.choice(alphabet) for _ in range(length))


# ------------------------------------------------------------------ Generate
def ca_name_constraint(domain):
    """nameConstraints of the lab CA (critical): only DNS names under the lab domain, no IP addresses.
    Clients (OpenSSL, Go, curl, browsers) reject every leaf outside it, even with a stolen CA key."""
    if not re.fullmatch(r"[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?", domain or ""):
        raise LabError("ca_domain %r is not a valid DNS name" % domain)
    return ("nameConstraints=critical,permitted;DNS:%s,excluded;IP:0.0.0.0/0.0.0.0,"
            "excluded;IP:0:0:0:0:0:0:0:0/0:0:0:0:0:0:0:0") % domain


def build_ca(e):
    """New lab CA in memory: (key PEM, certificate PEM). Writes nothing."""
    keymat = run(["openssl", "genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256"])
    cert = run(["openssl", "req", "-x509", "-new", "-key", "/dev/stdin", "-sha256", "-days", "3650",
                 "-subj", "/CN=%s" % e["ca_cn"],
                 "-addext", "basicConstraints=critical,CA:TRUE",
                 "-addext", "keyUsage=critical,keyCertSign,cRLSign",
                 "-addext", "subjectKeyIdentifier=hash",
                 "-addext", ca_name_constraint(e.get("ca_domain"))], stdin_text=keymat)
    return keymat, cert


def ca_secret_text(e, cert, keymat):
    b = lambda x: base64.b64encode(x).decode()
    return ("apiVersion: v1\nkind: Secret\nmetadata:\n  name: %s\n  namespace: %s\ntype: kubernetes.io/tls\ndata:\n"
            "  ca.crt: %s\n  tls.crt: %s\n  tls.key: %s\n") % (e["ca_name"], e["ca_namespace"], b(cert), b(cert), b(keymat))


def generate_entry(e, result):
    """Creates the file of entry e. Returns a note text (public only) or None."""
    kind, fpath = e["kind"], e["path"]
    if kind == "age":
        if not tool("age-keygen"):
            raise LabError("age-keygen is missing (sudo apt install age).")
        run(["age-keygen", "-o", fpath])
        os.chmod(fpath, 0o600)
    elif kind == "ca":
        keymat, cert = build_ca(e)
        text = ca_secret_text(e, cert, keymat)
        write_new(fpath, text)
        op = e.get("public_path")
        if op and not os.path.lexists(op):
            backup_dir(op, False)
            write_new(op, cert, 0o644)
    elif kind == "pw":
        write_new(fpath, random_string(int(e.get("length", 32))))
    elif kind == "text":
        write_new(fpath, e["content"])
    elif kind == "rustfs":
        text = ("# rustfs root key, created by lab-secrets.py (lab.sh init or backup-host.yml).\n"
                "# RUSTFS_ADDRESS is set by the Quadlet file (Environment= wins).\n"
                "RUSTFS_ACCESS_KEY=root-%s\nRUSTFS_SECRET_KEY=%s\nRUSTFS_ADDRESS=:9000\nRUSTFS_CONSOLE_ENABLE=true\n"
                % (random_string(12, LOWER), random_string(40)))
        write_new(fpath, text)
    elif kind == "s3env":
        text = ("# S3 access, bucket %s only (created by lab-secrets.py: lab.sh init or backup-host.yml).\n"
                "# Endpoint: %s  Bucket: %s\n"
                "# Next: lab.sh init renders the SOPS files from it (secrets/**, templates *.example).\n"
                "ACCESS_KEY_ID=%s\nACCESS_SECRET_KEY=%s\n"
                % (e["s3_bucket"], e["s3_endpoint"], e["s3_bucket"], e["s3_user"], random_string(40)))
        write_new(fpath, text)
    elif kind == "ssh":
        if os.path.lexists(fpath + ".pub"):
            raise LabError("%s.pub exists without the private key; neither delete nor overwrite it, please check." % fpath)
        old = os.umask(0o077)
        try:
            run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", e["comment"], "-f", fpath])
        finally:
            os.umask(old)
        os.chmod(fpath, 0o600)
    elif kind == "wireguard":
        # Private key file + sibling .pub (wg pubkey). Never print either value.
        if os.path.lexists(fpath + ".pub") and not os.path.lexists(fpath):
            raise LabError("%s.pub exists without the private key; neither delete nor overwrite it, please check." % fpath)
        if not tool("wg"):
            raise LabError("wg is missing (sudo apt install wireguard-tools).")
        old_umask = os.umask(0o077)
        try:
            priv = run(["wg", "genkey"])
            if not priv.endswith(b"\n"):
                priv = priv + b"\n"
            write_new(fpath, priv)
            os.chmod(fpath, 0o600)
            pub = run(["wg", "pubkey"], stdin_text=priv)
            if not pub.endswith(b"\n"):
                pub = pub + b"\n"
            write_new(fpath + ".pub", pub, 0o644)
        finally:
            os.umask(old_umask)
    else:
        raise LabError("Kind %s is not generated." % kind)


GENERATE_KINDS = ("pw", "text", "rustfs", "s3env", "ssh", "wireguard")


def generate(payload, names):
    """Creates the named files, only if they are missing (otherwise SKIP). For Ansible.
    age and ca belong to init (they depend on .sops.yaml and the CA storage)."""
    entries = {x["name"]: x for x in payload["entries"]}
    for n in names:
        e = entries.get(n)
        if e is None:
            report("ABORT", "%s: no such entry in the list of secrets" % n)
            continue
        if e["kind"] not in GENERATE_KINDS:
            report("ABORT", "%s: kind %s is not created by generate (only %s)" % (n, e["kind"], ", ".join(GENERATE_KINDS)))
            continue
        fpath = e["path"]
        if os.path.lexists(fpath):
            report("SKIP", "%s %s present" % (n, short(fpath)))
            continue
        try:
            backup_dir(fpath, False)
            generate_entry(e, None)
        except (LabError, OSError) as x:
            report("ABORT", "%s: %s" % (n, x))
            continue
        report("NEW", "%s %s (mode 600, value not shown)" % (n, short(fpath)))


def pub_text(fpath):
    try:
        with open(fpath + ".pub", encoding="utf-8") as f:
            return f.read().strip()
    except OSError:
        return None


# ------------------------------------------------------------------ Templates
def read_template(fpath):
    """Mini parser for *.sops.yaml.example (only the form used there)."""
    meta = {"labels": {}, "annotations": {}}
    obj = {"stype": "Opaque", "values": []}
    section = under = None
    with open(fpath, encoding="utf-8") as f:
        text_lines = f.read().splitlines()
    for nr, z in enumerate(text_lines, 1):
        if not z.strip() or z.lstrip().startswith("#"):
            continue
        indent = len(z) - len(z.lstrip(" "))
        m = re.match(r"^([^:\s]+):(?:\s+(.*))?$", z.strip())
        if not m:
            raise LabError("%s line %d not readable" % (fpath, nr))
        k, v = m.group(1), (m.group(2) or "").strip()
        if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
            v = v[1:-1]
        if indent == 0:
            section, under = k, None
            if k == "type":
                obj["stype"] = v
        elif section == "metadata" and indent == 2:
            if v == "":
                under = k
            else:
                under = None
                meta[k] = v
        elif section == "metadata" and indent == 4 and under in ("labels", "annotations"):
            meta[under][k] = v
        elif section == "stringData" and indent == 2:
            obj["values"].append((k, v))
        else:
            raise LabError("%s line %d: unexpected structure" % (fpath, nr))
    if "name" not in meta or "namespace" not in meta or not obj["values"]:
        raise LabError("%s: name, namespace and stringData are required" % fpath)
    obj["meta"] = meta
    return obj


class SOURCES:
    def __init__(self, entries):
        self.e = {x["name"]: x for x in entries}
        self.cache = {}

    def entry_of(self, name):
        if name not in self.e or not self.e[name].get("path"):
            raise LabError("placeholder refers to unknown entry %s" % name)
        return self.e[name]

    def fpath(self, name):
        return self.entry_of(name)["path"]

    def _read(self, name):
        p = self.fpath(name)
        if not os.path.isfile(p):
            raise LabError("%s is missing" % short(p))
        m = mode_of(p)
        if m != 0o600:
            raise LabError("%s has mode %o, expected 600 (chmod 600 %s)" % (short(p), m, short(p)))
        with open(p, "rb") as f:
            return f.read()

    def file(self, name):
        b = self._read(name)
        if b.endswith(b"\n"):
            b = b[:-1]
        if not b or b"\n" in b:
            raise LabError("%s must contain exactly one non-empty line" % short(self.fpath(name)))
        return b

    def optional(self, name):
        """Like file, but a missing or empty file yields an empty value (SOPS placeholder in Git)."""
        p = self.fpath(name)
        if not os.path.isfile(p):
            return b""
        m = mode_of(p)
        if m != 0o600:
            raise LabError("%s has mode %o, expected 600 (chmod 600 %s)" % (short(p), m, short(p)))
        with open(p, "rb") as f:
            b = f.read()
        if b.endswith(b"\n"):
            b = b[:-1]
        if b"\n" in b:
            raise LabError("%s may contain at most one line" % short(p))
        return b

    def env(self, name, key):
        if ("env", name) not in self.cache:
            d = {}
            for nr, z in enumerate(self._read(name).decode().split("\n"), 1):
                if not z.strip() or z.lstrip().startswith("#"):
                    continue
                m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$", z)
                if not m or m.group(1) in d:
                    raise LabError("%s line %d: expected KEY=VALUE" % (short(self.fpath(name)), nr))
                d[m.group(1)] = m.group(2).encode()
            self.cache[("env", name)] = d
        d = self.cache[("env", name)]
        if key not in d:
            raise LabError("%s does not contain %s" % (short(self.fpath(name)), key))
        return d[key]

    def ca(self, name, key):
        if ("ca", name) not in self.cache:
            d = {}
            for z in self._read(name).decode().split("\n"):
                m = re.match(r"^  (ca\.crt|tls\.crt|tls\.key): (\S+)$", z)
                if m:
                    d[m.group(1)] = base64.b64decode(m.group(2))
            self.cache[("ca", name)] = d
        d = self.cache[("ca", name)]
        if key not in d:
            raise LabError("%s does not contain %s (expected ca.crt, tls.crt, tls.key)" % (short(self.fpath(name)), key))
        return d[key]

    def value(self, raw):
        if not raw.startswith("@"):
            return raw.encode()
        parts = raw[1:].split(":")
        if parts[0] == "file" and len(parts) == 2:
            return self.file(parts[1])
        if parts[0] == "optional" and len(parts) == 2:
            return self.optional(parts[1])
        if parts[0] == "env" and len(parts) == 3:
            return self.env(parts[1], parts[2])
        if parts[0] == "ca" and len(parts) == 3:
            return self.ca(parts[1], parts[2])
        raise LabError("Placeholder %s unknown" % raw)

    def sources_of(self, template):
        names = []
        for _, raw in template["values"]:
            if raw.startswith("@") and not raw.startswith("@optional:"):
                n = raw[1:].split(":")[1]
                if n not in names:
                    names.append(n)
        return names


def secret_json(template, sources):
    data = {}
    for k, raw in template["values"]:
        data[k] = base64.b64encode(sources.value(raw)).decode()
    m = template["meta"]
    meta = {"name": m["name"], "namespace": m["namespace"], "labels": m["labels"], "annotations": m["annotations"]}
    return json.dumps({"apiVersion": "v1", "kind": "Secret", "metadata": meta, "type": template["stype"], "data": data})


# ------------------------------------------------------------------ age and .sops.yaml
def age_pubs(fpath):
    pubs = []
    try:
        with open(fpath, encoding="utf-8") as f:
            for z in f:
                m = re.match(r"^# public key: (age1[0-9a-z]+)\s*$", z)
                if m:
                    pubs.append(m.group(1))
    except OSError:
        return []
    if not pubs and tool("age-keygen"):
        try:
            pubs = [x for x in run(["age-keygen", "-y", fpath]).decode().split() if x.startswith("age1")]
        except LabError:
            pubs = []
    return pubs


def sops_recipients(sops_yaml):
    """Returns (lines, index of the age line, list of recipients)."""
    with open(sops_yaml, encoding="utf-8") as f:
        text_lines = f.read().split("\n")
    idx = [i for i, z in enumerate(text_lines) if re.match(r"^\s+age:\s", z)]
    if len(idx) != 1:
        raise LabError(".sops.yaml: exactly one line 'age: ...' expected, found %d" % len(idx))
    value = re.sub(r"^\s+age:\s*", "", text_lines[idx[0]]).strip()
    if value.startswith(">") or value.startswith("|") or value == "":
        raise LabError(".sops.yaml: age: over several lines is not changed automatically (please do it by hand)")
    return text_lines, idx[0], [x.strip() for x in value.split(",") if x.strip()]


def ask(text, yes):
    if yes:
        return True
    if not sys.stdin.isatty():
        return False
    try:
        print("%s [y/N] " % text, end="", flush=True)
        a = input()
    except EOFError:
        return False
    return a in ("y", "Y", "j", "J")


# ------------------------------------------------------------------ CA-Rotation
def ca_has_constraint(cert, domain):
    """True if the certificate has critical nameConstraints with permitted DNS:domain."""
    r = subprocess.run(["openssl", "x509", "-noout", "-ext", "nameConstraints"], input=cert, capture_output=True, check=False)
    t = r.stdout.decode(errors="replace")
    return r.returncode == 0 and "Name Constraints: critical" in t and re.search(r"Permitted:\s*DNS:%s\s*$" % re.escape(domain), t.split("Excluded:")[0], re.M) is not None


def ca_rotation(payload, repo, dry_run, yes):
    """Replace the old lab CA without nameConstraints with a new one with nameConstraints (host files and SOPS file)."""
    entries = payload["entries"]
    e = next((x for x in entries if x["kind"] == "ca"), None)
    if e is None:
        raise LabError("no entry with kind ca in the list of secrets")
    os.chdir(repo)
    fpath, op = e["path"], e.get("public_path")
    if not os.path.isfile(fpath):
        raise LabError("%s is missing (run lab.sh init first)" % short(fpath))
    q = SOURCES(entries)
    old_cert = q.ca(e["name"], "tls.crt")
    if ca_has_constraint(old_cert, e.get("ca_domain") or ""):
        report("SKIP", "%s already has critical nameConstraints (permitted DNS:%s), no rotation needed" % (short(fpath), e["ca_domain"]))
        return
    ca_name_constraint(e.get("ca_domain"))  # checks the domain before anything is touched
    # SOPS file of the CA: the template that uses @ca:<name>:
    sops_target = sops_template = None
    for vp in sorted(glob.glob(os.path.join("secrets", "**", "*.sops.yaml.example"), recursive=True)):
        v = read_template(vp)
        if any(raw.startswith("@ca:%s:" % e["name"]) for _, raw in v["values"]):
            sops_target, sops_template = vp[: -len(".example")], v
            break
    stamp = time.strftime("%Y%m%d-%H%M%S")
    backup_path = os.path.join(os.path.dirname(fpath), "ca-old-" + stamp)
    has_sops = bool(sops_target and os.path.isfile(sops_target))
    plan = ["back up the old CA to %s (host files%s)" % (short(backup_path), " and SOPS file" if has_sops else ""),
            "write the new CA with nameConstraints (permitted DNS:%s) to %s%s" % (e["ca_domain"], short(fpath), " and " + short(op) if op else "")]
    if sops_target:
        plan.append("re-encrypt %s %s" % (sops_target, "" if has_sops else "(still missing, created by lab.sh init)"))
    if dry_run:
        for z in plan:
            report("WOULD", z)
        return
    print("WARNING: The lab CA is being replaced. All certificates of the old CA become invalid as soon as Argo CD has the new CA in the cluster.")
    for z in plan:
        print("  - " + z)
    if not ask("Rotate the lab CA now?", yes):
        report("ABORT", "no confirmation, nothing changed")
        return
    keymat, cert = build_ca(e)
    if not ca_has_constraint(cert, e["ca_domain"]):
        raise LabError("the new CA has no nameConstraints (openssl too old?), nothing changed")
    new_path = fpath + ".new"
    new_op = (op + ".new") if op else None
    for t in (new_path, new_op, backup_path):
        if t and os.path.lexists(t):
            raise LabError("%s already exists (leftover of an earlier run?), please check and remove it by hand" % short(t))
    os.mkdir(backup_path, 0o700)
    os.chmod(backup_path, 0o700)
    backups = [(fpath, os.path.join(backup_path, os.path.basename(fpath)))]
    if op and os.path.isfile(op):
        backups.append((op, os.path.join(backup_path, os.path.basename(op))))
    if has_sops:
        backups.append((sops_target, os.path.join(backup_path, os.path.basename(sops_target))))
    for source, target in backups:
        with open(source, "rb") as f:
            write_new(target, f.read(), mode_of(source) or 0o600)
    report("BACKED UP", "old CA in %s (%d file(s))" % (short(backup_path), len(backups)))
    write_new(new_path, ca_secret_text(e, cert, keymat))
    if new_op:
        write_new(new_op, cert, 0o644)
    os.replace(new_path, fpath)
    if new_op:
        os.replace(new_op, op)
    report("REPLACED", "%s%s (new CA, value not shown)" % (short(fpath), " and " + short(op) if op else ""))
    if sops_target:
        if has_sops:
            os.unlink(sops_target)  # the backup is above, Git also holds the old version
        age_e = next(x for x in entries if x["kind"] == "age")
        js = secret_json(sops_template, SOURCES(entries))
        r = subprocess.run(["bash", os.path.join("ansible", "scripts", "sops-secret.sh"), "from-json", sops_target],
                           input=js.encode(), capture_output=True, env=sops_env(age_e["path"]), check=False)
        if r.returncode != 0:
            for source, target in backups:  # put everything back
                with open(target, "rb") as f:
                    content = f.read()
                if os.path.lexists(source):
                    os.unlink(source)
                write_new(source, content, mode_of(target) or 0o600)
            errors = [z for z in (r.stdout + r.stderr).decode(errors="replace").splitlines() if z.startswith(("ABORT", "Failed", "Error"))][:3]
            raise LabError("SOPS file not created (%s). Everything put back from %s." % (" | ".join(errors) or "sops-secret.sh", short(backup_path)))
        report("CREATED", "%s (encrypted, new CA)" % sops_target)
    print()
    print("Next (docs/how-to/ca-rotation.md):")
    print("  1. Remove the old CA from the trust stores, add the new one (ansible/scripts/lab-ca-trust.sh remove/add).")
    print("  2. git add %s, commit, push. Argo CD creates the new CA secret." % (sops_target or "secrets"))
    print("  3. ansible-playbook argocd.yml (stores the new lab-ca.crt), then have the server certificates reissued.")
    print("  The old CA is in %s. Delete it only when everything is green." % short(backup_path))


# ------------------------------------------------------------------ init
def sops_env(age_path):
    env = dict(os.environ)
    env["SOPS_AGE_KEY_FILE"] = age_path
    return env


def restore(templates, q, entries, env, dry_run):
    """Restore missing host files from existing SOPS files that can be decrypted."""
    is_missing = lambda name: not os.path.lexists(q.fpath(name))
    collected = {}  # ("file", name) -> bytes ; ("env", name) -> {key: bytes}; ("ca", name) -> {key: bytes}
    for vpfad, v in templates:
        target = vpfad[: -len(".example")]
        if not os.path.isfile(target):
            continue
        pending = [n for n in q.sources_of(v) if is_missing(n)]
        if not pending:
            continue
        if dry_run:
            for n in pending:
                report("WOULD RESTORE", "%s from %s (if decryptable)" % (short(q.fpath(n)), target))
            continue
        try:
            plain = json.loads(run(["sops", "decrypt", "--input-type", "yaml", "--output-type", "json", target], env=env))
        except LabError:
            report("NOTE", "%s cannot be decrypted (other key), values are not read from it" % target)
            continue
        payload = {k: base64.b64decode(x) for k, x in (plain.get("data") or {}).items()}
        for k, raw in v["values"]:
            if not raw.startswith("@") or raw.startswith("@optional:") or k not in payload:
                continue
            t = raw[1:].split(":")
            if t[0] == "file":
                collected[("file", t[1])] = payload[k]
            else:
                collected.setdefault((t[0], t[1]), {})[t[2]] = payload[k]
    if dry_run:
        return
    for (kind, name), value in collected.items():
        e = q.entry_of(name)
        fpath = e["path"]
        if os.path.lexists(fpath):
            continue
        backup_dir(fpath, False)
        if kind == "file":
            write_new(fpath, value)
        elif kind == "env":
            if not {"ACCESS_KEY_ID", "ACCESS_SECRET_KEY"} <= set(value):
                continue
            write_new(fpath, "# S3 access, restored from the SOPS file (lab.sh init).\nACCESS_KEY_ID=%s\nACCESS_SECRET_KEY=%s\n"
                      % (value["ACCESS_KEY_ID"].decode(), value["ACCESS_SECRET_KEY"].decode()))
        elif kind == "ca":
            if not {"ca.crt", "tls.crt", "tls.key"} <= set(value):
                continue
            b = lambda x: base64.b64encode(x).decode()
            write_new(fpath, "apiVersion: v1\nkind: Secret\nmetadata:\n  name: %s\n  namespace: %s\ntype: kubernetes.io/tls\ndata:\n"
                      "  ca.crt: %s\n  tls.crt: %s\n  tls.key: %s\n" % (e["ca_name"], e["ca_namespace"], b(value["ca.crt"]), b(value["tls.crt"]), b(value["tls.key"])))
            op = e.get("public_path")
            if op and not os.path.lexists(op):
                backup_dir(op, False)
                write_new(op, value["tls.crt"], 0o644)
        else:
            continue
        report("RESTORED", "%s %s (from the decrypted SOPS file, value not shown)" % (e["name"], short(fpath)))


# ------------------------------------------------------------------ break-glass recipient (offline age key)
# Convention: the LAST age recipient in .sops.yaml is the offline break-glass key. The key that
# lives in the cluster (argocd/sops-age) is never the last one. The private break-glass key is
# written once by age-keygen itself into a 0600 file and is never read, printed or logged here.
BG_FILE_NOTE = (
    "\n# k8s-lab break-glass key (offline recipient).\n"
    "# Put this file's content into your password manager, then delete this file:\n"
    "#   bash scripts/lab.sh init --break-glass-delete\n"
    "# Never copy it into the cluster, the repo or ~/.config/sops/age/.\n"
)


def short_pub(pub):
    return pub[:12] + "..."


def sops_data_files():
    return sorted(glob.glob(os.path.join("secrets", "**", "*.sops.yaml"), recursive=True))


def file_recipients(path):
    """Recipients listed in the (public) sops metadata of an encrypted file. No decryption."""
    with open(path, encoding="utf-8") as f:
        return re.findall(r"recipient:\s*(age1[0-9a-z]+)", f.read())


def write_age_line(sops_yaml, lines, idx, recipients):
    lines = list(lines)
    lines[idx] = re.sub(r"(age:\s*).*$", lambda m: m.group(1) + ",".join(recipients), lines[idx])
    tmp = sops_yaml + ".neu"
    write_new(tmp, "\n".join(lines), 0o644)
    os.replace(tmp, sops_yaml)


def break_glass_reencrypt(recipients, env, dry_run):
    """sops updatekeys for every secrets/**/*.sops.yaml whose recipients differ from .sops.yaml."""
    todo = []
    for f in sops_data_files():
        if set(file_recipients(f)) != set(recipients):
            todo.append(f)
        else:
            report("SKIP", "%s already has the recipients of .sops.yaml" % f)
    for f in todo:
        if dry_run:
            report("WOULD CHANGE", "%s: re-encrypt for %d recipients (sops updatekeys)" % (f, len(recipients)))
            continue
        r = subprocess.run(["sops", "--config", ".sops.yaml", "updatekeys", "--yes", f], env=env, capture_output=True, check=False)
        if r.returncode != 0:
            first = (r.stderr.decode(errors="replace").strip().splitlines() or ["no message"])[0][:200]
            report("ABORT", "%s: sops updatekeys failed (%s). Nothing else was changed." % (f, first))
            continue
        if set(file_recipients(f)) != set(recipients):
            report("ABORT", "%s: recipients still differ after sops updatekeys" % f)
            continue
        report("CREATED", "%s re-encrypted for %d recipients (values not shown)" % (f, len(recipients)))


def break_glass_setup(entries, sops_yaml, age_e, env, dry_run):
    entry = next((x for x in entries if x["kind"] == "break-glass"), None)
    if entry is None:
        report("ABORT", "no entry with kind break-glass in the secrets list")
        return
    bg_path = entry["path"]
    if not tool("age-keygen") or not tool("sops"):
        report("ABORT" if not dry_run else "NOTE", "age-keygen and sops are required for --break-glass")
        return
    try:
        lines, idx, recipients = sops_recipients(sops_yaml)
    except LabError as x:
        report("ABORT", str(x))
        return
    own = age_pubs(age_e["path"])
    if not own or not any(p in recipients for p in own):
        report("NOTE" if dry_run else "ABORT", "break-glass: your online age key is not a recipient in .sops.yaml. Run init first (or with --new-age-key).")
        return
    if len(recipients) >= 2:
        report("SKIP", ".sops.yaml already has %d recipients; the last one (%s) is the break-glass recipient" % (len(recipients), short_pub(recipients[-1])))
        if os.path.lexists(bg_path):
            report("NOTE", "key file %s still exists: put it into your password manager, then run: bash scripts/lab.sh init --break-glass-delete" % short(bg_path))
        break_glass_reencrypt(recipients, env, dry_run)
        return
    reuse = os.path.lexists(bg_path)
    pub = None
    if reuse:
        found = age_pubs(bg_path)
        pub = found[0] if found else None
        if pub is None:
            report("ABORT", "%s exists but its public key cannot be read. Nothing was changed." % short(bg_path))
            return
        if pub in own:
            report("ABORT", "%s holds your online key. Refusing to use it as break-glass key." % short(bg_path))
            return
        report("NOTE", "reusing existing key file %s (public key %s)" % (short(bg_path), short_pub(pub)))
    elif dry_run:
        report("WOULD CREATE", "break-glass key pair %s (mode 600, private part never shown)" % short(bg_path))
        report("WOULD CHANGE", ".sops.yaml: add the break-glass public key as second recipient")
        break_glass_reencrypt(recipients + ["age1dryrun"], env, True)
        return
    else:
        try:
            backup_dir(bg_path, False)
            r = subprocess.run(["age-keygen", "-o", bg_path], capture_output=True, check=False)
        except OSError as x:
            report("ABORT", "break-glass: %s" % x)
            return
        if r.returncode != 0:
            report("ABORT", "age-keygen failed: %s" % (r.stderr.decode(errors="replace").strip().splitlines() or ["no message"])[0][:200])
            return
        m = re.search(r"Public key:\s*(age1[0-9a-z]+)", r.stderr.decode(errors="replace"))
        pub = m.group(1) if m else None
        os.chmod(bg_path, 0o600)
        with open(bg_path, "a", encoding="utf-8") as f:
            f.write(BG_FILE_NOTE)
        if pub is None:
            found = age_pubs(bg_path)
            pub = found[0] if found else None
        if pub is None:
            report("ABORT", "break-glass: public key not readable after generation. Nothing else was changed.")
            return
        report("CREATED", "break-glass key %s (mode 600, private part not shown)" % short(bg_path))
    if dry_run:
        report("WOULD CHANGE", ".sops.yaml: add %s as second recipient" % short_pub(pub))
        break_glass_reencrypt(recipients + [pub], env, True)
        return
    n = len(sops_data_files())
    print("Plan: add recipient %s as second (last) recipient in .sops.yaml and re-encrypt %d file(s)." % (short_pub(pub), n))
    # The flag --break-glass is the confirmation. Reversible: .sops.yaml and secrets/ are tracked by git
    # (git checkout restores them), and a rerun of the command continues with the existing key file.
    write_age_line(sops_yaml, lines, idx, recipients + [pub])
    report("CREATED", ".sops.yaml: break-glass recipient %s added (last recipient)" % short_pub(pub))
    break_glass_reencrypt(recipients + [pub], env, False)
    print()
    print("NEXT STEPS (the private key was never printed):")
    print("  1. Put the key into your password manager:  wl-copy < %s" % short(bg_path))
    print("  2. Delete the file:                          bash scripts/lab.sh init --break-glass-delete")
    print("  3. git add .sops.yaml secrets && commit && push, then ansible-playbook verify-ksops.yml")


def break_glass_delete(entries, sops_yaml, dry_run):
    """Delete the local break-glass key file. Always needs a typed confirmation (--yes does not skip it)."""
    entry = next((x for x in entries if x["kind"] == "break-glass"), None)
    if entry is None:
        report("ABORT", "no entry with kind break-glass in the secrets list")
        return
    bg_path = entry["path"]
    if not os.path.lexists(bg_path):
        report("SKIP", "no break-glass key file at %s (nothing to delete)" % short(bg_path))
        return
    try:
        _lines, _idx, recipients = sops_recipients(sops_yaml)
    except LabError as x:
        report("ABORT", str(x))
        return
    pubs = age_pubs(bg_path)
    if not pubs or pubs[0] not in recipients[1:]:
        report("ABORT", "the public key of %s is not a break-glass recipient in .sops.yaml. Refusing to delete." % short(bg_path))
        return
    missing = [f for f in sops_data_files() if pubs[0] not in file_recipients(f)]
    if missing:
        report("ABORT", "%d secret file(s) are not encrypted for the break-glass key yet (e.g. %s). Run init --break-glass first." % (len(missing), missing[0]))
        return
    if dry_run:
        report("WOULD DELETE", "%s (after a typed confirmation)" % short(bg_path))
        return
    if not sys.stdin.isatty():
        report("ABORT", "deleting the break-glass key needs an interactive confirmation (no terminal). Nothing was deleted.")
        return
    print("This deletes %s. After that the break-glass key exists ONLY where you stored it." % short(bg_path))
    print("Open your password manager now and make sure the key is there and readable.")
    print("Type  delete  to confirm: ", end="", flush=True)
    try:
        answer = input().strip()
    except EOFError:
        answer = ""
    if answer != "delete":
        report("ABORT", "not confirmed. Nothing was deleted.")
        return
    size = os.path.getsize(bg_path)
    with open(bg_path, "r+b") as f:
        f.write(b"\0" * size)
        f.flush()
        os.fsync(f.fileno())
    os.remove(bg_path)
    report("DELETED", "%s (the key now lives only in your password manager)" % short(bg_path))


def init(payload, repo, dry_run, new_key, yes, break_glass=False):
    entries = payload["entries"]
    q = SOURCES(entries)
    os.chdir(repo)
    sops_yaml = os.path.join(repo, ".sops.yaml")
    if not os.path.isfile(sops_yaml) or not os.path.isdir(os.path.join(repo, "secrets")):
        raise LabError("%s is not a k8s-lab repo (.sops.yaml or secrets/ is missing)" % repo)
    age_e = next(x for x in entries if x["kind"] == "age")
    env = sops_env(age_e["path"])
    new_ssh = []

    def back_up(e):
        fpath = e["path"]
        if os.path.lexists(fpath):
            m = mode_of(fpath)
            extra = "" if m == 0o600 else " (NOTE: permissions %o, expected 600, not touched)" % (m or 0)
            report("SKIP", "%s %s present%s" % (e["name"], short(fpath), extra))
            return
        if dry_run:
            report("WOULD CREATE", "%s %s (%s)" % (e["name"], short(fpath), e["kind"]))
            return
        try:
            backup_dir(fpath, False)
            generate_entry(e, None)
        except (LabError, OSError) as x:
            report("ABORT", "%s: %s" % (e["name"], x))
            return
        report("CREATED", "%s %s (mode 600, value not shown)" % (e["name"], short(fpath)))
        if e["kind"] == "ssh":
            new_ssh.append(e)

    # 1. age key first (restoring and encrypting need it)
    back_up(age_e)

    # 2. templates and restore
    templates = []
    for p in sorted(glob.glob(os.path.join("secrets", "**", "*.sops.yaml.example"), recursive=True)):
        templates.append((p, read_template(p)))
    if not templates:
        raise LabError("no secrets/**/*.sops.yaml.example found")
    if os.path.isfile(age_e["path"]):
        restore(templates, q, entries, env, dry_run)

    # 3. all further files (only if they are missing)
    for e in entries:
        if e["kind"] in ("age", "cluster", "derived", "external", "break-glass", "wireguard"):
            continue
        back_up(e)

    # 4. .sops.yaml: recipients
    pubs = age_pubs(age_e["path"])
    try:
        text_lines, idx, rcpts = sops_recipients(sops_yaml)
    except LabError as x:
        report("ABORT", str(x))
        return
    own_keys = [p for p in pubs if p in rcpts]
    # Fresh from the public repo: .sops.yaml carries a placeholder instead of a key.
    # Then there is nothing to lose, your own key is entered without a question.
    placeholder = not any(AGE_PUB.match(x) for x in rcpts)
    if own_keys:
        report("SKIP", ".sops.yaml: your age key is a recipient")
    elif placeholder and pubs:
        if dry_run:
            report("WOULD CHANGE", ".sops.yaml: replace the placeholder with your age key (%s...)" % pubs[0][:12])
        else:
            text_lines[idx] = re.sub(r"(age:\s*).*$", lambda m: m.group(1) + pubs[0], text_lines[idx])
            tmp = sops_yaml + ".neu"
            write_new(tmp, "\n".join(text_lines), 0o644)
            os.replace(tmp, sops_yaml)
            own_keys = [pubs[0]]
            report("CREATED", ".sops.yaml: placeholder replaced, the recipient is now your age key")
    elif new_key:
        if not pubs:
            report("WOULD CHANGE" if dry_run else "ABORT", ".sops.yaml: public key not readable yet (key file is missing)")
        elif dry_run:
            report("WOULD CHANGE", ".sops.yaml: replace recipient %s with %s" % (",".join(x[:12] + "..." for x in rcpts), pubs[0][:12] + "..."))
        else:
            print("WARNING: .sops.yaml has recipient %s. --new-age-key replaces it with yours (%s...)." % (",".join(x[:12] + "..." for x in rcpts), pubs[0][:12]))
            print("         Already encrypted secrets/**/*.sops.yaml for the old key then stay unreadable (init reports them, never deletes).")
            if not ask("Replace the recipient in .sops.yaml?", yes):
                report("ABORT", ".sops.yaml not changed (no confirmation)")
            else:
                text_lines[idx] = re.sub(r"(age:\s*).*$", lambda m: m.group(1) + pubs[0], text_lines[idx])
                tmp = sops_yaml + ".neu"
                write_new(tmp, "\n".join(text_lines), 0o644)
                os.replace(tmp, sops_yaml)
                own_keys = [pubs[0]]
                report("CREATED", ".sops.yaml: the recipient is now your age key")
    else:
        report("NOTE", ".sops.yaml: your age key is not a recipient. New SOPS files would be unreadable for you. Enter it with --new-age-key.")

    # 5. render SOPS files
    if not tool("sops"):
        report("ABORT" if not dry_run else "NOTE", "sops is missing (sudo apt install sops or a release from github.com/getsops/sops)")
        return
    rendered_new = 0
    for vpfad, v in templates:
        target = vpfad[: -len(".example")]
        if os.path.isfile(age_e["path"]) is False and not dry_run:
            report("ABORT", "%s: age key is missing" % target)
            continue
        try:
            js = secret_json(v, q)
        except LabError as x:
            if dry_run and not os.path.isfile(target):
                report("WOULD CREATE", "%s (sources are only created later: %s)" % (target, x))
            elif dry_run:
                report("NOTE", "%s: comparison not possible (%s)" % (target, x))
            else:
                report("ABORT", "%s: %s" % (target, x))
            continue
        if not os.path.isfile(target) and not own_keys and not dry_run:
            report("ABORT", "%s: your age key is not a recipient in .sops.yaml (--new-age-key)" % target)
            continue
        args = ["bash", os.path.join("ansible", "scripts", "sops-secret.sh"), "from-json", target]
        if dry_run:
            args.append("--check")
        r = subprocess.run(args, input=js.encode(), capture_output=True, env=env, check=False)
        output = (r.stdout + r.stderr).decode(errors="replace").strip()
        for z in output.splitlines():
            if z.startswith("new:"):
                rendered_new += 1
                report("CREATED", z[4:].strip())
            elif z.startswith("SKIP"):
                m = re.match(r"^SKIP \((.*)\): (.*)$", z)
                report("SKIP", "%s (%s)" % (m.group(2), m.group(1)) if m else z[4:].lstrip(" :"))
            elif z.startswith("WOULD"):
                report("WOULD CREATE", z.replace("WOULD CREATE", "").strip(" :"))
        if r.returncode != 0:
            notice = ""
            if os.path.isfile(target):
                notice = " Does the file belong to another key or do the host files differ? Nothing was overwritten."
            error_lines = [z for z in output.splitlines() if z.startswith(("ABORT", "Failed", "Error"))][:3]
            report("ABORT", "%s: %s%s" % (target, " | ".join(error_lines) or "sops-secret.sh from-json failed", notice))

    # 5b. optional offline break-glass recipient (issue 11)
    if break_glass:
        break_glass_setup(entries, sops_yaml, age_e, env, dry_run)

    # 6. Notes
    for e in new_ssh:
        pub = pub_text(e["path"])
        if e["name"] == "vm-ssh-key":
            print("NOTE: %s: the public part (%s.pub) reaches the VM via cloud-init during the build (up)." % (e["name"], short(e["path"])))
            continue
        print()
        print("== New deploy key %s: public part (the private one stays on this machine) ==" % e["name"])
        print(pub or "(.pub not readable)")
        print("Register it on the Git server: repo -> Settings -> Deploy keys -> Add key.")
        print("Register it READ-ONLY (do NOT tick write access). Title e.g. %s." % e["name"])
    if rendered_new:
        print()
        print("%d SOPS file(s) newly encrypted. Next steps: git add secrets .sops.yaml, commit, push (Argo CD reads them from the repo)." % rendered_new)
    if ABORT_COUNT[0]:
        print()
        print("%d ABORT message(s). Nothing was overwritten or deleted." % ABORT_COUNT[0])


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    ap = argparse.ArgumentParser()
    ap.add_argument("command", choices=["map", "init", "generate", "ca-rotation"])
    ap.add_argument("--json", required=True)
    ap.add_argument("--name", action="append", default=[])
    ap.add_argument("--repo")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--new-age-key", action="store_true")
    ap.add_argument("--yes", action="store_true")
    ap.add_argument("--break-glass", action="store_true")
    ap.add_argument("--break-glass-delete", action="store_true")
    a = ap.parse_args()
    try:
        payload = load_json(a.json)
        if a.command == "map":
            print_map(payload)
            return 0
        if a.command == "generate":
            if not a.name:
                raise LabError("--name is_missing")
            generate(payload, a.name)
            return 1 if ABORT_COUNT[0] else 0
        if not a.repo:
            raise LabError("--repo is_missing")
        if a.command == "ca-rotation":
            ca_rotation(payload, os.path.abspath(a.repo), a.dry_run, a.yes)
            return 1 if ABORT_COUNT[0] else 0
        if a.break_glass and a.break_glass_delete:
            raise LabError("--break-glass and --break-glass-delete exclude each other")
        if a.break_glass_delete:
            repo = os.path.abspath(a.repo)
            os.chdir(repo)
            break_glass_delete(payload["entries"], os.path.join(repo, ".sops.yaml"), a.dry_run)
            return 1 if ABORT_COUNT[0] else 0
        init(payload, os.path.abspath(a.repo), a.dry_run, a.new_age_key, a.yes, a.break_glass)
    except (LabError, OSError) as x:
        print("ABORT: %s" % x)
        return 1
    return 1 if ABORT_COUNT[0] else 0


if __name__ == "__main__":
    sys.exit(main())
