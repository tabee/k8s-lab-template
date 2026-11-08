#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
"""Log in as the admin and print only whether it worked.

The access token is never printed. Used by the restore drill and by an
operator who wants to prove the account, not to fetch a token.
"""
import json
import os
import sys
import urllib.error
import urllib.request


def read_one(path):
    with open(path, encoding="utf-8") as handle:
        value = handle.read()
    if value.endswith("\n"):
        value = value[:-1]
    if not value or "\n" in value:
        sys.stderr.write("credential file must be exactly one non-empty line\n")
        sys.exit(1)
    return value


def login(base, user, password):
    payload = json.dumps({
        "type": "m.login.password",
        "identifier": {"type": "m.id.user", "user": user},
        "password": password,
    }).encode("utf-8")
    request = urllib.request.Request(
        base.rstrip("/") + "/_matrix/client/v3/login",
        data=payload,
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            body = json.loads(response.read().decode("utf-8"))
            return response.status == 200 and bool(body.get("access_token"))
    except (OSError, urllib.error.HTTPError, ValueError, UnicodeError):
        return False


def main():
    user = read_one(os.environ.get("MATRIX_ADMIN_USER_FILE", "/secrets/admin/username"))
    password = read_one(os.environ.get("MATRIX_ADMIN_PASSWORD_FILE", "/secrets/admin/password"))
    base = os.environ.get("MATRIX_BASE_URL", "http://127.0.0.1:8008")
    if login(base, user, password):
        sys.stdout.write("login ok\n")
        sys.exit(0)
    sys.stdout.write("login failed\n")
    sys.exit(1)


if __name__ == "__main__":
    main()
