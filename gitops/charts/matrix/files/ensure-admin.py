#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
"""Create the Matrix admin once. A second start finds the user and stops.

Registration on the homeserver is off. The shared-secret registration API
still accepts this call. M_USER_IN_USE is success: the password is not reset.
The username and the password are read from files and never printed.
"""
import hashlib
import hmac
import json
import os
import sys
import urllib.error
import urllib.request

BASE = os.environ.get("MATRIX_BASE_URL", "http://127.0.0.1:8008")


def registration_mac(secret, nonce, user, password):
    """HMAC-SHA1 over nonce, user, password and the admin flag, joined by NUL."""
    message = b"\x00".join([
        nonce.encode("utf-8"),
        user.encode("utf-8"),
        password.encode("utf-8"),
        b"admin",
    ])
    return hmac.new(secret.encode("utf-8"), message, hashlib.sha1).hexdigest()


def read_one(path):
    with open(path, encoding="utf-8") as handle:
        value = handle.read()
    if value.endswith("\n"):
        value = value[:-1]
    if not value or "\n" in value:
        sys.stderr.write("admin credential file must be exactly one non-empty line\n")
        sys.exit(1)
    return value


def post_json(url, payload):
    data = json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            body = response.read()
            return response.status, body
    except urllib.error.HTTPError as err:
        return err.code, err.read()


def ensure_admin(base, user, password, secret):
    """Returns (ok, line). line is safe to print."""
    nonce_url = base.rstrip("/") + "/_synapse/admin/v1/register"
    try:
        with urllib.request.urlopen(nonce_url, timeout=15) as response:
            nonce = json.loads(response.read().decode("utf-8"))["nonce"]
    except (OSError, ValueError, KeyError):
        return False, "matrix-admin: nonce request failed"
    status, body = post_json(nonce_url, {
        "nonce": nonce,
        "username": user,
        "password": password,
        "admin": True,
        "mac": registration_mac(secret, nonce, user, password),
    })
    if status == 200:
        return True, "matrix-admin: admin ensured"
    try:
        errcode = json.loads(body.decode("utf-8")).get("errcode", "")
    except (ValueError, UnicodeError):
        errcode = ""
    if errcode == "M_USER_IN_USE":
        return True, "matrix-admin: admin already present"
    return False, "matrix-admin: failed HTTP %s %s" % (status, errcode)


def main():
    user = read_one(os.environ.get("MATRIX_ADMIN_USER_FILE", "/secrets/admin/username"))
    password = read_one(os.environ.get("MATRIX_ADMIN_PASSWORD_FILE", "/secrets/admin/password"))
    secret = read_one(os.environ.get("MATRIX_REGISTRATION_FILE", "/secrets/registration/shared_secret"))
    ok, line = ensure_admin(BASE, user, password, secret)
    sys.stdout.write(line + "\n")
    if user in line or password in line:
        sys.stderr.write("matrix-admin: refused to print a credential\n")
        sys.exit(1)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
