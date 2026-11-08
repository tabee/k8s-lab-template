#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
"""accept-http.py: HTTPS checks of scripts/matrix-import.sh against the lab Matrix. Prints "RESULT ok|fail LABEL" lines.

  accept-http.py anon  BASE [--cacert FILE] [--resolve HOST:PORT:IP]
      client API answers, /_synapse/admin is not reachable from outside, federation and key endpoints are 404
  accept-http.py user  BASE SERVER_NAME LOCALPART [--cacert FILE] [--resolve ...] [--rooms N] [--e2e-devices N]
                       [--backup 0|1] [--media ID:BYTES]
      logs in (password in the environment variable MXI_PASSWORD, never on a command line), checks that the account
      is the one of SERVER_NAME, lists the joined rooms and reads the newest event of each, downloads one media file,
      queries the device keys and the key backup, then logs the device out again
Exit code 0 when the script itself ran; the verdict is in the RESULT lines.
"""
import http.client
import json
import os
import socket
import ssl
import sys
import urllib.parse


class Client:
    def __init__(self, base, cacert, resolve):
        u = urllib.parse.urlparse(base)
        self.host = u.hostname
        self.port = u.port or (443 if u.scheme == "https" else 80)
        self.tls = u.scheme == "https"
        self.addr = self.host
        if resolve:
            h, p, ip = resolve.split(":", 2)
            if h == self.host and int(p) == self.port:
                self.addr = ip
        self.ctx = ssl.create_default_context(cafile=cacert) if cacert else ssl.create_default_context()
        self.token = None

    def request(self, method, path, body=None, raw=False):
        headers = {"Host": self.host if self.port in (80, 443) else "%s:%d" % (self.host, self.port)}
        if self.token:
            headers["Authorization"] = "Bearer " + self.token
        data = None
        if body is not None:
            data = json.dumps(body).encode("utf-8")
            headers["Content-Type"] = "application/json"
        try:
            if self.tls:
                raw_sock = socket.create_connection((self.addr, self.port), timeout=30)
                sock = self.ctx.wrap_socket(raw_sock, server_hostname=self.host)
                conn = http.client.HTTPSConnection(self.host, self.port, timeout=60)
                conn.sock = sock
            else:
                conn = http.client.HTTPConnection(self.addr, self.port, timeout=60)
            conn.request(method, path, body=data, headers=headers)
            resp = conn.getresponse()
            payload = resp.read()
            conn.close()
        except (OSError, ssl.SSLError, http.client.HTTPException) as exc:
            return 0, b"", str(exc)[:80]
        if raw:
            return resp.status, payload, ""
        try:
            return resp.status, json.loads(payload.decode("utf-8") or "null"), ""
        except ValueError:
            return resp.status, None, ""


def result(ok, label, detail=""):
    sys.stdout.write("RESULT %s %s%s\n" % ("ok" if ok else "fail", label, (" (%s)" % detail) if (detail and not ok) else ""))


def anon(c):
    status, body, err = c.request("GET", "/_matrix/client/versions")
    result(status == 200 and isinstance(body, dict) and "versions" in body, "client API answers (/_matrix/client/versions)", err or "HTTP %s" % status)
    for path in ("/_synapse/admin/v1/server_version", "/_synapse/admin/v2/users", "//_synapse/admin/v1/server_version",
                 "/_synapse/admin/", "/_synapse/%61dmin/v1/server_version"):
        status, _, err = c.request("GET", path, raw=True)
        result(status in (403, 404), "admin API is not reachable from outside (GET %s)" % path, err or "HTTP %s" % status)
    for path in ("/_matrix/federation/v1/version", "/_matrix/key/v2/server", "/.well-known/matrix/server"):
        status, _, err = c.request("GET", path, raw=True)
        result(status == 404, "federation is off (GET %s is 404)" % path, err or "HTTP %s" % status)
    status, body, err = c.request("POST", "/_matrix/client/v3/register", {"username": "mxi-probe", "password": "x" * 20, "auth": {"type": "m.login.dummy"}})
    result(status in (400, 401, 403), "open registration is refused", err or "HTTP %s" % status)


def user(c, server, local, rooms, e2e_devices, backup, media):
    password = os.environ.get("MXI_PASSWORD", "")
    status, body, err = c.request("POST", "/_matrix/client/v3/login", {
        "type": "m.login.password", "identifier": {"type": "m.id.user", "user": local}, "password": password,
        "initial_device_display_name": "matrix-import acceptance"})
    ok = status == 200 and isinstance(body, dict) and body.get("access_token")
    detail = err or "HTTP %s" % status
    if status == 429 and isinstance(body, dict):
        detail += " (Synapse rate limit on logins, try again in %d s: bash scripts/lab.sh matrix-import accept)" % (int(body.get("retry_after_ms", 0)) // 1000 + 1)
    result(ok, "old password of @%s:%s works (login over HTTPS)" % (local, server), detail)
    if not ok:
        return
    c.token = body["access_token"]
    uid = "@%s:%s" % (local, server)
    try:
        result(body.get("user_id") == uid, "login returns the user id %s" % uid, str(body.get("user_id")))
        status, who, _ = c.request("GET", "/_matrix/client/v3/account/whoami")
        result(status == 200 and who.get("user_id") == uid, "whoami says %s" % uid)
        status, joined, _ = c.request("GET", "/_matrix/client/v3/joined_rooms")
        rl = joined.get("joined_rooms", []) if status == 200 and isinstance(joined, dict) else []
        if rooms is not None:
            result(len(rl) == rooms, "joined rooms: %d, database says %d" % (len(rl), rooms))
        empty = 0
        for room in rl[:20]:
            q = urllib.parse.quote(room, safe="")
            status, msgs, _ = c.request("GET", "/_matrix/client/v3/rooms/%s/messages?dir=b&limit=1" % q)
            if status != 200 or not msgs or not msgs.get("chunk"):
                empty += 1
        result(empty == 0, "history readable: the newest event of each of %d joined rooms (no room is empty or unreadable)" % min(len(rl), 20), "%d room(s) without events" % empty)
        if media:
            mid, size = media.split(":", 1)
            status, data, err = c.request("GET", "/_matrix/client/v1/media/download/%s/%s" % (server, urllib.parse.quote(mid, safe="")), raw=True)
            result(status == 200 and len(data) == int(size), "media %s downloads with %s bytes" % (mid, size), err or "HTTP %s, %d bytes" % (status, len(data)))
        status, keys, _ = c.request("POST", "/_matrix/client/v3/keys/query", {"device_keys": {uid: []}})
        devices = (keys or {}).get("device_keys", {}).get(uid, {}) if status == 200 else {}
        if e2e_devices is not None:
            result(len(devices) >= e2e_devices, "device keys of %s: %d on the server (database has %d from the import)" % (uid, len(devices), e2e_devices))
        if backup is not None:
            status, ver, _ = c.request("GET", "/_matrix/client/v3/room_keys/version")
            result((status == 200) == bool(backup), "key backup %s as in the import" % ("present" if backup else "absent"), "HTTP %s" % status)
    finally:
        c.request("POST", "/_matrix/client/v3/logout", {})


def main(argv):
    if len(argv) < 3 or argv[1] not in ("anon", "user"):
        sys.stderr.write(__doc__)
        return 2
    mode, base = argv[1], argv[2]
    rest = argv[3:]
    pos = []
    opts = {}
    i = 0
    while i < len(rest):
        if rest[i].startswith("--"):
            opts[rest[i][2:]] = rest[i + 1]
            i += 2
        else:
            pos.append(rest[i])
            i += 1
    c = Client(base, opts.get("cacert"), opts.get("resolve"))
    if mode == "anon":
        anon(c)
    else:
        if len(pos) != 2:
            sys.stderr.write(__doc__)
            return 2
        user(c, pos[0], pos[1], int(opts["rooms"]) if "rooms" in opts else None,
             int(opts["e2e-devices"]) if "e2e-devices" in opts else None,
             int(opts["backup"]) if "backup" in opts else None, opts.get("media"))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
