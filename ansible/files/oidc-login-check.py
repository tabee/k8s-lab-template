#!/usr/bin/env python3
"""Log in to an SSO-protected notes site with a real Keycloak user and log out again.

Used by ansible/tasks/verify-notes-site.yml (opt-in, needs a lab-users account) and by
the offline test tests/notes-sso-tests.sh (mock server). Standard library only.

Steps (each prints one line, never a password, cookie or token):
  1. GET <site>/ without a session   -> 302 to the Keycloak authorize URL (host sso)
  2. open the login form, post user and password, follow all redirects
  3. final answer is 200 on the site host
  4. second GET <site>/ with the session cookie -> 200 without a redirect
  5. GET <site>/oauth2/sign_out, then GET <site>/ -> 302 to the login again
  6. the Keycloak authorize URL shows the login form again (SSO session is really over)

The password comes from the environment variable named by --password-env.
Exit code 0 = all steps ok, 1 = a step failed, 2 = wrong usage.
"""
import argparse
import html
import http.client
import os
import re
import ssl
import sys
import urllib.parse


class Client:
    def __init__(self, resolve, cacert):
        self.resolve = resolve
        self.cookies = {}  # host -> {name: value}
        self.last_headers = []
        self.last_reason = ""
        self.ctx = ssl.create_default_context(cafile=cacert) if cacert else ssl.create_default_context()

    def request(self, method, url, data=None):
        u = urllib.parse.urlsplit(url)
        host = u.hostname
        port = u.port or (443 if u.scheme == "https" else 80)
        ip, rport = self.resolve.get(host, (host, port))
        if u.scheme == "https":
            conn = http.client.HTTPSConnection(ip, rport, timeout=20, context=self.ctx)
            # TCP connect to the mapped address, certificate checked against the site name
            conn.connect = self._tls_connect(conn, host)
        else:
            conn = http.client.HTTPConnection(ip, rport, timeout=20)
        headers = {"Host": u.netloc, "User-Agent": "lab-oidc-login-check", "Accept": "text/html"}
        jar = self.cookies.get(host, {})
        if jar:
            headers["Cookie"] = "; ".join(f"{k}={v}" for k, v in jar.items())
        body = None
        if data is not None:
            body = urllib.parse.urlencode(data)
            headers["Content-Type"] = "application/x-www-form-urlencoded"
        path = u.path or "/"
        if u.query:
            path += "?" + u.query
        conn.request(method, path, body=body, headers=headers)
        resp = conn.getresponse()
        text = resp.read().decode("utf-8", "replace")
        for h, v in resp.getheaders():
            if h.lower() == "set-cookie":
                name, _, rest = v.partition("=")
                value = rest.split(";", 1)[0]
                if value == "" or "max-age=0" in v.lower() or "1970" in v:
                    self.cookies.setdefault(host, {}).pop(name, None)
                else:
                    self.cookies.setdefault(host, {})[name] = value
        loc = resp.getheader("Location")
        if loc:
            loc = urllib.parse.urljoin(url, loc)
        self.last_headers = resp.getheaders()
        self.last_reason = resp.reason
        conn.close()
        return resp.status, loc, text

    @staticmethod
    def _tls_connect(conn, host):
        def connect():
            import socket
            sock = socket.create_connection((conn.host, conn.port), conn.timeout)
            conn.sock = conn._context.wrap_socket(sock, server_hostname=host)
        return connect

    def follow(self, url, data=None, limit=15):
        method = "POST" if data is not None else "GET"
        for _ in range(limit):
            status, loc, text = self.request(method, url, data)
            if status in (301, 302, 303, 307) and loc:
                url, method, data = loc, "GET", None
                continue
            return status, url, text
        return 0, url, ""


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--site-url", required=True, help="e.g. https://notes.lab.example/")
    ap.add_argument("--sso-host", required=True, help="host name of Keycloak, e.g. sso.lab.example")
    ap.add_argument("--user", required=True)
    ap.add_argument("--password-env", default="NOTES_SSO_PASSWORD")
    ap.add_argument("--cacert")
    ap.add_argument("--resolve", action="append", default=[], metavar="HOST=IP[:PORT]")
    ap.add_argument("--logout-path", default="/oauth2/sign_out")
    ap.add_argument("--get", action="append", default=[], metavar="PATH",
                    help="after the login also fetch PATH and write the answer (like curl --include) to --dump-dir/<n>.http")
    ap.add_argument("--dump-dir", help="directory for the --get answers (created, mode 0700)")
    a = ap.parse_args()
    password = os.environ.get(a.password_env)
    if not password:
        print(f"environment variable {a.password_env} is empty", file=sys.stderr)
        return 2
    resolve = {}
    for r in a.resolve:
        host, _, target = r.partition("=")
        ip, _, port = target.partition(":")
        scheme_port = urllib.parse.urlsplit(a.site_url).scheme == "https" and 443 or 80
        resolve[host] = (ip, int(port) if port else scheme_port)
    c = Client(resolve, a.cacert)
    site = urllib.parse.urlsplit(a.site_url)
    root = f"{site.scheme}://{site.netloc}/"
    failed = []

    def step(name, ok, extra=""):
        print(("ok   " if ok else "FAIL ") + name + ("" if ok or not extra else " (" + extra + ")"))
        if not ok:
            failed.append(name)
        return ok

    status, loc, _ = c.request("GET", root)
    sso_ok = status == 302 and loc is not None and urllib.parse.urlsplit(loc).hostname == a.sso_host
    if not step("without session: 302 to the login at " + a.sso_host, sso_ok, f"status {status}"):
        return 1
    status, url, text = c.follow(loc)
    form = re.search(r'<form[^>]*\baction="([^"]+)"', text)
    if not step("login form is shown", status == 200 and form is not None, f"status {status}"):
        return 1
    status, url, text = c.follow(html.unescape(form.group(1)),
                                 {"username": a.user, "password": password, "credentialId": ""})
    on_site = urllib.parse.urlsplit(url).hostname == site.hostname
    if not step("login: final answer 200 on the site", status == 200 and on_site, f"status {status} at {urllib.parse.urlsplit(url).hostname}"):
        return 1
    status, loc, _ = c.request("GET", root)
    step("next request with session: 200, no redirect", status == 200, f"status {status}")
    if a.get:
        if not a.dump_dir:
            print("--get needs --dump-dir", file=sys.stderr)
            return 2
        os.makedirs(a.dump_dir, mode=0o700, exist_ok=True)
        for n, path in enumerate(a.get):
            status, _, text = c.request("GET", root.rstrip("/") + path)
            head = f"HTTP/1.1 {status} {c.last_reason}\r\n" + "".join(f"{k}: {v}\r\n" for k, v in c.last_headers)
            with open(os.path.join(a.dump_dir, f"{n}.http"), "w", encoding="utf-8") as f:
                f.write(head + "\r\n" + text)
        step(f"fetched {len(a.get)} page(s) with the session", True)
    c.request("GET", root.rstrip("/") + a.logout_path)
    status, loc, _ = c.request("GET", root)
    again = status == 302 and loc is not None and urllib.parse.urlsplit(loc).hostname == a.sso_host
    step("after logout: 302 to the login again", again, f"status {status}")
    if again:
        status, url, text = c.follow(loc)
        step("after logout: Keycloak asks for credentials again (SSO session ended)",
             status == 200 and re.search(r'name="username"', text) is not None, f"status {status}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
