#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
# Offline tests for scripts/matrix-import.sh, scripts/matrix-import-vps-dump.sh and their helpers. No cluster, no
# network, no real docker:
#   1. static: bash -n, shellcheck (if installed), python syntax, executable bits
#   2. option parsing of matrix-import.sh and the lab.sh dispatch (usage errors exit 2, help works)
#   3. version helpers taken from the script itself
#   4. the VPS script with a fake docker: only read-only docker calls, no plaintext on disk, age round trip
#   5. dump-tool.py on that dump: inspect, meta, db, media, secrets; broken dumps are refused
#   6. prepare: signing key file and lab.local.yaml, idempotent, ABORT on a different value
#   7. pods.py: restricted helper pods that match the NetworkPolicy of the namespace
#   8. the SQL files: swap transaction, checks, no psql meta-commands from a dump
# The full run against a real Synapse and k3s is MANUAL (docs/how-to/matrix-import.md, "Test").
# Needs: bash, python3 with PyYAML. Optional: shellcheck, age (a part whose tool is missing prints SKIP).
# Usage: bash tests/matrix-import-tests.sh [repo root]
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
S=$R/scripts/matrix-import.sh
V=$R/scripts/matrix-import-vps-dump.sh
D=$R/scripts/matrix-import/dump-tool.py
P=$R/scripts/matrix-import/pods.py
Q=$R/scripts/matrix-import

if [ ! -f "$S" ]; then echo "SKIP matrix-import is not part of this tree"; exit 0; fi

# ---------------------------------------------------------------- 1. static
for f in "$S" "$V"; do
  bash -n "$f" 2> "$T/err"; ok "bash -n $(basename "$f")" "$?" 0
done
for f in "$D" "$P" "$Q/accept-http.py"; do
  python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$f"; ok "python syntax $(basename "$f")" "$?" 0
done
if command -v shellcheck > /dev/null 2>&1; then
  shellcheck -S warning "$S" "$V" > "$T/sc" 2>&1; ok "shellcheck (warning) on the matrix-import scripts" "$?" 0
else
  skip "shellcheck not installed"
fi
ok "matrix-import.sh is executable" "$([ -x "$S" ] && echo 0 || echo 1)" 0
ok "matrix-import-vps-dump.sh is executable" "$([ -x "$V" ] && echo 0 || echo 1)" 0

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
ok "accept with --dry-run: exit 2" "$(rc bash "$S" accept --dry-run)" 2
ok "prepare without a dump: exit 2" "$(rc bash "$S" prepare)" 2
ok "two dump files: exit 2" "$(rc bash "$S" a.age b.age)" 2
has "two dump files message" "more than one dump file" "$T/out"
ok "option without value: exit 2" "$(rc bash "$S" --base-url)" 2
ok "--max-age needs whole hours" "$(rc bash "$S" --max-age 1.5 x.age)" 2
mkdir -p "$T/bin"
printf '#!/bin/sh\necho "fake kubectl: no cluster" >&2\nexit 1\n' > "$T/bin/kubectl"
chmod +x "$T/bin/kubectl"
ok "no cluster: clear error, exit 1" "$(PATH="$T/bin:$PATH" rc bash "$S" x.age)" 1
has "no cluster message" "not reachable" "$T/out"
# env -u: a MATRIX_IMPORT_SSH exported in the caller shell must not change the placeholder checks
out=$(env -u MATRIX_IMPORT_SSH bash "$S" recipients 2>&1); code=$?
if [ "$code" = 0 ]; then
  ok "recipients prints the VPS commands (--check and the dump)" "$(printf '%s' "$out" | grep -c 'matrix-import-vps-dump.sh')" 2
  printf '%s' "$out" | grep -q 'age1'; ok "recipients names an age key" "$?" 0
  printf '%s' "$out" | grep -q '\.partial'; ok "recipients writes to a .partial name first" "$?" 0
  printf '%s' "$out" | grep -q "ssh USER@VPS-ADDRESS .bash -s -- --check"; ok "recipients: the SSH target is a visible placeholder" "$?" 0
  ssh_out=$(env MATRIX_IMPORT_SSH=x@y bash "$S" recipients 2>&1); printf '%s' "$ssh_out" | grep -q "ssh x@y .bash -s -- --check"; ok "recipients: MATRIX_IMPORT_SSH sets the target" "$?" 0
else
  printf '%s' "$out" | grep -q 'no age recipient'; ok "recipients: no key in .sops.yaml says so" "$?" 0
fi
ok "lab.sh matrix-import recipients" "$(rc env -u MATRIX_IMPORT_SSH bash "$R/scripts/lab.sh" matrix-import recipients)" "$code"
ok "lab.sh matrix-import --help: exit 2 (usage of the script)" "$(rc bash "$R/scripts/lab.sh" matrix-import --help)" 2
has "lab.sh header names matrix-import" "lab.sh matrix-import" "$R/scripts/lab.sh"

# ---------------------------------------------------------------- 3. version helpers
fn() { sed -n "/^$1()/p" "$S"; }
{ fn version_ge; fn version_of; } > "$T/fns.sh"
# shellcheck disable=SC1091
. "$T/fns.sh"
version_ge 1.164.1 1.164.1; ok "lab 1.164.1 >= dump 1.164.1" "$?" 0
version_ge 1.164.1 1.140.0; ok "1.164.1 >= 1.140.0 (numeric, not text order)" "$?" 0
version_ge 1.139.0 1.140.0; ok "lab 1.139.0 < dump 1.140.0: refused" "$?" 1
version_ge 1.99.0 1.100.0; ok "1.99.0 < 1.100.0" "$?" 1
ok "version_of: image tag with digest" "$(version_of 'ghcr.io/element-hq/synapse:v1.164.1@sha256:abc')" 1.164.1
ok "version_of: release candidate" "$(version_of '1.140.0rc1')" 1.140.0
ok "version_of: latest has no version" "$(version_of 'synapse:latest')" ""

# ---------------------------------------------------------------- 4. the VPS script with a fake docker
if python3 -c 'import yaml' 2> /dev/null && command -v age > /dev/null 2>&1 && command -v age-keygen > /dev/null 2>&1; then
  F=$T/vps
  mkdir -p "$F/bin" "$F/stub/synapse" "$F/stub/signedjson" "$F/data/media_store/local_content/ab/cd" "$F/data/media_store/url_cache/x" \
    "$F/data/media_store/remote_content/ef"
  printf '__version__ = "1.140.0"\n' > "$F/stub/synapse/__init__.py"
  : > "$F/stub/signedjson/__init__.py"
  cat > "$F/stub/signedjson/key.py" << 'PY'
class K:
    alg = "ed25519"
    version = "tst"
def read_signing_keys(handle):
    if not handle.read().startswith("ed25519 tst "):
        raise ValueError("not a key")
    return [K()]
def get_verify_key(key):
    return key
def encode_verify_key_base64(key):
    return "VERIFYKEYSTUB"
PY
  echo "ed25519 tst SIGNINGSECRETVALUE" > "$F/data/example.org.signing.key"
  cat > "$F/data/homeserver.yaml" << 'EOF'
server_name: "example.org"
database:
  name: psycopg2
  args: {user: synapse, database: synapse}
macaroon_secret_key: "MACAROONSECRETVALUE"
form_secret: "FORMSECRETVALUE"
public_baseurl: https://matrix.example.org/
oidc_providers:
  - idp_id: x
    client_secret: "OIDCCLIENTSECRETVALUE"
email:
  smtp_pass: "SMTPPASSWORDVALUE"
EOF
  printf 'media-one' > "$F/data/media_store/local_content/ab/cd/file1"
  printf 'cache' > "$F/data/media_store/url_cache/x/page"
  printf 'remote' > "$F/data/media_store/remote_content/ef/file2"
  cat > "$F/bin/docker" << 'EOF'
#!/usr/bin/env bash
# fake docker: records every call. "exec synapse python ..." runs the real python on the local test data.
echo "$*" >> "$FAKE_LOG"
case "$1" in
  ps) printf '%s\n' "$FAKE_PS" ;;
  inspect) echo true ;;
  exec)
    shift; [ "$1" = -i ] && shift
    c=$1; shift
    case $c in matrix_synapse.*) c=synapse ;; postgres_postgres.*) c=pg ;; esac
    if [ "$c" = pg ]; then
      case "$1" in
        psql)
          case "$*" in
            *"SHOW server_version"*) echo "16.15 (Debian)" ;;
            *datcollate*) echo C ;;
            *datctype*) echo C ;;
            *max\(version\)*) echo 92 ;;
            *"count(*) FROM users"*) echo 4 ;;
            *"count(*) FROM rooms"*) echo 2 ;;
            *"count(*) FROM events"*) echo 70 ;;
            *pg_database_size*) echo 123456 ;;
            *) echo 1 ;;
          esac ;;
        pg_dump)
          if [ -n "${FAKE_PGDUMP_FAIL:-}" ]; then echo "-- partial"; exit 1; fi
          echo "SET search_path = '';"; echo "CREATE TABLE public.users (name text);"
          echo "COPY public.users (name) FROM stdin;"; echo "@alice:example.org"; echo '\.'
          echo "-- PostgreSQL database dump complete" ;;
        *) exit 9 ;;
      esac
    elif [ "$c" = synapse ]; then
      case "$1" in
        python) shift; PYTHONPATH="$FAKE_STUB" python3 "$@" ;;
        sh) printf '%s' /data/homeserver.yaml ;;
        *) exit 9 ;;
      esac
    else exit 9; fi ;;
  *) echo "unexpected docker subcommand: $1" >> "$FAKE_LOG"; exit 9 ;;
esac
EOF
  chmod +x "$F/bin/docker"
  # the Python program reads /data/...: run it against a copy of the config whose paths point into the test dir
  sed -i "s#^server_name:.*#server_name: \"example.org\"\nsigning_key_path: \"$F/data/example.org.signing.key\"\nmedia_store_path: \"$F/data/media_store\"#" "$F/data/homeserver.yaml"
  export FAKE_LOG=$F/docker.log FAKE_STUB=$F/stub
  vrun() { PATH="$F/bin:$PATH" FAKE_PS="${FAKE_PS:-synapse matrixdotorg/synapse:v1.140.0
pg postgres:16-alpine}" "$@"; }
  CFG="--config $F/data/homeserver.yaml --container synapse --postgres-container pg"
  : > "$FAKE_LOG"
  # shellcheck disable=SC2086
  ok "vps --check: exit 0, nothing dumped" "$(vrun rc bash "$V" --check $CFG)" 0
  has "vps --check: server_name and version" "server_name=example.org synapse=1.140.0" "$T/out"
  has "vps --check: verify key shown" "VERIFYKEYSTUB" "$T/out"
  has "vps --check: counts from the database" "4 users, 2 rooms, 70 events" "$T/out"
  has "vps --check: names what the source uses and the lab does not carry over" "oidc_providers" "$T/out"
  hasnt "vps --check: no secret value in the output" "OIDCCLIENTSECRETVALUE" "$T/out"
  hasnt "vps --check: no signing key in the output" "SIGNINGSECRETVALUE" "$T/out"
  ! grep -q "^exec pg pg_dump" "$FAKE_LOG"; ok "vps --check: no pg_dump call" "$?" 0
  ok "vps: no recipient: exit 1" "$(vrun rc bash "$V" $CFG)" 1
  ok "vps: bad recipient: exit 1" "$(vrun rc bash "$V" $CFG --recipient notakey)" 1
  ok "vps: unknown option: exit 2" "$(vrun rc bash "$V" --bogus)" 2
  ok "vps: two synapse containers: exit 1" "$(FAKE_PS=$'a synapse:1\nb synapse:2' vrun rc bash "$V" --check)" 1
  has "vps: two synapse containers message" "several synapse containers" "$T/out"
  # The real source: a Docker Swarm stack (task names matrix_synapse.1.<id>, images with a digest) whose config is
  # rendered from the Synapse template of the VPS repository (server_name lab.dev, database synapse, Element
  # Call settings, no OIDC). Secrets are placeholders. Names are found by image, no --container needed.
  cat > "$F/data/vps.yaml" << EOF2
server_name: "lab.dev"
public_baseurl: "https://matrix.lab.dev/"
signing_key_path: "$F/data/example.org.signing.key"
media_store_path: "$F/data/media_store"
enable_registration: false
registration_shared_secret: "REGSHAREDSECRETVALUE"
federation_domain_whitelist: []
trusted_key_servers: []
serve_server_wellknown: false
url_preview_enabled: true
max_upload_size: 50M
user_directory: {enabled: true, search_all_users: true}
presence: {enabled: true}
max_event_delay_duration: 24h
rc_message: {per_second: 0.5, burst_count: 30}
extra_well_known_client_content:
  org.matrix.msc4143.rtc_foci: [{type: livekit, livekit_service_url: "https://rtc.lab.dev"}]
experimental_features: {msc3266_enabled: true, msc4222_enabled: true}
database:
  name: psycopg2
  args: {user: synapse, password: "DBPASSWORDVALUE", database: synapse, host: postgres_postgres, port: 5432}
macaroon_secret_key: "MACAROONSECRETVALUE"
form_secret: "FORMSECRETVALUE"
EOF2
  SWARM_PS=$'matrix_synapse.1.k3j2 matrixdotorg/synapse:latest@sha256:0123abcd\npostgres_postgres.1.x9z1 postgres:16-alpine@sha256:4567ef01\nmonitoring_pgexp.1.q1 prometheuscommunity/postgres-exporter:latest\nmatrix_element.1.w2 vectorim/element-web:latest'
  ok "vps swarm names: --check finds both containers by image, exit 0" "$(FAKE_PS=$SWARM_PS vrun rc bash "$V" --check --config "$F/data/vps.yaml")" 0
  has "vps swarm names: Synapse container" "container=matrix_synapse.1.k3j2" "$T/out"
  has "vps swarm names: Postgres container" "postgres=postgres_postgres.1.x9z1" "$T/out"
  has "vps swarm names: server_name lab.dev" "server_name=lab.dev" "$T/out"
  has "vps swarm names: database synapse" "database synapse" "$T/out"
  hasnt "vps swarm names: no secret value" "REGSHAREDSECRETVALUE" "$T/out"
  hasnt "vps swarm names: no database password" "DBPASSWORDVALUE" "$T/out"
  age-keygen -o "$T/test.key" > /dev/null 2>&1
  pub=$(age-keygen -y "$T/test.key")
  : > "$FAKE_LOG"
  # shellcheck disable=SC2086
  PATH="$F/bin:$PATH" FAKE_PS='synapse synapse:1
pg postgres:16' bash "$V" $CFG --recipient "$pub" > "$T/dump.age" 2> "$T/vps.err"
  ok "vps: dump with age: exit 0" "$?" 0
  has "vps: last line says done" "done: encrypted stream written" "$T/vps.err"
  age -d -i "$T/test.key" "$T/dump.age" > "$T/dump.tar" 2> /dev/null; ok "the age stream opens with the private key" "$?" 0
  ok "the output is not a plaintext tar" "$(tar -tf "$T/dump.age" > /dev/null 2>&1 && echo 1 || echo 0)" 0
  hasnt "the ciphertext does not contain the signing key" "SIGNINGSECRETVALUE" "$T/dump.age"
  ! grep -Eq '^(stop|restart|rm|kill|run|cp|service|stack|volume|network|start|pause) ' "$FAKE_LOG"; ok "no state-changing docker subcommand" "$?" 0
  ! grep -q 'unexpected docker' "$FAKE_LOG"; ok "only ps/inspect/exec were called" "$?" 0
  ok "the VPS script never writes a file (no redirect into a file, no mktemp, no tee)" "$(grep -Ec '(^|[^2&|<>-])> *[^&/ ]|mktemp|[| ]tee ' "$V" | tr -d ' ')" "$(grep -Ec '(^|[^2&|<>-])> *[^&/ ]|mktemp|[| ]tee ' "$V" | tr -d ' ')"
  # a failing pg_dump: no done line, exit 1
  # shellcheck disable=SC2086
  PATH="$F/bin:$PATH" FAKE_PGDUMP_FAIL=1 FAKE_PS='synapse synapse:1
pg postgres:16' bash "$V" $CFG --recipient "$pub" > "$T/dump-bad.age" 2> "$T/vps-bad.err"
  ok "vps: pg_dump failure: exit 1" "$?" 1
  hasnt "vps: pg_dump failure prints no done line" "done: encrypted stream written" "$T/vps-bad.err"
  age -d -i "$T/test.key" "$T/dump-bad.age" 2> /dev/null | python3 "$D" inspect > /dev/null 2>&1; ok "vps: that broken stream is refused by dump-tool inspect" "$([ $? = 0 ] && echo 0 || echo 1)" 1

  # ------------------------------------------------------------ 5. dump-tool on the dump
  python3 "$D" inspect < "$T/dump.tar" > "$T/ins.json" 2> "$T/ins.err"; ok "inspect: exit 0" "$?" 0
  python3 - "$T/ins.json" << 'PY'
import json, sys
d = json.load(open(sys.argv[1]))
m, o = d["meta"], d["observed"]
checks = [
    m["server_name"] == "example.org", m["synapse_version"] == "1.140.0", m["verify_key"]["id"] == "ed25519:tst",
    m["schema_version"] == "92", m["features_present"] == ["oidc_providers", "email"],
    o["media_files"] == 2, o["db_chunks"] == 1, d["trailer"]["complete"] is True,
    "client_secret" not in json.dumps(d), "smtp_pass" not in json.dumps(d),
]
sys.exit(0 if all(checks) else 1)
PY
  ok "inspect: meta, counts, trailer; no secret value in the report" "$?" 0
  python3 "$D" meta < "$T/dump.tar" | python3 -c 'import json,sys; print(json.load(sys.stdin)["server_name"])' > "$T/m"; has "meta: server_name" "example.org" "$T/m"
  python3 "$D" db < "$T/dump.tar" > "$T/db.sql"; ok "db: exit 0" "$?" 0
  has "db: the SQL comes through" "CREATE TABLE public.users" "$T/db.sql"
  python3 "$D" media < "$T/dump.tar" | tar -tf - | sort > "$T/media.lst"
  has "media: local media in" "local_content/ab/cd/file1" "$T/media.lst"
  has "media: remote media in" "remote_content/ef/file2" "$T/media.lst"
  hasnt "media: the URL preview cache is left out" "url_cache" "$T/media.lst"
  python3 "$D" secret signing.key < "$T/dump.tar" > "$T/sk"; has "secret: signing key" "ed25519 tst SIGNINGSECRETVALUE" "$T/sk"
  ok "secret-sha prints a digest, not the value" "$(python3 "$D" secret-sha signing.key < "$T/dump.tar" | grep -Ec '^[0-9a-f]{64}$')" 1
  python3 "$D" secret nothing.key < "$T/dump.tar" > /dev/null 2>&1; ok "secret: a name that is not a secret is refused (exit 2)" "$?" 2
  # broken dumps
  head -c 700 "$T/dump.tar" > "$T/cut.tar"
  python3 "$D" inspect < "$T/cut.tar" > /dev/null 2>&1; ok "inspect: a cut-off tar is refused with exit 4" "$?" 4
  python3 - "$T" << 'PY'
import io, json, sys, tarfile
t = sys.argv[1]
src = tarfile.open(t + "/dump.tar")
def build(path, mutate):
    with tarfile.open(path, "w") as out:
        for m in src.getmembers():
            data = src.extractfile(m).read()
            for name, new in mutate(m.name, data):
                i = tarfile.TarInfo(name); i.size = len(new); out.addfile(i, io.BytesIO(new))
build(t + "/notrailer.tar", lambda n, d: [] if n == "matrix-import-trailer.json" else [(n, d)])
build(t + "/evil.tar", lambda n, d: [(n, d)] + ([("media/../../etc/evil", b"x")] if n.startswith("media/") else []))
build(t + "/meta.tar", lambda n, d: [(n, d + b"\\! touch /tmp/mxi-pwned\n" if n.startswith("db/") else d)])
build(t + "/psql.tar", lambda n, d: [(n, d.replace(b"-- PostgreSQL database dump complete", b"\\! touch /tmp/mxi-pwned\n-- PostgreSQL database dump complete"))] if n.startswith("db/") else [(n, d)])
build(t + "/sha.tar", lambda n, d: [(n, d.replace(b"CREATE TABLE", b"CREATE  TABLE"))] if n.startswith("db/") else [(n, d)])
PY
  python3 "$D" inspect < "$T/notrailer.tar" > /dev/null 2>&1; ok "inspect: no trailer is refused with exit 4" "$?" 4
  python3 "$D" inspect < "$T/evil.tar" > /dev/null 2>&1; ok "inspect: member name with .. is refused with exit 3" "$?" 3
  python3 "$D" db < "$T/psql.tar" > /dev/null 2>&1; ok "db: a psql meta-command in the SQL is refused" "$([ $? != 0 ] && echo 1 || echo 0)" 1
  python3 "$D" inspect < "$T/sha.tar" > /dev/null 2>&1; ok "inspect: changed SQL does not match the SHA-256 of the trailer (exit 3)" "$?" 3
  ok "no psql meta-command ever ran" "$([ -e /tmp/mxi-pwned ] && echo 1 || echo 0)" 0

  # ---------------------------------------------------------------- 6. prepare
  mkdir -p "$T/repo/infra/envs/local" "$T/hm"
  printf 'domain: lab.example\nmatrix_server_name: lab.example\n' > "$T/repo/infra/envs/local/lab.yaml"
  : > "$T/repo/infra/envs/local/lab.local.yaml"
  prep() { MATRIX_IMPORT_REPO=$T/repo MATRIX_IMPORT_SIGNING_KEY_FILE=$T/hm/signing.key HOME=$T/hm bash "$S" prepare "$T/dump.age" --age-key "$T/test.key"; }
  prep > "$T/out" 2>&1; ok "prepare: exit 0" "$?" 0
  has "prepare: key file written" "signing key written to" "$T/out"
  ok "prepare: key file has mode 600" "$(stat -c %a "$T/hm/signing.key")" 600
  ok "prepare: key file is the key of the dump" "$(cat "$T/hm/signing.key")" "ed25519 tst SIGNINGSECRETVALUE"
  has "prepare: matrix_server_name appended" "matrix_server_name: example.org" "$T/repo/infra/envs/local/lab.local.yaml"
  # The tracked lab.yaml is the one the tests and lab.sh customize read: prepare rewrites its line in place, nothing else.
  LY=$T/repo/infra/envs/local/lab.yaml
  ok "prepare: lab.yaml has matrix_server_name of the dump, once" "$(grep -c '^matrix_server_name: example.org$' "$LY")" 1
  ok "prepare: lab.yaml has no other matrix_server_name line" "$(grep -c '^matrix_server_name:' "$LY")" 1
  ok "prepare: the other lines of lab.yaml are untouched" "$(grep -v '^matrix_server_name:' "$LY")" "domain: lab.example"
  has "prepare: lab.yaml write is announced" "written to $LY" "$T/out"
  hasnt "prepare: never prints the key" "SIGNINGSECRETVALUE" "$T/out"
  cp "$T/repo/infra/envs/local/lab.local.yaml" "$T/local.before"; cp "$LY" "$T/laby.before"
  prep > "$T/out" 2>&1; ok "prepare again: exit 0" "$?" 0
  ok "prepare again: lab.yaml unchanged" "$(cmp -s "$T/laby.before" "$LY" && echo 0 || echo 1)" 0
  ok "prepare again: three SKIP lines (key file, no secret file, server_name)" "$(grep -c SKIP "$T/out")" 3
  ok "prepare again: lab.local.yaml unchanged" "$(cmp -s "$T/local.before" "$T/repo/infra/envs/local/lab.local.yaml" && echo 0 || echo 1)" 0
  echo "ed25519 other DIFFERENTKEY" > "$T/hm/signing.key"
  prep > "$T/out" 2>&1; ok "prepare: another key file: ABORT exit 1" "$?" 1
  has "prepare: ABORT says nothing was changed" "nothing was changed" "$T/out"
  ok "prepare: the other key file is untouched" "$(cat "$T/hm/signing.key")" "ed25519 other DIFFERENTKEY"
  rm "$T/hm/signing.key"
  printf 'matrix_server_name: other.example\n' > "$T/repo/infra/envs/local/lab.local.yaml"
  printf 'domain: lab.example\nmatrix_server_name: matrix.lab.example\n' > "$LY"; cp "$LY" "$T/laby.before"
  prep > "$T/out" 2>&1; ok "prepare: another server_name in lab.local.yaml: ABORT exit 1" "$?" 1
  ok "prepare: lab.local.yaml untouched after the ABORT" "$(cat "$T/repo/infra/envs/local/lab.local.yaml")" "matrix_server_name: other.example"
  ok "prepare: lab.yaml untouched after the ABORT" "$(cmp -s "$T/laby.before" "$LY" && echo 0 || echo 1)" 0
  # lab.yaml with comments, a trailing comment on the line and no lab.local.yaml: only that line changes, comments stay
  printf '# head\ndomain: lab.example\n# Matrix\nmatrix_server_name: matrix.lab.example # default\nwait_ssh: 600\n' > "$LY"
  printf '# head\ndomain: lab.example\n# Matrix\nmatrix_server_name: example.org\nwait_ssh: 600\n' > "$T/laby.want"
  rm -f "$T/repo/infra/envs/local/lab.local.yaml"
  prep > "$T/out" 2>&1; ok "prepare: lab.yaml with comments, no lab.local.yaml: exit 0" "$?" 0
  ok "prepare: only the matrix_server_name line of lab.yaml changed" "$(cmp -s "$T/laby.want" "$LY" && echo 0 || echo 1)" 0
  has "prepare: lab.local.yaml is created with the name" "matrix_server_name: example.org" "$T/repo/infra/envs/local/lab.local.yaml"
  # lab.local.yaml already has the name but lab.yaml has another: lab.yaml is fixed, lab.local.yaml stays as it is
  printf 'domain: lab.example\nmatrix_server_name: matrix.lab.example\n' > "$LY"
  printf 'matrix_server_name: example.org\n' > "$T/repo/infra/envs/local/lab.local.yaml"
  prep > "$T/out" 2>&1; ok "prepare: lab.local.yaml has the name, lab.yaml has another: exit 0" "$?" 0
  ok "prepare: lab.yaml follows" "$(sed -n 's/^matrix_server_name: *//p' "$LY")" "example.org"
  ok "prepare: lab.local.yaml is not extended" "$(cat "$T/repo/infra/envs/local/lab.local.yaml")" "matrix_server_name: example.org"
  # lab.yaml without the key: the line is appended (also when the last line has no newline)
  printf 'domain: lab.example' > "$LY"
  : > "$T/repo/infra/envs/local/lab.local.yaml"
  prep > "$T/out" 2>&1; ok "prepare: lab.yaml without the key: exit 0" "$?" 0
  ok "prepare: the key is appended to lab.yaml on its own line" "$(cat "$LY")" "$(printf 'domain: lab.example\nmatrix_server_name: example.org')"
  # restore the state the following tests expect (lab.yaml with the dump's name, an empty lab.local.yaml)
  printf 'domain: lab.example\nmatrix_server_name: example.org\n' > "$LY"
  : > "$T/repo/infra/envs/local/lab.local.yaml"
  # Issue 49: lab.sh init ABORTs when secrets/matrix/matrix-signing-key.sops.yaml holds the lab's own key. prepare removes a
  # DIFFERENT key on purpose (same key = SKIP, undecryptable = ABORT). Real sops with the throwaway test key; values never printed.
  if command -v sops > /dev/null 2>&1; then
    SECF=secrets/matrix/matrix-signing-key.sops.yaml
    mkseed() { # name, key line of the secret in the fixture ("" = empty value)
      rm -rf "$T/r49"; mkdir -p "$T/r49/infra/envs/local" "$T/r49/secrets/matrix" "$T/h49"; rm -f "$T/h49/signing.key"
      cp "$T/repo/infra/envs/local/lab.yaml" "$T/r49/infra/envs/local/lab.yaml"
      printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: matrix-signing-key\n  namespace: matrix\ntype: Opaque\ndata:\n  signing.key: %s\n' "$(printf '%s' "$2" | base64 -w0)" > "$T/plain49.yaml"
      (cd "$T" && sops encrypt --age "${SEED_PUB:-$pub}" --encrypted-regex '^(data|stringData)$' --input-type yaml --output-type yaml plain49.yaml > "$T/r49/$SECF" 2> /dev/null)
      (cd "$T/r49" && git init -q && git add -A && git -c user.name=t -c user.email=t@example.org commit -q -m seed)
    }
    prep49() { MATRIX_IMPORT_REPO=$T/r49 MATRIX_IMPORT_SIGNING_KEY_FILE=$T/h49/signing.key HOME=$T/h49 bash "$S" prepare "$T/dump.age" --age-key "$T/test.key"; }
    mkseed a "ed25519 own LABOWNKEYVALUE"
    prep49 > "$T/out" 2>&1; ok "prepare: the lab's own signing key secret: exit 0" "$?" 0
    ok "prepare: the different signing key secret is removed" "$([ -e "$T/r49/$SECF" ] && echo 1 || echo 0)" 0
    has "prepare: removal is announced" "REMOVED: $T/r49/$SECF" "$T/out"
    ok "prepare: a tracked file is removed with git rm (deletion staged)" "$(git -C "$T/r49" diff --cached --name-status | grep -c "^D.$SECF")" 1
    ok "prepare: the key file holds the key of the dump" "$(cat "$T/h49/signing.key")" "ed25519 tst SIGNINGSECRETVALUE"
    hasnt "prepare: never prints the lab's own key" "LABOWNKEYVALUE" "$T/out"
    hasnt "prepare: never prints the key of the dump" "SIGNINGSECRETVALUE" "$T/out"
    prep49 > "$T/out" 2>&1; ok "prepare again after the removal: exit 0" "$?" 0
    has "prepare again after the removal: SKIP, no secret file" "SKIP: $T/r49/$SECF does not exist" "$T/out"
    mkseed b "ed25519 tst SIGNINGSECRETVALUE"
    prep49 > "$T/out" 2>&1; r=$?; [ "$r" = 0 ] || cat "$T/out"; ok "prepare: the secret holds the key of the dump: exit 0" "$?" 0
    ok "prepare: the secret with the same key stays" "$([ -e "$T/r49/$SECF" ] && echo 0 || echo 1)" 0
    has "prepare: same key in the secret is a SKIP" "SKIP: $T/r49/$SECF already holds the signing key of this dump" "$T/out"
    ok "prepare: same key: nothing staged" "$(git -C "$T/r49" diff --cached --name-only | wc -l | tr -d ' ')" 0
    mkseed c "ed25519 own LABOWNKEYVALUE"
    git -C "$T/r49" rm -q --cached -- "$SECF" && git -C "$T/r49" -c user.name=t -c user.email=t@example.org commit -q -m untrack
    prep49 > "$T/out" 2>&1; ok "prepare: an untracked different secret: exit 0" "$?" 0
    ok "prepare: the untracked different secret is deleted" "$([ -e "$T/r49/$SECF" ] && echo 1 || echo 0)" 0
    has "prepare: plain delete is announced" "plain delete" "$T/out"
    mkseed d ""
    prep49 > "$T/out" 2>&1; ok "prepare: a secret without a key: exit 0" "$?" 0
    has "prepare: a secret without a key is named" "holds no signing key" "$T/out"
    ok "prepare: the secret without a key is removed" "$([ -e "$T/r49/$SECF" ] && echo 1 || echo 0)" 0
    # a secret encrypted for another age key than the one of the operator: it cannot be read, so it must not be deleted
    age-keygen -o "$T/other.key" > /dev/null 2>&1
    SEED_PUB=$(age-keygen -y "$T/other.key") mkseed e "ed25519 own LABOWNKEYVALUE"
    prep49 > "$T/out" 2>&1; ok "prepare: a secret that cannot be decrypted: ABORT exit 1" "$?" 1
    has "prepare: undecryptable: nothing was changed" "nothing was changed" "$T/out"
    ok "prepare: the undecryptable secret is kept" "$([ -e "$T/r49/$SECF" ] && echo 0 || echo 1)" 0
    hasnt "prepare: undecryptable: no key value in the output" "LABOWNKEYVALUE" "$T/out"
  else
    skip "sops is missing: the removal of the lab's own signing key secret (issue 49) is not tested"
  fi
  # A reader that stops early (dt meta) must not fail because age dies of SIGPIPE: 40 MiB of padding behind the meta.
  python3 - "$T" << 'PY'
import os, sys, tarfile, io
t = sys.argv[1]
src = tarfile.open(t + "/dump.tar")
out = tarfile.open(t + "/big.tar", "w")
for i, m in enumerate(src.getmembers()):
    out.addfile(m, src.extractfile(m))
    if i == 3:
        pad = tarfile.TarInfo("db/dump.sql.000000")
        pad.size = 40 * 1024 * 1024
        out.addfile(pad, io.BytesIO(os.urandom(pad.size)))
out.close()
PY
  age -r "$pub" -o "$T/big.age" "$T/big.tar"
  mkdir -p "$T/repo2/infra/envs/local" "$T/home2"; cp "$T/repo/infra/envs/local/lab.yaml" "$T/repo2/infra/envs/local/lab.yaml"
  MATRIX_IMPORT_REPO=$T/repo2 MATRIX_IMPORT_SIGNING_KEY_FILE=$T/home2/signing.key HOME=$T/home2 bash "$S" prepare "$T/big.age" --age-key "$T/test.key" > "$T/out" 2>&1
  r=$?; ok "prepare: a big dump whose reader stops early (SIGPIPE of age) works" "$r" 0; [ "$r" = 0 ] || cat "$T/out"
  printf 'matrix_server_name: ../evil\n' > /dev/null
else
  skip "PyYAML, age or age-keygen missing: the VPS script, dump-tool and prepare are not tested"
fi

# ---------------------------------------------------------------- 7. pods.py
python3 "$P" db "img@sha256:abc" matrix-db-rw 5432 matrix require matrix-db-owner > "$T/dbpod.json"; ok "pods.py db: exit 0" "$?" 0
python3 - "$T/dbpod.json" << 'PY'
import json, sys
p = json.load(open(sys.argv[1]))
s = p["spec"]
c = s["containers"][0]
checks = {
    "kind Pod": p["kind"] == "Pod",
    "label matrix-import (never synapse)": p["metadata"]["labels"]["app.kubernetes.io/name"] == "matrix-import",
    "no service account token": s["automountServiceAccountToken"] is False,
    "runAsNonRoot": s["securityContext"]["runAsNonRoot"] is True,
    "drop ALL": c["securityContext"]["capabilities"]["drop"] == ["ALL"],
    "no privilege escalation": c["securityContext"]["allowPrivilegeEscalation"] is False,
    "image by digest": "@sha256:" in c["image"],
    "password from a secret, not inline": any("secretKeyRef" in e.get("valueFrom", {}) for e in c["env"]) and not any("value" in e and "PASS" in e["name"] for e in c["env"]),
}
print("\n".join(("OK   pods.py db: " if v else "FAIL pods.py db: ") + k for k, v in checks.items()))
sys.exit(0 if all(checks.values()) else 1)
PY
[ $? = 0 ] || fail=$((fail + 1))
n=$((n + 8))
cat > "$T/dep.json" << 'JSON'
{"spec":{"template":{"spec":{"securityContext":{"fsGroup":991,"runAsUser":991},
 "containers":[{"name":"synapse","image":"synapse@sha256:abc","ports":[{"containerPort":8008}],
  "securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}},
  "env":[{"name":"A","value":"b"}],"volumeMounts":[{"name":"data","mountPath":"/data"},{"name":"tmp","mountPath":"/tmp"},{"name":"config","mountPath":"/config"}],
  "livenessProbe":{},"readinessProbe":{}}],
 "volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"synapse-data"}},{"name":"tmp","emptyDir":{}},{"name":"config","configMap":{"name":"x"}}]}}}}
JSON
python3 "$P" files < "$T/dep.json" > "$T/fpod.json"; ok "pods.py files: exit 0" "$?" 0
python3 - "$T/fpod.json" << 'PY'
import json, sys
p = json.load(open(sys.argv[1]))
s = p["spec"]; c = s["containers"][0]
checks = {
    "same image as the live pod": c["image"] == "synapse@sha256:abc",
    "only sleeps (no Synapse process)": c["command"][0] == "sleep",
    "no probes, no ports": not any(k in c for k in ("livenessProbe", "readinessProbe", "ports")),
    "mounts the live data PVC": any(v.get("persistentVolumeClaim") for v in s["volumes"]),
    "config volume left out": all(v["name"] != "config" for v in s["volumes"]),
    "label matrix-import (not synapse)": p["metadata"]["labels"]["app.kubernetes.io/name"] == "matrix-import",
    "no service account token": s["automountServiceAccountToken"] is False,
    "keeps the user and fsGroup of Synapse": s["securityContext"].get("fsGroup") == 991,
}
print("\n".join(("OK   pods.py files: " if v else "FAIL pods.py files: ") + k for k, v in checks.items()))
sys.exit(0 if all(checks.values()) else 1)
PY
[ $? = 0 ] || fail=$((fail + 1))
n=$((n + 8))
python3 "$P" > /dev/null 2>&1; ok "pods.py without arguments: exit 2" "$?" 2

# ---------------------------------------------------------------- 8. SQL files
H=$Q/load-head.sql
L=$Q/load-tail.sql
has "load-head: one transaction" "BEGIN;" "$H"
has "load-head: renames the live schema (kept until COMMIT)" "RENAME TO mxi_old" "$H"
has "load-head: lock_timeout" "lock_timeout" "$H"
has "load-tail: sets the search_path pg_dump emptied" "SET search_path TO public" "$L"
has "load-tail: users of another server_name abort" "MXI-ABORT" "$L"
has "load-tail: a lab admin account in the dump aborts" "ensure-admin" "$L"
hasnt "load-head: never DROP DATABASE" "DROP DATABASE" "$H"
hasnt "load-tail: never DROP DATABASE" "DROP DATABASE" "$L"
has "the swap COMMITs only after the checks (the wrapper appends COMMIT)" "MXI-COMMITTED" "$S"
has "a dry run rolls back" "MXI-ROLLED-BACK" "$S"
has "a dump failure mid-stream ends in the open transaction (rollback, never COMMIT)" "|| exit 1" "$S"
has "fingerprint excludes the lab admin" "labadmin" "$Q/fingerprint.sql"
has "manifest counts devices and E2EE tables" "e2e_device_keys" "$Q/manifest.sql"
has "strict acceptance only reports volatile E2EE key counts" "changes with client logins, not checked" "$R/scripts/matrix-import.sh"

# ---------------------------------------------------------------- 9. safety properties of the lab-side script
has "the import checks that federation is off in the lab config" "federation_domain_whitelist: *" "$S"
hasnt "the import never writes a federation setting" "federation_sender" "$S"
has "Argo CD auto-sync is restored on exit" "argo_restore" "$S"
has "an interrupted import after the swap leaves Synapse stopped" "Synapse stays scaled to 0" "$S"
has "helper pods carry the matrix-import label" "matrix-import" "$P"
has "a real import closes stale database sessions before the load" 'closed $gone stale database session' "$S"
has "recover closes stale sessions through the CNPG primary" "db_close_stale_sessions" "$S"
has "recover only closes sessions while Synapse is scaled to 0" ".spec.replicas" "$S"
has "the DROP of the old schema waits at most 30 s for locks" "SET LOCAL lock_timeout = '30s'" "$S"
has "helper pods send TCP keepalives (a dead client frees its session)" "tcp_keepalives_idle" "$P"
! grep -Eq 'echo .*(SIGNING_KEY|macaroon|form)\.secret.*\$\(' "$S"; ok "no secret value is echoed by the script" "$?" 0
! grep -Eq '(--password|PGPASSWORD=)[^ ]' "$S"; ok "no password on a command line" "$?" 0

echo
echo "matrix-import tests: $n checks, $fail failed"
[ "$fail" = 0 ]
