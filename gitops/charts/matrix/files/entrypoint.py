#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
"""Start Synapse as the chart user and make sure the admin exists.

The image runs start.py, which switches to uid 991 with gosu when UID is set
or the process is root. Restricted Pod Security forbids that. This script is
the container command instead: it expects to already be uid 991, refuses a
UID environment variable, fills the secret config on an emptyDir and execs
Synapse. The signing key, macaroon secret and form secret live on the volume
so a restart and a file restore keep them. Nothing secret is printed.
"""
import os
import shutil
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.request

SIGNING_DEST = "/data/signing.key"
SIGNING_SECRET = "/secrets/signing/signing.key"


def decide_signing(provided, have):
    """provided and have are stripped key lines. Empty means absent.

    install: a provided key and an empty volume (first start, or a restore
    that brought the secret but not the file).
    keep: nothing provided (Synapse generates on an empty volume, or the
    volume already holds the key) or both sides are the same line.
    abort: both sides are set and differ. The caller must not print them.
    """
    if provided and have and provided != have:
        return "abort"
    if provided and not have:
        return "install"
    return "keep"


def read_secret(path, label):
    with open(path, encoding="utf-8") as handle:
        value = handle.read()
    if value.endswith("\n"):
        value = value[:-1]
    if not value or "\n" in value:
        sys.stderr.write("%s must be exactly one non-empty line\n" % label)
        sys.exit(1)
    return value


def reject(value, label):
    if any(char in value for char in "\"\\\n"):
        sys.stderr.write("%s is not safe to place in the config\n" % label)
        sys.exit(1)


def write_private(path, text):
    tmp = path + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(text)
    os.replace(tmp, path)


def ensure_token(path):
    if os.path.isfile(path):
        current = open(path, encoding="utf-8").read().strip()
        if current:
            return current
    token = __import__("secrets").token_hex(32)
    write_private(path, token + "\n")
    return token


def apply_signing(provided_text):
    provided = provided_text.strip()
    have = ""
    if os.path.isfile(SIGNING_DEST):
        have = open(SIGNING_DEST, encoding="utf-8").read().strip()
    decision = decide_signing(provided, have)
    if decision == "abort":
        sys.stderr.write("signing key on the volume differs from the provided secret\n")
        sys.exit(1)
    if decision == "install":
        write_private(SIGNING_DEST, provided + "\n")
        sys.stderr.write("signing key installed from the secret\n")
    return decision


def fill(template, mapping):
    out = template
    for key, value in mapping.items():
        token = "__%s__" % key
        if out.count(token) != 1:
            sys.stderr.write("placeholder %s is not present exactly once\n" % token)
            sys.exit(1)
        reject(value, key)
        out = out.replace(token, value)
    return out


def healthy():
    try:
        with urllib.request.urlopen("http://127.0.0.1:8008/health", timeout=2) as response:
            return response.status == 200
    except (OSError, urllib.error.URLError):
        return False


def main():
    if os.environ.get("UID"):
        sys.stderr.write("UID is set; the image would switch user, which restricted Pod Security forbids\n")
        sys.exit(1)
    os.makedirs("/data/media_store", mode=0o750, exist_ok=True)
    os.makedirs("/config", mode=0o700, exist_ok=True)
    provided = ""
    if os.path.isfile(SIGNING_SECRET):
        provided = open(SIGNING_SECRET, encoding="utf-8").read()
    apply_signing(provided)
    host = os.environ.get("DATABASE_HOST", "")
    user = os.environ.get("DATABASE_USER", "")
    database = os.environ.get("DATABASE_NAME", "")
    if not host or not user or not database:
        sys.stderr.write("DATABASE_HOST, DATABASE_USER and DATABASE_NAME are required\n")
        sys.exit(1)
    template = open("/config-src/homeserver.yaml", encoding="utf-8").read()
    if ("user: %s\n" % user) not in template or ("database: %s\n" % database) not in template:
        sys.stderr.write("homeserver template user or database does not match the environment\n")
        sys.exit(1)
    filled = fill(template, {
        "DATABASE_PASSWORD": read_secret("/secrets/db/password", "database password"),
        "DATABASE_HOST": host,
        "MACAROON_SECRET": ensure_token("/data/macaroon.secret"),
        "FORM_SECRET": ensure_token("/data/form.secret"),
        "REGISTRATION_SECRET": read_secret("/secrets/registration/shared_secret", "registration secret"),
        "OIDC_CLIENT_SECRET": read_secret("/secrets/oidc/client_secret", "OIDC client secret"),
    })
    write_private("/config/homeserver.yaml", filled)
    shutil.copyfile("/config-src/log.yaml", "/config/log.yaml")
    proc = subprocess.Popen([
        sys.executable, "-m", "synapse.app.homeserver",
        "--config-path", "/config/homeserver.yaml",
        "--config-path", "/config/log.yaml",
    ])

    def forward(signum, _frame):
        if proc.poll() is None:
            proc.send_signal(signum)

    signal.signal(signal.SIGTERM, forward)
    signal.signal(signal.SIGINT, forward)
    for _ in range(90):
        if proc.poll() is not None:
            sys.exit(proc.returncode or 1)
        if healthy():
            break
        time.sleep(2)
    else:
        sys.stderr.write("synapse did not become healthy\n")
        proc.terminate()
        proc.wait(timeout=20)
        sys.exit(1)
    admin = subprocess.call([sys.executable, "/bootstrap/ensure-admin.py"])
    if admin != 0:
        proc.terminate()
        try:
            proc.wait(timeout=20)
        except subprocess.TimeoutExpired:
            proc.kill()
        sys.exit(admin)
    sys.exit(proc.wait())


if __name__ == "__main__":
    main()
