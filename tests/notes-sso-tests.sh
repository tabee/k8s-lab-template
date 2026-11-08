#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
# Offline tests for the Keycloak login of the notes sites (ADR 0021). No cluster, no Keycloak.
#   1. notes chart (helm template): auth sso (default), auth basic, invalid auth
#   2. login proxy: hardening, memory limit marker, secret, args, policies
#   3. Keycloak side: client "notes" in the rendered realm follows sites.yaml, NetworkPolicy
#   4. Ansible values: defaults equal the chart, secrets of sso/basic sites, role and playbooks
#   5. ansible/files/oidc-login-check.py against a mock server (login, logout, broken logout)
#   6. names: lab_hosts covers the site and the Keycloak host
# Usage: bash tests/notes-sso-tests.sh [repo root]
set -u
export PYTHONDONTWRITEBYTECODE=1
R=$(cd "${1:-$(dirname "${BASH_SOURCE[0]}")/..}" && pwd -P)
mkdir -p "$HOME/.cache/lab-sh-tests"
T=$(mktemp -d -p "$HOME/.cache/lab-sh-tests")
cleanup() { [ -z "${MOCK_PID:-}" ] || kill "$MOCK_PID" 2> /dev/null; rm -rf "$T"; }
trap cleanup EXIT
fail=0
n=0
ok() { n=$((n + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else echo "FAIL $1 (is '$2', want '$3')"; fail=$((fail + 1)); fi; }
has() { grep -Fq -- "$2" "$3"; local r=$?; ok "$1" "$r" 0; }
hasnt() { if grep -Fq -- "$2" "$3"; then ok "$1" 1 0; else ok "$1" 0 0; fi; }
CH="$R/gitops/charts/notes-site"
HSET="site.name=t,site.host=t.example.test,site.repo=ssh://git@x/y.git"

# Shared start of every Python block: counters and helpers (the block starts with exec of this file).
cat > "$T/pyhead.py" << 'PY'
import sys

import yaml

bad = []


def check(label, cond):
    print(("OK   " if cond else "FAIL ") + label)
    if not cond:
        bad.append(label)


def load(p):
    return [d for d in yaml.safe_load_all(open(p, encoding="utf-8")) if d]


def by(docs, kind, name):
    return [d for d in docs if d["kind"] == kind and d["metadata"]["name"] == name]
PY
export PYHEAD="$T/pyhead.py"
# pyblock <label> <args...>: runs the Python from stdin; OK/FAIL lines are counted.
pyblock() {
  local label=$1
  shift
  python3 - "$@" > "$T/py.out" 2>&1
  cat "$T/py.out"
  n=$((n + $(grep -c '^OK ' "$T/py.out") + $(grep -c '^FAIL' "$T/py.out")))
  fail=$((fail + $(grep -c '^FAIL' "$T/py.out")))
  grep -q 'Traceback' "$T/py.out"
  ok "$label ran without a Python error" "$?" 1
}

echo "== 1. notes chart: auth sso, basic, invalid"
if command -v helm > /dev/null 2>&1; then
  helm template notes-t "$CH" -n notes-t --set "$HSET" > "$T/sso.yaml" 2> "$T/sso.err"; ok "helm template: default auth renders" "$?" 0
  helm template notes-t "$CH" -n notes-t --set "$HSET,site.auth=sso" > "$T/sso2.yaml" 2> /dev/null
  cmp -s "$T/sso.yaml" "$T/sso2.yaml"; ok "default auth is sso (same render as site.auth=sso)" "$?" 0
  helm template notes-t "$CH" -n notes-t --set "$HSET,site.auth=basic" > "$T/basic.yaml" 2> "$T/basic.err"; ok "helm template: auth basic renders" "$?" 0
  helm template notes-t "$CH" -n notes-t --set "$HSET,site.auth=bogus" > /dev/null 2> "$T/bogus.err"; ok "helm template: unknown auth is refused" "$?" 1
  has "message names the allowed values" "site.auth must be sso or basic" "$T/bogus.err"
  pyblock "chart routing" "$T/sso.yaml" "$T/basic.yaml" << 'PY'
exec(open(__import__("os").environ["PYHEAD"]).read())
sso, basic = load(sys.argv[1]), load(sys.argv[2])
check("sso: proxy Deployment and Service exist", len(by(sso, "Deployment", "notes-oauth2-proxy")) == 1 and len(by(sso, "Service", "notes-oauth2-proxy")) == 1)
check("basic: no proxy Deployment or Service", not by(basic, "Deployment", "notes-oauth2-proxy") and not by(basic, "Service", "notes-oauth2-proxy"))
check("sso: no basic-auth Middleware", not by(sso, "Middleware", "basic-auth"))
check("basic: basic-auth Middleware exists", len(by(basic, "Middleware", "basic-auth")) == 1)
check("both: no-cache Middleware stays", len(by(sso, "Middleware", "no-cache")) == 1 and len(by(basic, "Middleware", "no-cache")) == 1)
rs = by(sso, "IngressRoute", "notes")[0]["spec"]
rb = by(basic, "IngressRoute", "notes")[0]["spec"]
check("sso: route goes to the proxy, no basic-auth middleware",
      rs["routes"][0]["services"][0]["name"] == "notes-oauth2-proxy" and "basic-auth" not in [m["name"] for m in rs["routes"][0].get("middlewares", [])])
check("basic: route goes to the site with basic-auth",
      rb["routes"][0]["services"][0]["name"] == "notes" and "basic-auth" in [m["name"] for m in rb["routes"][0].get("middlewares", [])])
check("both: HTTPS entry point only", rs["entryPoints"] == ["websecure"] and rb["entryPoints"] == ["websecure"])
nps = {d["metadata"]["name"] for d in sso if d["kind"] == "NetworkPolicy"}
npb = {d["metadata"]["name"] for d in basic if d["kind"] == "NetworkPolicy"}
check("sso: four policies (traefik, proxy, egress of the site, egress of the proxy)",
      nps == {"notes-allow-traefik", "notes-allow-proxy", "notes-allow-egress", "notes-oauth2-proxy-allow-egress"})
check("basic: only the two old policies", npb == {"notes-allow-traefik", "notes-allow-egress"})
sys.exit(1 if bad else 0)
PY

  echo "== 2. login proxy: hardening, limits, secret, arguments, policies"
  pyblock "proxy checks" "$T/sso.yaml" << 'PY'
exec(open(__import__("os").environ["PYHEAD"]).read())
sso = load(sys.argv[1])
dep = by(sso, "Deployment", "notes-oauth2-proxy")[0]
pod = dep["spec"]["template"]["spec"]
c = pod["containers"][0]
args = c["args"]
check("one replica, one container", dep["spec"]["replicas"] == 1 and len(pod["containers"]) == 1)
check("image is pinned by digest", "@sha256:" in c["image"] and c["image"].startswith("quay.io/oauth2-proxy/oauth2-proxy:v"))
sc, psc = c["securityContext"], pod["securityContext"]
check("restricted: non-root, read-only root, no privilege escalation, drop ALL, seccomp",
      psc["runAsNonRoot"] is True and sc["readOnlyRootFilesystem"] is True and sc["allowPrivilegeEscalation"] is False
      and sc["capabilities"]["drop"] == ["ALL"] and psc["seccompProfile"]["type"] == "RuntimeDefault")
check("no service account token", pod["automountServiceAccountToken"] is False)
check("no volumes (stateless, cookie session store: nothing to back up)", not pod.get("volumes"))
res = c["resources"]
check("tiny: request 24Mi memory + 10m CPU, limit 64Mi memory, no CPU limit",
      res["requests"] == {"cpu": "10m", "memory": "24Mi"} and res["limits"] == {"memory": "64Mi"})
check("probes on /ping and /ready", c["livenessProbe"]["httpGet"]["path"] == "/ping" and c["readinessProbe"]["httpGet"]["path"] == "/ready")
env = {e["name"]: e["valueFrom"]["secretKeyRef"] for e in c["env"]}
check("secrets come from the Secret notes-oidc (env, never on the command line)",
      env == {"OAUTH2_PROXY_CLIENT_SECRET": {"key": "client-secret", "name": "notes-oidc"},
              "OAUTH2_PROXY_COOKIE_SECRET": {"key": "cookie-secret", "name": "notes-oidc"}})
check("no secret flag in the arguments", not any(a.startswith(("--client-secret", "--cookie-secret")) for a in args))
check("group restriction lab-users, groups claim read", "--allowed-group=lab-users" in args and "--oidc-groups-claim=groups" in args)
check("PKCE S256", "--code-challenge-method=S256" in args)
check("cookie: secure, httponly, samesite lax, per-site name",
      {"--cookie-secure=true", "--cookie-httponly=true", "--cookie-samesite=lax", "--cookie-name=_notes_t"} <= set(args))
check("session lifetime 10h, refresh 4m", "--cookie-refresh=4m" in args and "--cookie-expire=10h" in args)
check("redirect URL is fixed to the site host (no forwarded headers trusted)",
      "--redirect-url=https://t.example.test/oauth2/callback" in args and not any(a.startswith("--reverse-proxy") for a in args))
check("login at the public SSO host, back channel inside the cluster",
      any(a.startswith("--login-url=https://sso.") for a in args) and any(a.startswith("--redeem-url=http://keycloak.keycloak.svc:8080/") for a in args)
      and any(a.startswith("--oidc-jwks-url=http://keycloak.keycloak.svc:8080/") for a in args))
check("logout ends the Keycloak session (id_token_hint)", any(a.startswith("--backend-logout-url=") and "id_token_hint={id_token}" in a for a in args))
check("upstream is the site service in its own namespace", "--upstream=http://notes.notes-t.svc:80" in args)
np = {d["metadata"]["name"]: d["spec"] for d in sso if d["kind"] == "NetworkPolicy"}
eg = np["notes-oauth2-proxy-allow-egress"]
check("proxy egress: three rules (DNS, the site pod, Keycloak), egress only", len(eg["egress"]) == 3 and eg["policyTypes"] == ["Egress"])
check("proxy egress ports: 53, 53, 8080, 8080", sorted(p["port"] for r in eg["egress"] for p in r["ports"]) == [53, 53, 8080, 8080])
check("proxy egress has no ipBlock (no internet, no API server)", not any("ipBlock" in t for r in eg["egress"] for t in r["to"]))
check("site ingress only from the proxy on 8080",
      len(np["notes-allow-proxy"]["ingress"]) == 1 and np["notes-allow-proxy"]["ingress"][0]["ports"][0]["port"] == 8080)
tr = np["notes-allow-traefik"]
check("Traefik reaches the proxy on 4180, not the site",
      tr["podSelector"]["matchLabels"]["app.kubernetes.io/name"] == "notes-oauth2-proxy" and tr["ingress"][0]["ports"][0]["port"] == 4180)
sys.exit(1 if bad else 0)
PY
  has "memory marker for the proxy (lab-limit)" "# lab-limit: notes-*/notes-oauth2-proxy/oauth2-proxy" "$CH/templates/oauth2-proxy.yaml"
  pyblock "memory-budget marker" "$R" << 'PY'
import importlib.util
import sys
from pathlib import Path

spec = importlib.util.spec_from_file_location("mb", sys.argv[1] + "/scripts/memory-budget.py")
mb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mb)
marks = [m for m in mb.find_markers(Path(sys.argv[1])) if any(s[1] == "notes-oauth2-proxy" for s in m[3])]
print(("OK   " if len(marks) == 1 and marks[0][2] == 64 else "FAIL ") + "memory-budget.py finds the proxy marker with 64 MiB")
print(("OK   " if mb.normalize_pod("notes-oauth2-proxy-1111111-aaaaa") == "notes-oauth2-proxy" else "FAIL ") + "pod name of the proxy normalises to the workload")
PY
else
  echo "SKIP: helm is missing"
fi

echo "== 3. Keycloak side: client notes follows sites.yaml, NetworkPolicy"
is_link=0
[ -L "$R/gitops/charts/keycloak/files/sites.yaml" ] || is_link=1
ok "the keycloak chart reads sites.yaml through a symlink" "$is_link" 0
ok "symlink target is the one list" "$(readlink "$R/gitops/charts/keycloak/files/sites.yaml")" "../../../sites.yaml"
if command -v helm > /dev/null 2>&1; then
  helm template keycloak "$R/gitops/charts/keycloak" > "$T/kc.yaml" 2> "$T/kc.err"; ok "helm template of the keycloak chart" "$?" 0
  cp -r "$R/gitops" "$T/g2"
  # Append through YAML, not text: a fresh clone (public export) has an empty list ("[]").
  python3 - "$T/g2/sites.yaml" << 'PY'
import sys

import yaml

p = sys.argv[1]
sites = yaml.safe_load(open(p, encoding="utf-8")) or []
sites += [{"name": "extra", "repo": "ssh://git@git.example.test/me/extra.git", "host": "extra.lab.example"},
          {"name": "breakglass", "repo": "ssh://git@git.example.test/me/bg.git", "host": "bg.lab.example", "auth": "basic"}]
open(p, "w", encoding="utf-8").write(yaml.safe_dump(sites, sort_keys=False))
PY
  helm template keycloak "$T/g2/charts/keycloak" > "$T/kc2.yaml" 2> /dev/null; ok "helm template with two more sites" "$?" 0
  pyblock "realm client notes" "$T/kc.yaml" "$T/kc2.yaml" "$R/gitops/sites.yaml" << 'PY'
exec(open(__import__("os").environ["PYHEAD"]).read())
import json


def client(path):
    docs = load(path)
    cm = [d for d in docs if d["kind"] == "ConfigMap"][0]
    realm = json.loads(cm["data"]["realm.json"])
    return {c["clientId"]: c for c in realm["clients"]}["notes"]


c1, c2 = client(sys.argv[1]), client(sys.argv[2])
sites = [s for s in yaml.safe_load(open(sys.argv[3], encoding="utf-8")) if s.get("auth", "sso") != "basic"]
check("client notes is confidential, standard flow only",
      c1["publicClient"] is False and c1["standardFlowEnabled"] is True and not c1["directAccessGrantsEnabled"]
      and not c1["implicitFlowEnabled"] and not c1["serviceAccountsEnabled"])
check("client secret is a placeholder for the realm job, no value in Git", c1["secret"] == "$(env:NOTES_CLIENT_SECRET)")
check("PKCE S256 is required", c1["attributes"]["pkce.code.challenge.method"] == "S256")
check("redirect URIs are exact: one callback per sso site", sorted(c1["redirectUris"]) == sorted("https://%s/oauth2/callback" % s["host"] for s in sites))
check("no wildcard in redirect or logout URIs", not any("*" in u for u in c1["redirectUris"]) and "*" not in c1["attributes"]["post.logout.redirect.uris"])
check("with more sites: sso site added, basic site left out",
      "https://extra.lab.example/oauth2/callback" in c2["redirectUris"] and not any("bg.lab.example" in u for u in c2["redirectUris"]))
check("post-logout URIs follow the same list", all(("https://%s/" % s["host"]) in c1["attributes"]["post.logout.redirect.uris"] for s in sites))
check("the groups scope is a default scope (needed for the group check)", "groups" in c1["defaultClientScopes"])
sys.exit(1 if bad else 0)
PY
fi
has "Keycloak admits the login proxies" "name: keycloak-allow-notes-proxy" "$R/gitops/workloads/keycloak/manifests/networkpolicy.yaml"
has "the realm job reads the client secret from its own SOPS Secret" "name: keycloak-notes-client" "$R/gitops/workloads/keycloak/manifests/job-config.yaml"

echo "== 4. Ansible values and role"
pyblock "ansible values" "$R" << 'PY'
exec(open(__import__("os").environ["PYHEAD"]).read())
import re
from pathlib import Path

R = Path(sys.argv[1])
notes = yaml.safe_load((R / "ansible/inventory/group_vars/all/notes.yml").read_text(encoding="utf-8"))
vals = yaml.safe_load((R / "gitops/charts/notes-site/values.yaml").read_text(encoding="utf-8"))
check("notes_auth_default equals the chart default site.auth", notes["notes_auth_default"] == vals["site"]["auth"] == "sso")
check("notes_oidc_secret_name equals secrets.oidc of the chart", notes["notes_oidc_secret_name"] == vals["secrets"]["oidc"])
check("notes_auth_secret_name equals secrets.auth of the chart", notes["notes_auth_secret_name"] == vals["secrets"]["auth"])
check("cookie key length is 16, 24 or 32 (what oauth2-proxy accepts)", notes["notes_cookie_length"] in (16, 24, 32))
check("realm and group of the chart match the realm", vals["sso"]["realm"] == "lab" and vals["sso"]["group"] == "lab-users")
check("SSO host of the chart is the Keycloak certificate name",
      vals["sso"]["host"] in (R / "gitops/workloads/keycloak/manifests/certificate.yaml").read_text(encoding="utf-8"))
sec = (R / "ansible/inventory/group_vars/all/secrets.yml").read_text(encoding="utf-8")
check("secrets_fixed has keycloak-notes-client-secret (pw, 48)",
      re.search(r"- name: keycloak-notes-client-secret\n(?:    .*\n)*?    kind: pw\n(?:    .*\n)*?    length: 48", sec) is not None)
check("secrets_notes: cookie for sso, password only for basic", "'-cookie'" in sec and "'-pw'" in sec)
check("keycloak.yml names the client secret file", "keycloak_notes_client_secret_file" in (R / "ansible/inventory/group_vars/all/keycloak.yml").read_text(encoding="utf-8"))
tasks = (R / "ansible/roles/notes_sites/tasks/site.yml").read_text(encoding="utf-8")
check("role handles notes-oidc and notes-auth", "notes_oidc_secret_name" in tasks and "notes_auth_secret_name" in tasks)
check("role removes the stale notes-auth of an sso site", "state: absent" in tasks)
check("role keeps secret values out of the log (no_log)", tasks.count("no_log: true") >= 2)
sys.exit(1 if bad else 0)
PY
if command -v ansible-playbook > /dev/null 2>&1; then
  ex=0
  for pb in verify-notes verify-egress argocd; do
    (cd "$R/ansible" && ansible-playbook -i localhost, --syntax-check "$pb.yml" > "$T/syn.out" 2>&1) || { ex=$((ex + 1)); cat "$T/syn.out"; }
  done
  ok "syntax check: verify-notes, verify-egress, argocd" "$ex" 0
else
  echo "SKIP: ansible-playbook is missing"
fi
has "verify-notes: authenticated login check is opt-in via NOTES_SSO_PASSWORD" "NOTES_SSO_PASSWORD" "$R/ansible/tasks/verify-notes-site.yml"
has "verify-egress checks the proxy policy" "notes-oauth2-proxy-allow-egress" "$R/ansible/verify-egress.yml"
has "verify-egress probes the proxy pod labels" "notes-oauth2-proxy" "$R/ansible/verify-egress.yml"

echo "== 5. oidc-login-check.py against a mock (login, logout, broken logout)"
cat > "$T/mock.py" << 'PY'
import http.server
import sys
import urllib.parse

BROKEN = len(sys.argv) > 2 and sys.argv[2] == "broken-logout"
SITE, SSO = "site.test", "sso.test"
SESSION = {"sso": False}
FORM = '<form action="http://%s/login" method="post"><input name="username"></form>' % SSO


class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, code, body="", headers=()):
        self.send_response(code)
        for k, v in headers:
            self.send_header(k, v)
        data = body.encode()
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def cookie(self, name):
        for part in self.headers.get("Cookie", "").split("; "):
            if part.startswith(name + "="):
                return part.split("=", 1)[1]
        return ""

    def route(self):
        host = self.headers["Host"].split(":")[0]
        u = urllib.parse.urlsplit(self.path)
        if host == SITE:
            if u.path == "/oauth2/sign_out":
                if not BROKEN:
                    SESSION["sso"] = False  # the real proxy ends the Keycloak session (backend logout)
                self.send(302, headers=[("Set-Cookie", "s=; Max-Age=0; Path=/"), ("Location", "/")])
            elif u.path == "/cb":
                self.send(302, headers=[("Set-Cookie", "s=1; Path=/"), ("Location", "/")])
            elif self.cookie("s") == "1":
                self.send(200, "notes")
            else:
                self.send(302, headers=[("Location", "http://%s/auth?x=1" % SSO)])
        elif host == SSO and u.path == "/auth":
            if SESSION["sso"]:
                self.send(302, headers=[("Location", "http://%s/cb" % SITE)])
            else:
                self.send(200, FORM)
        elif host == SSO and u.path == "/login" and self.command == "POST":
            body = urllib.parse.parse_qs(self.rfile.read(int(self.headers.get("Content-Length", "0"))).decode())
            if body.get("password") == ["right"]:
                SESSION["sso"] = True
                self.send(302, headers=[("Location", "http://%s/cb" % SITE)])
            else:
                self.send(200, FORM)
        else:
            self.send(404)

    do_GET = do_POST = route


srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write(str(srv.server_address[1]))
srv.serve_forever()
PY
CHK="$R/ansible/files/oidc-login-check.py"
run_mock() { # run_mock <mode> <password> : starts the mock, runs the check, stops the mock; exit code in $RC
  rm -f "$T/port"
  python3 "$T/mock.py" "$T/port" "$1" &
  MOCK_PID=$!
  for _ in $(seq 1 50); do [ -s "$T/port" ] && break; sleep 0.1; done
  local port
  port=$(cat "$T/port")
  NOTES_SSO_PASSWORD="$2" python3 "$CHK" --site-url http://site.test/ --sso-host sso.test --user u \
    --resolve "site.test=127.0.0.1:$port" --resolve "sso.test=127.0.0.1:$port" --get /page --dump-dir "$T/dump" > "$T/chk.out" 2>&1
  RC=$?
  kill "$MOCK_PID" 2> /dev/null
  wait "$MOCK_PID" 2> /dev/null
  MOCK_PID=""
}
run_mock ok right
ok "mock, correct password and working logout: exit 0" "$RC" 0
has "login check: redirect to the login seen" "ok   without session: 302 to the login at sso.test" "$T/chk.out"
has "login check: final answer on the site" "ok   login: final answer 200 on the site" "$T/chk.out"
has "login check: after logout the login is asked for again" "ok   after logout: Keycloak asks for credentials again" "$T/chk.out"
ok "login check: the page fetched with the session was dumped" "$(grep -c 'notes' "$T/dump/0.http")" 1
hasnt "login check never prints the password" "right" "$T/chk.out"
run_mock ok wrong
ok "mock, wrong password: exit 1" "$RC" 1
has "wrong password stops at the login step" "FAIL login: final answer 200 on the site" "$T/chk.out"
run_mock broken-logout right
ok "mock, logout leaves the Keycloak session alive: exit 1 (the check has teeth)" "$RC" 1
has "broken logout is reported" "FAIL after logout: Keycloak asks for credentials again" "$T/chk.out"
env -u NOTES_SSO_PASSWORD python3 "$CHK" --site-url http://site.test/ --sso-host sso.test --user u > "$T/chk.out" 2>&1
ok "no password in the environment: exit 2" "$?" 2

echo "== 6. names: lab_hosts covers the site and the SSO host"
pyblock "lab_hosts names" "$R" << 'PY'
exec(open(__import__("os").environ["PYHEAD"]).read())
import glob
from pathlib import Path

R = Path(sys.argv[1])
sites = yaml.safe_load((R / "gitops/sites.yaml").read_text(encoding="utf-8"))
certs = set()
for f in glob.glob(str(R / "gitops/workloads/**/certificate.yaml"), recursive=True):
    for d in load(f):
        certs |= set(d["spec"]["dnsNames"])
sso_host = yaml.safe_load((R / "gitops/charts/notes-site/values.yaml").read_text(encoding="utf-8"))["sso"]["host"]
check("every site host has a name source (sites.yaml field host)", all(s.get("host") for s in sites))
check("the SSO host is a certificate name under gitops/workloads (the lab_hosts role reads it there)", sso_host in certs)
role = (R / "ansible/roles/lab_hosts/tasks/main.yml").read_text(encoding="utf-8")
check("lab_hosts reads sites.yaml and the certificates", "lab_hosts_sites_file" in role and "lab_hosts_cert_file" in role)
sys.exit(1 if bad else 0)
PY

echo
echo "$n checks, $fail failures"
[ "$fail" = 0 ]
