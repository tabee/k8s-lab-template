#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
# Offline tests for scripts/gitea-import.sh and its helpers. No cluster, no network, no real docker:
#   1. static: bash -n, shellcheck (if installed), python syntax, executable bits
#   2. option parsing of gitea-import.sh and the lab.sh dispatch (usage errors exit 2, help works)
#   3. version helpers (version_ge, version_of) taken from the script itself
#   4. dump-tool.py on a small generated tar: meta, inspect (sqlite/postgres, LFS), select, unsafe names refused
#   5. pods.py: restricted pods, no service account token, label that matches the existing NetworkPolicies
#   6. filter.sql: drops webhooks, tokens, mirrors, ...; keeps users and repositories; every table guarded
#   7. gitea-import-vps-dump.sh with a fake docker: only read-only docker calls, temp dir removed, age round trip
# The full run against a real Gitea and k3s is MANUAL: scripts/gitea-import-e2e.sh (needs Docker).
# Needs: bash, python3. Optional: shellcheck, age (a suite part whose tool is missing prints SKIP).
# Usage: bash tests/gitea-import-tests.sh [repo root]
set -u
export PYTHONDONTWRITEBYTECODE=1
R=$(cd "${1:-$(dirname "${BASH_SOURCE[0]}")/..}" && pwd -P)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail=0
n=0
ok() { n=$((n + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else echo "FAIL $1 (actual '$2', expected '$3')"; fail=$((fail + 1)); fi; }
skip() { echo "SKIP $1"; }
has() { grep -Fq -- "$2" "$3"; ok "$1" "$?" 0; }
hasnt() { grep -Fq -- "$2" "$3"; ok "$1" "$?" 1; }
S=$R/scripts/gitea-import.sh
V=$R/scripts/gitea-import-vps-dump.sh
D=$R/scripts/gitea-import/dump-tool.py

if [ ! -f "$S" ]; then echo "SKIP gitea-import is not part of this tree"; exit 0; fi

# ---------------------------------------------------------------- 1. static
for f in "$S" "$V" "$R/scripts/gitea-import-e2e.sh"; do
  bash -n "$f" 2> "$T/err"; ok "bash -n $(basename "$f")" "$?" 0
done
for f in "$D" "$R/scripts/gitea-import/pods.py"; do
  python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$f"; ok "python syntax $(basename "$f")" "$?" 0
done
if command -v shellcheck > /dev/null 2>&1; then
  shellcheck -S warning "$S" "$V" "$R/scripts/gitea-import-e2e.sh" > "$T/sc" 2>&1; ok "shellcheck (warning) on the gitea-import scripts" "$?" 0
else
  skip "shellcheck not installed"
fi
ok "gitea-import.sh is executable" "$([ -x "$S" ] && echo 0 || echo 1)" 0
ok "gitea-import-vps-dump.sh is executable" "$([ -x "$V" ] && echo 0 || echo 1)" 0

# ---------------------------------------------------------------- 2. option parsing
rc() { "$@" > "$T/out" 2>&1; echo $?; }
ok "no argument: usage, exit 2" "$(rc bash "$S")" 2
has "usage text names recipients" "recipients" "$T/out"
ok "--help: exit 2 (usage), names --replace" "$(rc bash "$S" --help)" 2
has "help names --replace" "--replace" "$T/out"
ok "unknown option: exit 2" "$(rc bash "$S" --bogus x.age)" 2
has "unknown option is named" "unknown option: --bogus" "$T/out"
ok "--yes without --replace: exit 2" "$(rc bash "$S" --yes x.age)" 2
has "--yes message" "--yes only answers the question of --replace" "$T/out"
ok "recipients with a dump file: exit 2" "$(rc bash "$S" recipients x.age)" 2
ok "accept with --replace: exit 2" "$(rc bash "$S" accept --replace)" 2
ok "two dump files: exit 2" "$(rc bash "$S" a.age b.age)" 2
has "two dump files message" "more than one dump file" "$T/out"
ok "option without value: exit 2" "$(rc bash "$S" --base-url)" 2
mkdir -p "$T/bin"
printf '#!/bin/sh\necho "fake kubectl: no cluster" >&2\nexit 1\n' > "$T/bin/kubectl"
chmod +x "$T/bin/kubectl"
ok "no cluster: clear error, exit 1" "$(PATH="$T/bin:$PATH" rc bash "$S" x.age)" 1
has "no cluster message" "namespace gitea not reachable" "$T/out"
# recipients works offline (public export: .sops.yaml may carry no age key; then it says so)
out=$(bash "$S" recipients 2>&1); code=$?
if [ "$code" = 0 ]; then
  ok "recipients prints the VPS command" "$(printf '%s' "$out" | grep -c 'gitea-import-vps-dump.sh')" 2
  printf '%s' "$out" | grep -q 'age1' ; ok "recipients names an age key" "$?" 0
else
  printf '%s' "$out" | grep -q 'no age recipient'; ok "recipients: no key in .sops.yaml says so" "$?" 0
fi
# lab.sh passes the options through and needs no cluster for recipients
ok "lab.sh gitea-import recipients" "$(rc bash "$R/scripts/lab.sh" gitea-import recipients)" "$code"
ok "lab.sh gitea-import --help: exit 2 (usage of the script)" "$(rc bash "$R/scripts/lab.sh" gitea-import --help)" 2
has "lab.sh header names gitea-import" "lab.sh gitea-import" "$R/scripts/lab.sh"

# ---------------------------------------------------------------- 3. version helpers
fn() { sed -n "/^$1()/p" "$S"; }
{ fn version_ge; fn version_of; } > "$T/fns.sh"
# shellcheck disable=SC1091
. "$T/fns.sh"
version_ge 1.27.3 1.27.3; ok "lab 1.27.3 >= dump 1.27.3" "$?" 0
version_ge 1.27.10 1.27.3; ok "1.27.10 >= 1.27.3 (numeric, not text order)" "$?" 0
version_ge 1.28.0 1.27.9; ok "1.28.0 >= 1.27.9" "$?" 0
version_ge 1.26.4 1.27.0; ok "lab 1.26.4 < dump 1.27.0: refused" "$?" 1
version_ge 1.9.9 1.10.0; ok "1.9.9 < 1.10.0" "$?" 1
ok "version_of: image tag with registry" "$(version_of 'docker.gitea.com/gitea:1.27.3-rootless')" 1.27.3
ok "version_of: --version output" "$(version_of 'Gitea version 1.26.4 built with go1.25')" 1.26.4
ok "version_of: latest has no version" "$(version_of 'gitea:latest')" ""

# ---------------------------------------------------------------- 4. dump-tool
python3 - "$T" << 'PY'
import io, json, sys, tarfile
t = sys.argv[1]

def add(tf, name, data=b"x", typ=None):
    i = tarfile.TarInfo(name)
    i.size = len(data)
    tf.addfile(i, io.BytesIO(data))

def build(path, db_type, lfs, evil=None):
    with tarfile.open(path, "w", format=tarfile.GNU_FORMAT) as tf:
        add(tf, "gitea-import-meta.json", json.dumps({"format": 1, "gitea_version": "1.27.3", "db_type": db_type}).encode())
        add(tf, "gitea-db.sql", b'CREATE TABLE "public"."user" (id int);\n')
        add(tf, "app.ini", ("[database]\nDB_TYPE = %s\nPASSWD = TOPSECRETVALUE\n" % db_type).encode())
        add(tf, "repos/alice/notes.git/HEAD", b"ref: refs/heads/main\n")
        add(tf, "data/avatars/a1", b"png")
        add(tf, "data/jwt/private.pem", b"KEY")
        add(tf, "data/indexers/x", b"idx")
        if lfs:
            add(tf, "data/lfs/ab/cd/ef", b"obj")
        if evil:
            add(tf, evil, b"evil")

build(t + "/pg.tar", "postgres", True)
build(t + "/sq.tar", "sqlite3", False)
build(t + "/evil.tar", "postgres", False, "repos/../../etc/evil")
PY
ok "dump-tool meta" "$(python3 "$D" meta "$T/pg.tar" | python3 -c 'import json,sys; print(json.load(sys.stdin)["gitea_version"])')" 1.27.3
python3 "$D" inspect "$T/pg.tar" > "$T/ins" 2>&1; ok "inspect postgres dump: exit 0" "$?" 0
has "inspect: dump_db_type=postgres" "dump_db_type=postgres" "$T/ins"
has "inspect: has_lfs=1 or true" "has_lfs=" "$T/ins"
hasnt "inspect never prints the password value" "TOPSECRETVALUE" "$T/ins"
python3 "$D" inspect "$T/sq.tar" > "$T/ins2" 2>&1
has "inspect sqlite dump: dump_db_type" "dump_db_type=sqlite3" "$T/ins2"
python3 "$D" sql "$T/pg.tar" > "$T/db.sql"; has "sql member extracted" 'CREATE TABLE "public"."user"' "$T/db.sql"
python3 "$D" select "$T/pg.tar" | tar -tf - | sort > "$T/sel"
has "select keeps repos" "repos/alice/notes.git/HEAD" "$T/sel"
has "select keeps LFS under lfs/" "lfs/ab/cd/ef" "$T/sel"
has "select keeps avatars" "avatars/a1" "$T/sel"
hasnt "select leaves out jwt keys" "jwt" "$T/sel"
hasnt "select leaves out the indexer" "indexers" "$T/sel"
hasnt "select leaves out app.ini" "app.ini" "$T/sel"
python3 "$D" select "$T/evil.tar" > /dev/null 2> "$T/ev"; ok "unsafe member name: exit 3" "$?" 3
python3 "$D" inspect "$T/evil.tar" > /dev/null 2>&1; ok "unsafe member name refused by inspect too" "$?" 3

# ---------------------------------------------------------------- 5. pods.py
P=$R/scripts/gitea-import/pods.py
python3 "$P" db "img@sha256:abc" gitea-db-rw 5432 gitea require gitea-db-owner > "$T/dbpod.json"; ok "pods.py db: exit 0" "$?" 0
python3 - "$T/dbpod.json" << 'PY'
import json, sys
p = json.load(open(sys.argv[1]))
s = p["spec"]
c = s["containers"][0]
checks = {
    "kind Pod": p["kind"] == "Pod",
    "namespace not hard-coded or gitea": p["metadata"].get("namespace") in (None, "gitea"),
    "label gitea-import": p["metadata"]["labels"]["app.kubernetes.io/name"] == "gitea-import",
    "no service account token": s["automountServiceAccountToken"] is False,
    "runAsNonRoot": s["securityContext"]["runAsNonRoot"] is True,
    "drop ALL": c["securityContext"]["capabilities"]["drop"] == ["ALL"],
    "no privilege escalation": c["securityContext"]["allowPrivilegeEscalation"] is False,
    "image by digest": "@sha256:" in c["image"],
    "password from a secret, not inline": any("secretKeyRef" in e.get("valueFrom", {}) for e in c["env"]) and not any("value" in e and "PASS" in e["name"] for e in c["env"]),
}
bad = [k for k, v in checks.items() if not v]
print("\n".join(("OK   pods.py db: " if v else "FAIL pods.py db: ") + k for k, v in checks.items()))
sys.exit(1 if bad else 0)
PY
[ $? = 0 ] || fail=$((fail + 1))
n=$((n + 9))
cat > "$T/dep.json" << 'JSON'
{"spec":{"template":{"spec":{"securityContext":{"fsGroup":1000},
 "containers":[{"name":"gitea","image":"gitea/gitea@sha256:abc","ports":[{"containerPort":3000}],
  "env":[{"name":"A","value":"b"}],"volumeMounts":[{"name":"data","mountPath":"/data"}],
  "livenessProbe":{},"readinessProbe":{}}],
 "volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"gitea-shared-storage"}},{"name":"unused","emptyDir":{}}]}}}}
JSON
python3 "$P" files gitea-db-owner < "$T/dep.json" > "$T/fpod.json"; ok "pods.py files: exit 0" "$?" 0
python3 - "$T/fpod.json" << 'PY'
import json, sys
p = json.load(open(sys.argv[1]))
s = p["spec"]; c = s["containers"][0]
checks = {
    "same image as the live pod": c["image"] == "gitea/gitea@sha256:abc",
    "only sleeps (no gitea process)": c["command"][0] == "sleep",
    "no probes, no ports": not any(k in c for k in ("livenessProbe", "readinessProbe", "ports")),
    "mounts the live PVC": any(v.get("persistentVolumeClaim") for v in s["volumes"]),
    "unused volume left out": all(v["name"] != "unused" for v in s["volumes"]),
    "label gitea-import (not gitea)": p["metadata"]["labels"]["app.kubernetes.io/name"] == "gitea-import",
    "no service account token": s["automountServiceAccountToken"] is False,
    "DB credentials come from the secret": sum("secretKeyRef" in e.get("valueFrom", {}) for e in c["env"]) == 2,
}
print("\n".join(("OK   pods.py files: " if v else "FAIL pods.py files: ") + k for k, v in checks.items()))
sys.exit(0 if all(checks.values()) else 1)
PY
[ $? = 0 ] || fail=$((fail + 1))
n=$((n + 8))
python3 "$P" > /dev/null 2>&1; ok "pods.py without arguments: exit 2" "$?" 2

# ---------------------------------------------------------------- 6. filter.sql
F=$R/scripts/gitea-import/filter.sql
for t in webhook hook_task access_token two_factor public_key mirror push_mirror secret package_version oauth2_application; do
  has "filter.sql drops $t" "'$t'" "$F"
done
# the data to keep must not be in the drop list (the list is the ARRAY[...] block)
awk '/names text\[\] := ARRAY\[/,/\];/' "$F" > "$T/droplist"
for t in user repository team org_user access collaboration issue release lfs_meta_object; do
  grep -Eq "'$t'" "$T/droplist"; ok "filter.sql keeps $t (not in the drop list)" "$?" 1
done
has "filter.sql guards by to_regclass" "to_regclass" "$F"
has "template repositories are handled (is_template)" "is_template" "$R/scripts/gitea-import.sh"

# ---------------------------------------------------------------- 7. VPS dump script with a fake docker
# fake docker: records every call; answers ps/inspect/exec; `gitea dump` writes a tar to stdout
mkdir -p "$T/vps/bin" "$T/vps/work/dumpsrc/repos/alice/notes.git"
echo "ref: refs/heads/main" > "$T/vps/work/dumpsrc/repos/alice/notes.git/HEAD"
echo 'CREATE TABLE "public"."user" (id int);' > "$T/vps/work/dumpsrc/gitea-db.sql"
printf '[database]\nDB_TYPE = sqlite3\n' > "$T/vps/work/dumpsrc/app.ini"
cat > "$T/vps/bin/docker" << 'EOF'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_DOCKER_LOG"
case "$1" in
  ps) printf '%s\n' "$FAKE_PS" ;;
  inspect) echo true ;;
  exec)
    shift; [ "$1" = -u ] && shift 2; shift  # drop: -u git CONTAINER
    case "$1" in
      gitea)
        if [ "$2" = --version ]; then echo "Gitea version 1.27.3 built with go1.25 : bindata"
        elif [ "$2" = dump ]; then tar -C "$FAKE_DUMP_SRC" -cf - gitea-db.sql app.ini repos
        else exit 9; fi ;;
      mktemp) mkdir -p "$FAKE_TMP" && echo "$FAKE_TMP" ;;
      rm) shift; shift; rm -rf "$@"; echo "removed $*" >> "$FAKE_DOCKER_LOG" ;;
      sh) echo sqlite3 ;;
      *) exit 9 ;;
    esac ;;
  *) echo "unexpected docker subcommand: $1" >> "$FAKE_DOCKER_LOG"; exit 9 ;;
esac
EOF
chmod +x "$T/vps/bin/docker"
export FAKE_DOCKER_LOG=$T/vps/docker.log FAKE_DUMP_SRC=$T/vps/work/dumpsrc FAKE_TMP=$T/vps/tmpdump
vrun() { PATH="$T/vps/bin:$PATH" FAKE_PS="${FAKE_PS:-gitea_gitea.1.abc docker.gitea.com/gitea:1.27.3}" "$@"; }
: > "$FAKE_DOCKER_LOG"
ok "vps --check: exit 0, nothing dumped" "$(vrun rc bash "$V" --check)" 0
has "vps --check finds the container" "container=gitea_gitea.1.abc version=1.27.3 db_type=sqlite3" "$T/out"
hasnt "vps --check ran no dump" "dump" "$FAKE_DOCKER_LOG"
ok "vps: no container: exit 1" "$(FAKE_PS='web nginx:1' vrun rc bash "$V" --check)" 1
ok "vps: two containers: exit 1" "$(FAKE_PS=$'a gitea/gitea:1\nb gitea/gitea:2' vrun rc bash "$V" --check)" 1
has "vps: two containers message" "several gitea containers" "$T/out"
ok "vps: --container skips the search" "$(FAKE_PS=$'a gitea/gitea:1\nb gitea/gitea:2' vrun rc bash "$V" --check --container a)" 0
ok "vps: no recipient: exit 1" "$(vrun rc bash "$V" < /dev/null)" 1
ok "vps: bad recipient: exit 1" "$(vrun rc bash "$V" --recipient notakey)" 1
ok "vps: bad format: exit 1" "$(vrun rc bash "$V" --format zip --check)" 1
ok "vps: unknown option: exit 2" "$(vrun rc bash "$V" --bogus)" 2
if command -v age > /dev/null 2>&1 && command -v age-keygen > /dev/null 2>&1; then
  age-keygen -o "$T/test.key" > /dev/null 2>&1
  pub=$(age-keygen -y "$T/test.key")
  : > "$FAKE_DOCKER_LOG"
  PATH="$T/vps/bin:$PATH" FAKE_PS='g gitea/gitea:1.27.3' bash "$V" --recipient "$pub" > "$T/dump.age" 2> "$T/vps.err"
  ok "vps: dump with age: exit 0" "$?" 0
  age -d -i "$T/test.key" "$T/dump.age" > "$T/dump.tar" 2> /dev/null; ok "the age stream opens with the private key" "$?" 0
  ok "the output is not a plaintext tar" "$([ "$(head -c 4 "$T/dump.age")" != "gite" ] && echo 0 || echo 1)" 0
  python3 "$D" meta "$T/dump.tar" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["gitea_version"], d["db_type"], d["dump_database"])' > "$T/m"
  has "meta member: version, source db, postgres dump syntax" "1.27.3 sqlite3 postgres" "$T/m"
  python3 "$D" sql "$T/dump.tar" > "$T/db2.sql"; has "the dump SQL is readable through the stream" 'CREATE TABLE' "$T/db2.sql"
  python3 "$D" select "$T/dump.tar" | tar -tf - | grep -q 'repos/alice/notes.git/HEAD'; ok "the repos are readable through the stream" "$?" 0
  ok "the temp dir in the container is removed again" "$([ ! -e "$FAKE_TMP" ] && echo 0 || echo 1)" 0
  # only read-only docker subcommands were used, nothing was stopped or changed
  ! grep -Eq '^(stop|restart|rm|kill|run|cp|service|stack|volume|network) ' "$FAKE_DOCKER_LOG"; ok "no state-changing docker subcommand" "$?" 0
  ! grep -q 'unexpected docker' "$FAKE_DOCKER_LOG"; ok "only ps/inspect/exec were called" "$?" 0
  ok "vps: a terminal as stdout is refused (the script checks -t 1)" "$(grep -c 'stdout is a terminal' "$V")" 1
else
  skip "age/age-keygen not installed: round trip of the VPS script not tested"
fi

# ---------------------------------------------------------------- 8. Keycloak SSO after the import
# The import replaces login_source; the safety net ensure_sso_source restarts Gitea once when the source is missing.
has "import: the safety net runs right after the scale-up" "  ensure_sso_source" "$S"
has "import: acceptance checks the Keycloak login source" "SSO: login source keycloak present" "$S"
hasnt "filter.sql keeps no login source (it is reinstalled by configure-oidc)" "INSERT INTO login_source" "$R/scripts/gitea-import/filter.sql"
has "filter.sql drops login_source" "login_source" "$R/scripts/gitea-import/filter.sql"
mkdir -p "$T/sso/bin"
cat > "$T/sso/bin/kubectl" <<'EOS'
#!/bin/sh
echo "$*" >> "$SSO_LOG"
case "$*" in
  *"get secret gitea-oidc"*) [ "${SSO_SECRET:-1}" = 1 ]; exit $? ;;
  *"auth list"*)
    n=$(cat "$SSO_STATE" 2>/dev/null || echo 0)
    if [ "$n" -ge "${SSO_APPEARS_AFTER:-1}" ]; then printf 'ID\t|Name\t|Type\t|Enabled\n1\t|keycloak\t|OAuth2\t|true\n'; else printf 'ID\t|Name\t|Type\t|Enabled\n'; fi ;;
  *"rollout restart"*) n=$(cat "$SSO_STATE" 2>/dev/null || echo 0); echo $((n + 1)) > "$SSO_STATE" ;;
esac
exit 0
EOS
chmod +x "$T/sso/bin/kubectl"
sed -n '/^sso_expected()/,/^# -* the dump: decrypt/p' "$S" > "$T/sso/funcs.sh"
sso_run() { # sso_run SECRET APPEARS_AFTER -> output; restarts counted in $T/sso/log
  rm -f "$T/sso/log" "$T/sso/state"
  ( PATH="$T/sso/bin:$PATH"; export SSO_LOG="$T/sso/log" SSO_STATE="$T/sso/state" SSO_SECRET=$1 SSO_APPEARS_AFTER=$2
    NS=gitea; KCTX=()
    # shellcheck disable=SC2034  # used by the sourced functions
    DEPLOY=gitea
    k() { kubectl "${KCTX[@]}" -n "$NS" "$@"; }
    info() { echo "gitea-import: $*"; }; warn() { echo "gitea-import: WARNING: $*"; }; die() { echo "die: $*"; exit 1; }
    . "$R/scripts/gitea-sso.sh"
    . "$T/sso/funcs.sh"; ensure_sso_source ) > "$T/sso/out" 2>&1
  echo $?
}
ok "sso: source already there: no restart" "$(sso_run 1 0)" 0
ok "sso: no restart call" "$(grep -c 'rollout restart' "$T/sso/log")" 0
has "sso: says so" "is present again" "$T/sso/out"
ok "sso: source missing: one restart installs it" "$(sso_run 1 1)" 0
ok "sso: exactly one restart" "$(grep -c 'rollout restart' "$T/sso/log")" 1
has "sso: reports the install" "login source keycloak installed" "$T/sso/out"
ok "sso: source never appears: no endless loop, a warning" "$(sso_run 1 99)" 0
ok "sso: still only one restart" "$(grep -c 'rollout restart' "$T/sso/log")" 1
has "sso: the warning names the manual command" "rollout restart deploy/gitea" "$T/sso/out"
ok "sso: lab without Keycloak (no secret gitea-oidc): nothing touched" "$(sso_run 0 1)" 0
ok "sso: no exec, no restart without the secret" "$(grep -cE 'rollout|auth list' "$T/sso/log")" 0

echo
echo "gitea-import tests: $n checks, $fail failed"
[ "$fail" = 0 ]
