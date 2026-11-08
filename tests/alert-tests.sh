#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
# Tests for the alerts of issue #8 (scripts/lab-alert.py), without a cluster, a Synapse or a desktop:
# kubectl, notify-send, logger and sops are stubs on the PATH; rustfs, the Matrix homeserver and the edge are
# small local servers (the edge with a throw-away CA and TLS).
#   1. config errors; unknown sink
#   2. sinks: file, exec, journal, desktop, matrix (path, token header, body; token never printed), fallback rules
#   3. checks: rustfs, cnpg, k8up, replica, edge (green and every way of failing)
#   4. run: alert once, no repeat, reminder after repeat_hours, recovery message, no state loss when nothing is delivered
#   5. the repo: Matrix is off by default, one place for the values, clusters match gitops/, syntax check
# Usage: bash tests/alert-tests.sh [repo root]
set -u
export PYTHONDONTWRITEBYTECODE=1
R=$(cd "${1:-$(dirname "${BASH_SOURCE[0]}")/..}" && pwd -P)
mkdir -p "$HOME/.cache/lab-sh-tests"
T=$(mktemp -d -p "$HOME/.cache/lab-sh-tests")
SRV_PIDS=""
cleanup() {
  local p
  for p in $SRV_PIDS; do kill "$p" 2> /dev/null; done
  rm -rf "$T"
}
trap cleanup EXIT
fail=0
n=0
ok() { n=$((n + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else echo "FAIL $1 (is '$2', want '$3')"; fail=$((fail + 1)); fi; }
has() { grep -Fq -- "$2" "$3"; local r=$?; ok "$1" "$r" 0; [ "$r" = 0 ] || sed "s/^/       | /" "$3" 2>/dev/null | tail -8; }
hasnot() { ! grep -Fq -- "$2" "$3"; ok "$1" "$?" 0; }
LA="$R/scripts/lab-alert.py"

# ---------- stubs
mkdir -p "$T/bin" "$T/kube"
cat > "$T/bin/notify-send" << 'SH'
#!/usr/bin/env bash
[ -e "$FAKE_DIR/desktop-broken" ] && { echo "no bus" >&2; exit 1; }
echo "$*" >> "$FAKE_DIR/desktop.log"
SH
cat > "$T/bin/logger" << 'SH'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_DIR/journal.log"
SH
cat > "$T/bin/sops" << 'SH'
#!/usr/bin/env bash
[ -e "$FAKE_DIR/sops-broken" ] && { echo "cannot decrypt" >&2; exit 128; }
case "$*" in
  *'["ping_url"]'*) cat "$FAKE_DIR/hb-ping.url"; exit 0 ;;
  *'["fail_url"]'*) cat "$FAKE_DIR/hb-fail.url"; exit 0 ;;
esac
echo "SECRET-TOKEN-VALUE"
SH
cat > "$T/bin/kubectl" << 'SH'
#!/usr/bin/env bash
[ -e "$FAKE_DIR/kube-down" ] && { echo "The connection to the server was refused" >&2; exit 1; }
case "$*" in
  *backups.postgresql.cnpg.io*) cat "$FAKE_DIR/kube/cnpg.json" ;;
  *backups.k8up.io*) cat "$FAKE_DIR/kube/k8up.json" ;;
  *) echo "{}" ;;
esac
SH
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH" FAKE_DIR="$T"

# ---------- servers: HTTP (rustfs health + Matrix) and HTTPS (edge)
cat > "$T/srv-http.py" << 'PY'
import http.server, json, os, sys
d = os.environ["FAKE_DIR"]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path.startswith("/hb"):
            with open(d + "/heartbeat.log", "a") as f:
                f.write(self.path + "\n")
            code = 500 if os.path.exists(d + "/heartbeat-down") else 200
            self.send_response(code); self.end_headers(); self.wfile.write(b"ok")
            return
        code = 503 if os.path.exists(d + "/rustfs-down") else 200
        self.send_response(code); self.end_headers(); self.wfile.write(b"ok")
    def do_PUT(self):
        n = int(self.headers.get("Content-Length", 0)); body = self.rfile.read(n).decode()
        with open(d + "/matrix.log", "a") as f:
            f.write(json.dumps({"path": self.path, "auth": self.headers.get("Authorization"), "body": body}) + "\n")
        code = 403 if os.path.exists(d + "/matrix-denied") else 200
        self.send_response(code); self.end_headers(); self.wfile.write(b"{}")
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(d + "/http.port", "w").write(str(s.server_port))
s.serve_forever()
PY
cat > "$T/srv-https.py" << 'PY'
import http.server, os, ssl
d = os.environ["FAKE_DIR"]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        mode = open(d + "/edge-mode").read().strip() if os.path.exists(d + "/edge-mode") else "ok"
        self.send_response(404 if mode == "404" else 200); self.end_headers()
        self.wfile.write(b"nothing" if mode == "other" else b"Hostname: whoami-123\n")
s = http.server.HTTPServer(("127.0.0.1", 0), H)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(d + "/srv.crt", d + "/srv.key")
s.socket = ctx.wrap_socket(s.socket, server_side=True)
open(d + "/https.port", "w").write(str(s.server_port))
s.serve_forever()
PY
HAVE_TLS=no
if command -v openssl > /dev/null; then
  (cd "$T" && openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.crt -subj "/CN=test-ca" -days 2 -addext "keyUsage=critical,keyCertSign,cRLSign" -addext "subjectKeyIdentifier=hash" > /dev/null 2>&1 \
    && openssl req -newkey rsa:2048 -nodes -keyout srv.key -out srv.csr -subj "/CN=whoami.lab.test" > /dev/null 2>&1 \
    && printf 'subjectAltName=DNS:whoami.lab.test\nauthorityKeyIdentifier=keyid\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n' > san.ext \
    && openssl x509 -req -in srv.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out srv.crt -days 2 -extfile san.ext > /dev/null 2>&1 \
    && openssl req -x509 -newkey rsa:2048 -nodes -keyout other.key -out other.crt -subj "/CN=other-ca" -days 2 > /dev/null 2>&1) && HAVE_TLS=yes
fi
python3 "$T/srv-http.py" & SRV_PIDS="$SRV_PIDS $!"
if [ "$HAVE_TLS" = yes ]; then python3 "$T/srv-https.py" & SRV_PIDS="$SRV_PIDS $!"; fi
for _ in $(seq 1 50); do [ -s "$T/http.port" ] && { [ "$HAVE_TLS" = no ] || [ -s "$T/https.port" ]; } && break; sleep 0.1; done
HP=$(cat "$T/http.port")
HSP=$(cat "$T/https.port" 2> /dev/null || echo 1)

NOW=1800000000
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
cnpg_json() { # age_hours ...: completed backups of gitea/gitea-db with these ages, plus one failed
  python3 - "$NOW" "$@" << 'PY'
import datetime, json, sys
now = int(sys.argv[1]); items = []
def iso(t): return datetime.datetime.fromtimestamp(t, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
for h in sys.argv[2:]:
    ns, name, age = h.split(":")
    items.append({"metadata": {"namespace": ns}, "spec": {"cluster": {"name": name}},
                  "status": {"phase": "completed", "stoppedAt": iso(now - int(float(age) * 3600))}})
items.append({"metadata": {"namespace": "gitea"}, "spec": {"cluster": {"name": "gitea-db"}}, "status": {"phase": "failed", "stoppedAt": iso(now - 10)}})
print(json.dumps({"items": items}))
PY
}
k8up_json() { # ns:age_hours:reason ...
  python3 - "$NOW" "$@" << 'PY'
import datetime, json, sys
now = int(sys.argv[1]); items = []
def iso(t): return datetime.datetime.fromtimestamp(t, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
for h in sys.argv[2:]:
    ns, age, reason = h.split(":")
    items.append({"metadata": {"namespace": ns}, "status": {"conditions": [
        {"type": "Completed", "status": "True", "reason": reason, "lastTransitionTime": iso(now - int(float(age) * 3600))}]}})
print(json.dumps({"items": items}))
PY
}
cnpg_json gitea:gitea-db:5 db-lab:pg-lab:6 > "$T/kube/cnpg.json"
k8up_json gitea:7:Succeeded > "$T/kube/k8up.json"
printf '#!/usr/bin/env bash\necho "{\\"ok\\": true, \\"detail\\": \\"last mirror 3 min ago\\"}"\n' > "$T/bin/replica-status"
chmod +x "$T/bin/replica-status"

# mkcfg OUTFILE [key=json ...] (nested keys: matrix.enabled=true)
mkcfg() {
  local out=$1; shift
  python3 - "$out" "$@" << PY
import json, sys
c = {"state_file": "$T/state.json", "sinks": ["file"], "fallback_sinks": ["desktop", "journal"], "repeat_hours": 24,
     "file_path": "$T/sink.log", "now": $NOW, "http_timeout": 3, "kubectl_bin": "kubectl", "kubectl_timeout": 10,
     "kubeconfig": "$T/kubeconfig",
     "cnpg": {"max_age_hours": 30, "clusters": [{"namespace": "gitea", "name": "gitea-db"}, {"namespace": "db-lab", "name": "pg-lab"}]},
     "k8up": {"max_age_hours": 30, "namespaces": ["gitea"]},
     "rustfs_url": "http://127.0.0.1:$HP/health",
     "replica": {"enabled": True, "argv": ["$T/bin/replica-status"], "timeout": 10},
     "edge": {"enabled": $([ "$HAVE_TLS" = yes ] && echo True || echo False), "ip": "127.0.0.1", "port": $HSP, "host": "whoami.lab.test", "ca_file": "$T/ca.crt", "expect": "Hostname"},
     "matrix": {"enabled": False, "homeserver": "http://127.0.0.1:$HP", "room_id": "!room:lab.test", "token_file": "$T/matrix.sops.yaml", "token_key": "token", "sops_bin": "sops"},
     "heartbeat": {"enabled": False, "url_file": "$T/hb.sops.yaml", "ping_url_key": "ping_url", "fail_url_key": "fail_url", "sops_bin": "sops", "age_key_file": ""},
     "desktop": {"bin": "notify-send"}, "exec_argv": []}
for kv in sys.argv[2:]:
    k, v = kv.split("=", 1)
    t = c
    *path, last = k.split(".")
    for p in path:
        t = t[p]
    t[last] = json.loads(v)
json.dump(c, open(sys.argv[1], "w"))
PY
}
rc() { "$@" > "$T/out" 2>&1; echo $?; }
reset() { rm -f "$T/state.json" "$T/sink.log" "$T/desktop.log" "$T/journal.log" "$T/matrix.log" "$T/heartbeat.log" "$T/desktop-broken" "$T/sops-broken" "$T/matrix-denied" "$T/rustfs-down" "$T/kube-down" "$T/edge-mode" "$T/heartbeat-down"; }
C="$T/cfg.json"
mkcfg "$C"

echo "== config"
ok "no config file: exit 2" "$(rc python3 "$LA" check --config "$T/none.json")" 2
mkcfg "$T/c1.json" 'sinks=["pager"]'
ok "unknown sink: exit 2" "$(rc python3 "$LA" check --config "$T/c1.json")" 2
has "unknown sink: message lists the known ones" "known: desktop, exec, file, journal, matrix" "$T/out"

echo "== sinks"
reset
ok "test with the file sink: exit 0" "$(rc python3 "$LA" test --config "$C")" 0
has "file sink wrote the alert" "k8s-lab test alert" "$T/sink.log"
ok "a sent alert needs no fallback" "$([ -e "$T/desktop.log" ] && echo used || echo unused)" unused
mkcfg "$T/s1.json" 'sinks=["matrix"]'
ok "matrix off: fallback is used, exit 0" "$(rc python3 "$LA" test --config "$T/s1.json")" 0
has "matrix off: says skipped" "matrix   skipped (not switched on)" "$T/out"
has "fallback desktop got it" "k8s-lab test alert" "$T/desktop.log"
has "fallback journal got it" "k8s-lab test alert" "$T/journal.log"
reset
mkcfg "$T/s2.json" 'sinks=["matrix"]' 'matrix.enabled=true'
ok "matrix on: exit 0" "$(rc python3 "$LA" test --config "$T/s2.json")" 0
has "matrix: path is the send endpoint of the room" "/_matrix/client/v3/rooms/%21room%3Alab.test/send/m.room.message/" "$T/matrix.log"
has "matrix: bearer token from sops" "Bearer SECRET-TOKEN-VALUE" "$T/matrix.log"
has "matrix: m.text body" 'msgtype' "$T/matrix.log"
hasnot "matrix: the token is not printed" "SECRET-TOKEN-VALUE" "$T/out"
ok "matrix delivered: no fallback" "$([ -e "$T/desktop.log" ] && echo used || echo unused)" unused
touch "$T/matrix-denied"
ok "matrix refused (403): fallback, exit 0" "$(rc python3 "$LA" test --config "$T/s2.json")" 0
has "matrix 403 is named" "homeserver answered 403" "$T/out"
has "fallback after a failure" "k8s-lab test alert" "$T/desktop.log"
rm -f "$T/matrix-denied" "$T/desktop.log"
touch "$T/sops-broken"
python3 "$LA" test --config "$T/s2.json" > "$T/out" 2>&1
has "sops failure is named" "cannot be decrypted" "$T/out"
hasnot "sops failure: still no token in the output" "SECRET-TOKEN-VALUE" "$T/out"
rm -f "$T/sops-broken"
mkcfg "$T/s3.json" 'sinks=["matrix"]' 'matrix.enabled=true' 'matrix.homeserver="http://127.0.0.1:1"'
python3 "$LA" test --config "$T/s3.json" > "$T/out" 2>&1
has "homeserver down (VPN off): clear message" "not reachable (VPN up?)" "$T/out"
mkcfg "$T/s4.json" 'sinks=["matrix"]' 'matrix.enabled=true' 'matrix.room_id=""'
python3 "$LA" test --config "$T/s4.json" > "$T/out" 2>&1
has "room id missing: clear message" "matrix.room_id is not set" "$T/out"
reset
touch "$T/desktop-broken"
mkcfg "$T/s5.json" 'sinks=["desktop"]'
ok "desktop broken, journal fallback: exit 0" "$(rc python3 "$LA" test --config "$T/s5.json")" 0
has "desktop failure is named" "no graphical session" "$T/out"
has "journal still got it" "k8s-lab test alert" "$T/journal.log"
mkcfg "$T/s6.json" 'sinks=["desktop"]' 'fallback_sinks=[]'
ok "nothing delivered: exit 1" "$(rc python3 "$LA" test --config "$T/s6.json")" 1
rm -f "$T/desktop-broken"
printf '#!/usr/bin/env bash\ncat > "$FAKE_DIR/exec.in"; echo "$K8S_LAB_ALERT_LEVEL" > "$FAKE_DIR/exec.level"\n' > "$T/bin/hook"; chmod +x "$T/bin/hook"
mkcfg "$T/s7.json" 'sinks=["exec"]' "exec_argv=[\"$T/bin/hook\"]"
ok "exec sink: exit 0" "$(rc python3 "$LA" test --config "$T/s7.json")" 0
has "exec sink: message on stdin" "k8s-lab test alert" "$T/exec.in"
has "exec sink: level in the environment" "info" "$T/exec.level"

echo "== checks"
reset
ok "all green: exit 0" "$(rc python3 "$LA" check --config "$C")" 0
has "rustfs ok" "OK   rustfs: HTTP 200" "$T/out"
has "cnpg ok" "OK   cnpg: all 2 clusters" "$T/out"
has "k8up ok" "OK   k8up: all 1 namespaces" "$T/out"
has "replica ok" "OK   replica: last mirror 3 min ago" "$T/out"
if [ "$HAVE_TLS" = yes ]; then has "edge ok" "OK   edge: HTTPS 200 from whoami.lab.test" "$T/out"; else echo "SKIP: openssl is missing (edge tests)"; fi
touch "$T/rustfs-down"
ok "rustfs 503: exit 1" "$(rc python3 "$LA" check --config "$C")" 1
has "rustfs 503: message" "FAIL rustfs: HTTP 503 from rustfs" "$T/out"
rm -f "$T/rustfs-down"
mkcfg "$T/k1.json" 'rustfs_url="http://127.0.0.1:1/health"'
python3 "$LA" check --config "$T/k1.json" > "$T/out" 2>&1
has "rustfs not reachable: message" "rustfs not reachable" "$T/out"
cnpg_json gitea:gitea-db:5 db-lab:pg-lab:40 > "$T/kube/cnpg.json"
ok "cnpg too old: exit 1" "$(rc python3 "$LA" check --config "$C")" 1
has "cnpg too old: names the cluster and the age" "db-lab/pg-lab: last backup 40.0 h ago (limit 30.0 h)" "$T/out"
cnpg_json gitea:gitea-db:5 > "$T/kube/cnpg.json"
python3 "$LA" check --config "$C" > "$T/out" 2>&1
has "cnpg: a cluster without any completed backup" "db-lab/pg-lab: no completed backup" "$T/out"
cnpg_json gitea:gitea-db:5 db-lab:pg-lab:6 > "$T/kube/cnpg.json"
k8up_json gitea:50:Succeeded > "$T/kube/k8up.json"
ok "k8up too old: exit 1" "$(rc python3 "$LA" check --config "$C")" 1
has "k8up too old: message" "gitea: last K8up backup 50.0 h ago" "$T/out"
k8up_json gitea:1:Failed > "$T/kube/k8up.json"
python3 "$LA" check --config "$C" > "$T/out" 2>&1
has "k8up: a failed backup does not count" "gitea: no successful K8up backup" "$T/out"
k8up_json gitea:7:Succeeded > "$T/kube/k8up.json"
touch "$T/kube-down"
python3 "$LA" check --config "$C" > "$T/out" 2>&1
has "cluster down: cnpg says so" "FAIL cnpg: kubectl failed (exit 1: The connection to the server was refused), is the cluster up?" "$T/out"
has "cluster down: k8up says so" "FAIL k8up: kubectl failed" "$T/out"
rm -f "$T/kube-down"
printf '#!/usr/bin/env bash\necho "{\\"ok\\": false, \\"detail\\": \\"last mirror 400 min ago, limit 180 min\\"}"; exit 1\n' > "$T/bin/replica-status"
ok "replica too old: exit 1" "$(rc python3 "$LA" check --config "$C")" 1
has "replica too old: detail comes through" "FAIL replica: last mirror 400 min ago" "$T/out"
printf '#!/usr/bin/env bash\necho garbage; exit 3\n' > "$T/bin/replica-status"
python3 "$LA" check --config "$C" > "$T/out" 2>&1
has "replica status unreadable is a failure" "replica status unreadable (exit 3" "$T/out"
printf '#!/usr/bin/env bash\necho "{\\"ok\\": true, \\"detail\\": \\"last mirror 3 min ago\\"}"\n' > "$T/bin/replica-status"
if [ "$HAVE_TLS" = yes ]; then
  echo 404 > "$T/edge-mode"
  python3 "$LA" check --config "$C" > "$T/out" 2>&1
  has "edge 404" "FAIL edge: edge answered HTTP 404" "$T/out"
  echo other > "$T/edge-mode"
  python3 "$LA" check --config "$C" > "$T/out" 2>&1
  has "edge 200 but not whoami" "not with Hostname" "$T/out"
  rm -f "$T/edge-mode"
  mkcfg "$T/e1.json" "edge.ca_file=\"$T/other.crt\""
  python3 "$LA" check --config "$T/e1.json" > "$T/out" 2>&1
  has "edge with the wrong CA" "TLS problem at the edge" "$T/out"
  mkcfg "$T/e2.json" 'edge.port=1'
  python3 "$LA" check --config "$T/e2.json" > "$T/out" 2>&1
  has "edge not reachable" "edge not reachable at 127.0.0.1:1" "$T/out"
fi
mkcfg "$T/e3.json" 'edge.enabled=false' 'replica.enabled=false'
python3 "$LA" check --config "$T/e3.json" > "$T/out" 2>&1
has "switched-off checks pass and say so" "OK   replica: replica not switched on" "$T/out"
ok "--only runs one check" "$(python3 "$LA" check --config "$C" --only rustfs | wc -l)" 1

echo "== run: state, dedupe, recovery"
reset
ok "healthy run: exit 0" "$(rc python3 "$LA" run --config "$C")" 0
ok "healthy run: no alert" "$([ -e "$T/sink.log" ] && echo alert || echo none)" none
touch "$T/rustfs-down"
ok "failing run: exit 1" "$(rc python3 "$LA" run --config "$C")" 1
has "first failure is alerted" "ALERT k8s-lab ALARM: rustfs -> file sent" "$T/out"
ok "one alert line in the sink" "$(wc -l < "$T/sink.log")" 1
python3 "$LA" run --config "$C" > "$T/out" 2>&1
ok "second run: no second alert" "$(wc -l < "$T/sink.log")" 1
python3 "$LA" status --config "$C" > "$T/out" 2>&1
has "status shows the failing check" "rustfs   FAILING since" "$T/out"
mkcfg "$T/r1.json" "now=$(( NOW + 25 * 3600 ))" 'cnpg.clusters=[]' 'k8up.namespaces=[]' 'replica.enabled=false' 'edge.enabled=false'
python3 "$LA" run --config "$T/r1.json" > "$T/out" 2>&1
ok "after repeat_hours: one reminder" "$(wc -l < "$T/sink.log")" 2
has "reminder wording" "still failing: rustfs" "$T/sink.log"
rm -f "$T/rustfs-down"
python3 "$LA" run --config "$T/r1.json" > "$T/out" 2>&1
ok "recovery: message sent" "$(wc -l < "$T/sink.log")" 3
has "recovery wording" "k8s-lab OK again: rustfs" "$T/sink.log"
python3 "$LA" run --config "$T/r1.json" > "$T/out" 2>&1
ok "recovered stays quiet" "$(wc -l < "$T/sink.log")" 3
echo "-- nothing delivered keeps the failure pending"
reset
touch "$T/rustfs-down" "$T/desktop-broken"
mkcfg "$T/n1.json" 'sinks=["desktop"]' 'fallback_sinks=[]'
python3 "$LA" run --config "$T/n1.json" > "$T/out" 2>&1
ok "undelivered alert is not remembered" "$(python3 -c "import json; print('rustfs' in json.load(open('$T/state.json')))")" False
rm -f "$T/desktop-broken"
python3 "$LA" run --config "$T/n1.json" > "$T/out" 2>&1
has "next run delivers it" "ALERT k8s-lab ALARM: rustfs -> desktop sent" "$T/out"
reset

echo "== maintenance marker (issue #21): lab.sh rebuilds the VM on purpose"
reset
MF="$T/maintenance.json"
rm -f "$MF"
mkmark() { # mkmark STARTED_OFFSET_SECONDS PID [COMMAND]  (offset is relative to the fake clock)
  python3 -c "import json,sys; json.dump({'pid': int(sys.argv[2]), 'started': $NOW + int(sys.argv[1]), 'command': sys.argv[3]}, open('$MF', 'w'))" "$1" "$2" "${3:-rebuild}"
}
mkcfg "$T/m1.json" "maintenance_file=\"$MF\""
mfail() { reset; touch "$T/rustfs-down" "$T/kube-down"; } # everything is down, as while the VM is gone
mfail
ok "no marker: the failing check is still alerted" "$(rc python3 "$LA" run --config "$T/m1.json")" 1
ok "no marker: alerts sent" "$([ -s "$T/sink.log" ] && echo alert || echo none)" alert
mfail
mkmark -600 $$
ok "valid marker: run exits 0 although everything fails" "$(rc python3 "$LA" run --config "$T/m1.json")" 0
has "valid marker: says maintenance and names the command" "MAINTENANCE: lab.sh rebuild (pid $$)" "$T/out"
ok "valid marker: no alert" "$([ -e "$T/sink.log" ] && echo alert || echo none)" none
ok "valid marker: no fallback sink either" "$([ -e "$T/desktop.log" ] && echo used || echo unused)" unused
ok "valid marker: no state written" "$([ -e "$T/state.json" ] && echo state || echo none)" none
python3 "$LA" status --config "$T/m1.json" > "$T/out" 2>&1
has "status shows the maintenance" "maintenance: ACTIVE, lab.sh rebuild" "$T/out"
ok "check does not honour the marker (manual run shows the truth)" "$(rc python3 "$LA" check --config "$T/m1.json")" 1
ok "test does not honour the marker" "$(rc python3 "$LA" test --config "$T/m1.json")" 0
has "test still sent" "k8s-lab test alert" "$T/sink.log"
mfail
mkmark -$((4 * 3600)) $$
ok "marker older than the limit (3 h): alerts work again" "$(rc python3 "$LA" run --config "$T/m1.json")" 1
has "old marker: says so" "ignored" "$T/out"
ok "old marker: alert sent" "$([ -s "$T/sink.log" ] && echo alert || echo none)" alert
mfail
mkcfg "$T/m2.json" "maintenance_file=\"$MF\"" 'maintenance_max_hours=6'
mkmark -$((4 * 3600)) $$
ok "limit is configurable (6 h): still paused at 4 h" "$(rc python3 "$LA" run --config "$T/m2.json")" 0
mfail
dead=999999; while kill -0 "$dead" 2> /dev/null; do dead=$((dead + 1)); done
mkmark -60 "$dead"
ok "marker of a dead process (lab.sh was killed): alerts work again" "$(rc python3 "$LA" run --config "$T/m1.json")" 1
has "dead process: says so" "process is gone, ignored" "$T/out"
mfail
mkmark 600 $$
ok "marker from the future (clock or file wrong): ignored" "$(rc python3 "$LA" run --config "$T/m1.json")" 1
mfail
printf 'garbage' > "$MF"
ok "unreadable marker: fails open, alerts work" "$(rc python3 "$LA" run --config "$T/m1.json")" 1
has "unreadable marker: says so" "is unreadable, ignored" "$T/out"
mfail
printf '{"pid": 1}' > "$MF"
ok "marker without a start time: fails open" "$(rc python3 "$LA" run --config "$T/m1.json")" 1
mfail
mkcfg "$T/m3.json" 'maintenance_file=""'
mkmark -60 $$
ok "no maintenance_file in the config: marker ignored" "$(rc python3 "$LA" run --config "$T/m3.json")" 1
mfail
mkmark -60 $$
python3 "$LA" run --config "$T/m1.json" > /dev/null 2>&1
rm -f "$MF" "$T/rustfs-down" "$T/kube-down"
ok "after the marker is gone: normal run, exit 0" "$(rc python3 "$LA" run --config "$T/m1.json")" 0
ok "a paused run left no failing state behind" "$([ -e "$T/sink.log" ] && echo alert || echo none)" none
reset

echo "== heartbeat (external ping, issue #8 decision 2026-11-06)"
printf 'http://127.0.0.1:%s/hb\n' "$HP" > "$T/hb-ping.url"
printf 'http://127.0.0.1:%s/hb/fail\n' "$HP" > "$T/hb-fail.url"
printf 'ping_url: placeholder\nfail_url: placeholder\n' > "$T/hb.sops.yaml"
reset
mkcfg "$T/h0.json"
ok "heartbeat off: subcommand exits 1" "$(rc python3 "$LA" heartbeat --config "$T/h0.json")" 1
has "heartbeat off: says disabled" "disabled" "$T/out"
reset
mkcfg "$T/h1.json" 'heartbeat.enabled=true' 'cnpg.clusters=[]' 'k8up.namespaces=[]' 'replica.enabled=false' 'edge.enabled=false'
ok "heartbeat on: ping exits 0" "$(rc python3 "$LA" heartbeat --config "$T/h1.json")" 0
has "heartbeat on: says ok" "HEARTBEAT ok" "$T/out"
ok "heartbeat on: HTTP hit the ping path" "$(grep -c '^/hb$' "$T/heartbeat.log" 2>/dev/null || echo 0)" 1
reset
mkcfg "$T/h2.json" 'heartbeat.enabled=true' 'cnpg.clusters=[]' 'k8up.namespaces=[]' 'replica.enabled=false' 'edge.enabled=false'
ok "run with heartbeat: exit 0 and ping" "$(rc python3 "$LA" run --config "$T/h2.json")" 0
has "run with heartbeat: HEARTBEAT ok" "HEARTBEAT ok" "$T/out"
ok "run with heartbeat: ping logged" "$(grep -c '^/hb$' "$T/heartbeat.log" 2>/dev/null || echo 0)" 1
reset
touch "$T/rustfs-down"
mkcfg "$T/h3.json" 'heartbeat.enabled=true' 'cnpg.clusters=[]' 'k8up.namespaces=[]' 'replica.enabled=false' 'edge.enabled=false'
ok "failing run still pings and hits fail URL" "$(rc python3 "$LA" run --config "$T/h3.json")" 1
has "failing run: HEARTBEAT ok (ping + fail)" "ping + fail" "$T/out"
ok "failing run: fail path logged" "$(grep -c '^/hb/fail$' "$T/heartbeat.log" 2>/dev/null || echo 0)" 1
rm -f "$T/rustfs-down"
reset
MF="$T/maint.json"
mkcfg "$T/h4.json" 'heartbeat.enabled=true' "maintenance_file=\"$MF\"" 'cnpg.clusters=[]' 'k8up.namespaces=[]' 'replica.enabled=false' 'edge.enabled=false'
python3 -c "import json,sys; json.dump({'pid': int(sys.argv[1]), 'started': $NOW - 60, 'command': 'lab.sh rebuild'}, open(sys.argv[2], 'w'))" "$$" "$MF"
ok "maintenance: run exits 0" "$(rc python3 "$LA" run --config "$T/h4.json")" 0
has "maintenance: says MAINTENANCE" "MAINTENANCE:" "$T/out"
has "maintenance: still pings heartbeat" "HEARTBEAT ok" "$T/out"
rm -f "$MF"
reset
has "repo: heartbeat off by default" "backup_alert_heartbeat_enabled: false" "$R/ansible/inventory/group_vars/all/alert.yml"
has "repo: heartbeat URL is a SOPS file" "alert_heartbeat_url_file:" "$R/ansible/inventory/group_vars/all/alert.yml"
has "repo: role renders heartbeat" '"heartbeat"' "$R/ansible/roles/backup_alert/templates/alert.json.j2"
has "repo: ADR 0028 exists" "Externer Heartbeat" "$R/docs/concepts/decisions/0028-external-heartbeat.md"

echo "== the repo"
GV="$R/ansible/inventory/group_vars/all/alert.yml"
has "matrix is off by default" "backup_alert_matrix_enabled: false" "$GV"
has "the token is a SOPS file" "alert_matrix_token_file:" "$GV"
has "the fallback is desktop and journal" "backup_alert_fallback_sinks: [desktop, journal]" "$GV"
for c in "gitea-db" "pg-lab" "matrix-db"; do
  grep -rq "name: $c$" "$R/gitops/workloads"; ok "cluster $c from alert.yml exists in gitops/" "$?" 0
  grep -q "name: $c }" "$GV"; ok "cluster $c is in alert.yml" "$?" 0
done
for f in lab-alert.py lab-replica.py; do
  python3 -m py_compile "$R/scripts/$f" 2> "$T/out"; ok "$f compiles" "$?" 0
done
has "alert.yml defines the maintenance marker" "backup_alert_maintenance_file:" "$GV"
has "the role renders the maintenance marker" "maintenance_file" "$R/ansible/roles/backup_alert/templates/alert.json.j2"
has "the role renders the maintenance limit" "maintenance_max_hours" "$R/ansible/roles/backup_alert/templates/alert.json.j2"
has "lab_values hands the marker path to lab.sh" "alert_maintenance_file:" "$R/ansible/inventory/group_vars/all/lab.yml"
has "the role renders every sink from the variables" "backup_alert_fallback_sinks" "$R/ansible/roles/backup_alert/templates/alert.json.j2"
if command -v ansible-playbook > /dev/null; then
  (cd "$R/ansible" && ansible-playbook --syntax-check backup-alert.yml verify-alerts.yml > "$T/out" 2>&1); ok "alert playbooks syntax check" "$?" 0
else
  echo "SKIP: ansible-playbook is missing"
fi

echo
echo "$n checks, $fail failures"
[ "$fail" = 0 ]
