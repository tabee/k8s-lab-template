#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
# matrix-import.sh: bring an existing Synapse homeserver (the production one on the old VPS) into the lab Matrix, with
# its server_name, signing key, accounts, rooms, history, media and the E2EE device data, so that existing clients keep
# working after a later cutover. Optional and generic: server_name and source host are inputs; the default of the lab
# stays a fresh instance. Federation stays OFF, always. Call it as `bash scripts/lab.sh matrix-import ...` (lab.sh loads
# lab.yaml and the KUBECONFIG first); it also runs on its own with KUBECONFIG set.
#
# One command per step (the old VPS is only ever READ, by a script you stream over SSH):
#   1. bash scripts/lab.sh matrix-import recipients       age recipients of .sops.yaml and the two VPS commands
#   2. ssh $MATRIX_IMPORT_SSH 'bash -s -- --check' < scripts/matrix-import-vps-dump.sh                (read-only checks)
#   3. ssh $MATRIX_IMPORT_SSH 'bash -s -- --recipient ...' < scripts/matrix-import-vps-dump.sh > dump.age.partial   (encrypted dump)
#   4. bash scripts/lab.sh matrix-import prepare DUMP     server_name into lab.yaml (and lab.local.yaml), signing
#                                                         key into the key file; removes the lab's own, different signing key secret
#                                                         secrets/matrix/matrix-signing-key.sops.yaml (same key = SKIP);
#                                                         then init, customize, commit, push
#   5. bash scripts/lab.sh matrix-import DUMP --dry-run   load the dump in a transaction that is rolled back, check, report
#   6. bash scripts/lab.sh matrix-import DUMP             the import (SKIP / ABORT / import, see below)
#   7. bash scripts/lab.sh matrix-import accept           the acceptance checks again, any time
# Also: `backup` (fresh CNPG base backup + K8up backup of Matrix only), `recover` (undo what an interrupted run left:
# Synapse scaled up again, Argo CD auto-sync restored, helper pods deleted).
#
# DUMP is the age file of scripts/matrix-import-vps-dump.sh. It is never written to disk in plain text: every pass
# decrypts it again into a pipe. Its sha256 is the identity of the import. The tar inside must carry a complete trailer.
# What is imported: the whole Synapse database (users with password hashes, devices, access tokens, E2EE device and
# one-time keys, room key backups, rooms and their history, media records, account data), the media store, the signing
# key, the macaroon and form secrets. NOT imported: the Synapse config of the source (the lab chart decides: federation
# off, no URL previews, ...), url preview cache, anything outside the media store.
#
# Decision per run (state in the ConfigMap matrix-import-state, namespace matrix):
#   same dump (same sha256) already imported  -> SKIP (acceptance only); --reimport forces a new run
#   lab Matrix empty (only the lab admin)      -> import
#   lab Matrix holds the result of an earlier import (fingerprint unchanged) -> import (replaces it)
#   lab Matrix holds anything else              -> ABORT; --replace replaces it after [y/N] and after a snapshot
#   server_name of the dump differs from the lab's, or both signing keys are set and differ -> ABORT (run prepare)
#   lab Synapse older than the Synapse of the dump -> ABORT (a newer schema cannot be run by an older Synapse)
#   dump older than --max-age hours (default 24)   -> WARNING (the import still runs; a cutover needs a fresh dump)
#
# Options: --dry-run, --replace, --yes (answers the [y/N] of --replace), --reimport, --no-backup (no snapshot before a
#   replace and none after the import; explicit), --max-age HOURS, --age-key FILE (default $SOPS_AGE_KEY_FILE or
#   ~/.config/sops/age/keys.txt), --base-url URL (default https://matrix.<domain> from lab.sh, or
#   https://matrix.lab.example), --cacert FILE (default ~/.config/k8s-lab/lab-ca.crt), --resolve HOST:PORT:IP,
#   --namespace NS (default matrix), --context CTX.
# Environment (tests and other clusters): MATRIX_IMPORT_DB_HOST (default matrix-db-rw, the direct service, not the
#   pooler), MATRIX_IMPORT_PSQL_IMAGE (default: image of the CNPG cluster matrix-db), MATRIX_IMPORT_DEPLOY (synapse),
#   MATRIX_IMPORT_ARGO_NS (argocd), MATRIX_IMPORT_ARGO_APPS (root matrix; root FIRST), MATRIX_IMPORT_VERIFY_LOGIN
#   ("user:password ..." of dump users whose old password must still work; test only), MATRIX_IMPORT_SIGNING_KEY_FILE
#   and MATRIX_IMPORT_REPO (prepare; lab.sh sets both), MATRIX_IMPORT_BASE_URL.
# No secret value is printed or put on a command line. /_synapse/admin is never used from outside (Traefik blocks it).
# Exit codes: 0 ok / SKIP, 1 error or ABORT, 2 usage.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TOOLDIR="$HERE/matrix-import"

NS=${MATRIX_IMPORT_NS:-matrix}
KCTX=()
DEPLOY=${MATRIX_IMPORT_DEPLOY:-synapse}
CLUSTER=matrix-db
SCHEDULE=matrix-files
DB_HOST=${MATRIX_IMPORT_DB_HOST:-matrix-db-rw}
DB_SECRET=${MATRIX_IMPORT_DB_SECRET:-matrix-db-owner}
DB_NAME=${MATRIX_IMPORT_DB_NAME:-matrix}
ADMIN_SECRET=${MATRIX_IMPORT_ADMIN_SECRET:-matrix-admin}
SIGNING_SECRET=${MATRIX_IMPORT_SIGNING_SECRET:-matrix-signing-key}
HOMESERVER_CM=matrix-homeserver
ARGO_NS=${MATRIX_IMPORT_ARGO_NS:-argocd}
ARGO_APPS=${MATRIX_IMPORT_ARGO_APPS:-root matrix}
STATE_CM=matrix-import-state
DB_POD=matrix-import-db
FILES_POD=matrix-import-files
BASE_URL=${MATRIX_IMPORT_BASE_URL:-https://matrix.lab.example}
CACERT=""
RESOLVE=""
AGE_KEY=""
MAX_AGE=24
REPLACE=0
YES=0
DRY_RUN=0
REIMPORT=0
NO_BACKUP=0
DUMP=""
MODE=import
SCRATCH=""
LABADMIN=""

# ---------------------------------------------------------------- output
info() { echo "matrix-import: $*"; }
warn() { echo "matrix-import: WARNING: $*" >&2; }
die() { echo "matrix-import: ERROR: $*" >&2; exit 1; }
abort() { echo "matrix-import: ABORT: $*" >&2; exit 1; }
usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2; exit 2; }

k() { kubectl "${KCTX[@]}" -n "$NS" "$@"; }
kg() { kubectl "${KCTX[@]}" "$@"; }

# ---------------------------------------------------------------- options
parse_args() {
  local sub=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --replace) REPLACE=1; shift ;;
      --yes) YES=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      --reimport) REIMPORT=1; shift ;;
      --no-backup) NO_BACKUP=1; shift ;;
      --max-age) [ $# -ge 2 ] || usage; MAX_AGE=$2; shift 2 ;;
      --base-url) [ $# -ge 2 ] || usage; BASE_URL=${2%/}; shift 2 ;;
      --cacert) [ $# -ge 2 ] || usage; CACERT=$2; shift 2 ;;
      --resolve) [ $# -ge 2 ] || usage; RESOLVE=$2; shift 2 ;;
      --age-key) [ $# -ge 2 ] || usage; AGE_KEY=$2; shift 2 ;;
      --namespace) [ $# -ge 2 ] || usage; NS=$2; shift 2 ;;
      --context) [ $# -ge 2 ] || usage; KCTX=(--context "$2"); shift 2 ;;
      -h | --help | help) usage ;;
      -*) echo "matrix-import: unknown option: $1" >&2; usage ;;
      *)
        if [ "$sub" = 0 ] && [ -z "$DUMP" ]; then
          case "$1" in
            recipients | accept | recover | backup | prepare) MODE=$1; sub=1; shift; continue ;;
          esac
        fi
        [ -z "$DUMP" ] || { echo "matrix-import: more than one dump file given" >&2; usage; }
        DUMP=$1; shift ;;
    esac
  done
  case $MODE in
    import | prepare) [ -n "$DUMP" ] || { echo "matrix-import: no dump file given" >&2; usage; } ;;
    *) [ -z "$DUMP" ] || { echo "matrix-import: '$MODE' takes no dump file" >&2; usage; } ;;
  esac
  if [ "$MODE" != import ] && { [ "$REPLACE" = 1 ] || [ "$DRY_RUN" = 1 ] || [ "$REIMPORT" = 1 ]; }; then
    echo "matrix-import: --replace, --dry-run and --reimport only apply to an import" >&2; usage
  fi
  if [ "$YES" = 1 ] && [ "$REPLACE" != 1 ]; then
    echo "matrix-import: --yes only answers the question of --replace" >&2; usage
  fi
  case $MAX_AGE in '' | *[!0-9]*) echo "matrix-import: --max-age takes whole hours" >&2; usage ;; esac
  if [ -z "$CACERT" ] && [ -f "$HOME/.config/k8s-lab/lab-ca.crt" ]; then
    CACERT="$HOME/.config/k8s-lab/lab-ca.crt"
  fi
  AGE_KEY=${AGE_KEY:-${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}}
  return 0
}

# ---------------------------------------------------------------- scratch space (small, no plain text of the dump)
cleanup_scratch() {
  [ -n "$SCRATCH" ] && [ -d "$SCRATCH" ] || return 0
  rm -rf "$SCRATCH"
}

make_scratch() { SCRATCH=$(mktemp -d); chmod 700 "$SCRATCH"; }

# ---------------------------------------------------------------- generic helpers
need_tool() { command -v "$1" >/dev/null 2>&1 || die "$1 is not installed (needed: $2)."; }

# Compare dotted versions: version_ge A B is true when A >= B.
version_ge() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1)" = "$2" ]; }

# Reduce "v1.164.1@sha256:..." or "1.140.0rc1" to 1.164.1 / 1.140.0.
version_of() { printf '%s\n' "$1" | sed -n 's/^[^0-9]*\([0-9][0-9]*\.[0-9][0-9]*\(\.[0-9][0-9]*\)\{0,1\}\).*/\1/p' | head -n 1; }

json_get() { python3 -c 'import json,sys
d=json.load(sys.stdin)
for part in sys.argv[1].split("."):
    d=d.get(part, "") if isinstance(d, dict) else ""
print(d if d is not None else "")' "$1"; }

state_get() { k get cm "$STATE_CM" -o go-template="{{index .data \"$1\"}}" 2>/dev/null | sed 's/^<no value>$//' || true; }

# state_set KEY VALUE [KEY VALUE ...]: merge into the ConfigMap (created when missing); a value of "-" deletes the key.
state_set() {
  local pf="$SCRATCH/patch.json"
  k get cm "$STATE_CM" >/dev/null 2>&1 || k create cm "$STATE_CM" >/dev/null
  python3 -c 'import json,sys
a=sys.argv[1:]
print(json.dumps({"data":{a[i]:(None if a[i+1]=="-" else a[i+1]) for i in range(0,len(a),2)}}))' "$@" >"$pf"
  k patch cm "$STATE_CM" --type merge --patch-file "$pf" >/dev/null
}

ask_yn() { # ask_yn QUESTION: returns 0 only for y/Y/yes
  local ans=""
  [ -t 0 ] || return 1
  read -r -p "$1 [y/N] " ans || true
  case $ans in y | Y | yes | YES) return 0 ;; *) return 1 ;; esac
}

# The dump: decrypt into a pipe, never into a file. dt JOB reads as far as the job needs and returns the status of the
# tool. A reader that stops early (meta, secret) makes age die of SIGPIPE (141): that is not an error of the dump.
dump_stream() {
  local rc=0
  age -d -i "$AGE_KEY" "$DUMP" || rc=$?
  [ "$rc" = 0 ] || [ "$rc" = 141 ] || return "$rc"
}
dt() {
  local rc
  dump_stream | python3 "$TOOLDIR/dump-tool.py" "$@" || rc=$?
  return "${rc:-0}"
}
# Same, with the status of the tool taken from the pipeline (a downstream pipe is the caller's business).
dt_pipe() { dump_stream | python3 "$TOOLDIR/dump-tool.py" "$@"; }

# psql in the helper pod; arguments are psql arguments, stdin is passed through.
sql() { k exec -i "$DB_POD" -c psql -- psql -X -q -v ON_ERROR_STOP=1 "$@"; }
sqlq() { sql -At "$@"; }                   # query, bare output
# shellcheck disable=SC2120
sqls() { sqlq -v "labadmin=$LABADMIN" -v "server_name=${SERVER_NAME:-}" "$@"; }

# ---------------------------------------------------------------- preflight
preflight() {
  need_tool kubectl "talk to the cluster"
  need_tool python3 "read the dump and build JSON"
  need_tool sha256sum "dump identity"
  need_tool base64 "read secrets"
  kg get ns "$NS" >/dev/null 2>&1 || die "namespace $NS not reachable (KUBECONFIG? cluster up?)."
  k get deploy "$DEPLOY" >/dev/null 2>&1 || die "deployment $DEPLOY not found in namespace $NS."
  k get secret "$DB_SECRET" >/dev/null 2>&1 || die "secret $DB_SECRET not found in namespace $NS."
  k get secret "$ADMIN_SECRET" >/dev/null 2>&1 || die "secret $ADMIN_SECRET not found in namespace $NS."
  LABADMIN=$(k get secret "$ADMIN_SECRET" -o go-template='{{index .data "username"}}' | base64 -d)
  [ -n "$LABADMIN" ] || die "secret $ADMIN_SECRET has no username."
  case $LABADMIN in *[!a-z0-9._=/+-]*) die "the lab admin name has characters Synapse does not allow in a localpart." ;; esac
}

lab_image() { k get deploy "$DEPLOY" -o jsonpath='{.spec.template.spec.containers[0].image}'; }
lab_version() {
  local v img
  img=$(lab_image)
  img=${img%%@*}
  v=$(version_of "${img##*:}")
  [ -n "$v" ] || die "cannot read the lab Synapse version from the image tag of deployment $DEPLOY."
  printf '%s\n' "$v"
}
lab_server_name() {
  k get cm "$HOMESERVER_CM" -o jsonpath='{.data.homeserver\.yaml}' | sed -n 's/^ *server_name: *"\{0,1\}\([^" ]*\)"\{0,1\} *$/\1/p' | head -n 1
}

# ---------------------------------------------------------------- helper pods
delete_pods() {
  k delete pod "$DB_POD" "$FILES_POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}

start_db_pod() {
  local img
  img=${MATRIX_IMPORT_PSQL_IMAGE:-$(k get cluster.postgresql.cnpg.io "$CLUSTER" -o jsonpath='{.spec.imageName}' 2>/dev/null || true)}
  [ -n "$img" ] || die "no psql image: the CNPG cluster $CLUSTER has no spec.imageName; set MATRIX_IMPORT_PSQL_IMAGE (digest-pinned)."
  k delete pod "$DB_POD" --ignore-not-found --wait=true >/dev/null 2>&1 || true
  python3 "$TOOLDIR/pods.py" db "$img" "$DB_HOST" 5432 "$DB_NAME" require "$DB_SECRET" | k apply -f - >/dev/null
  k wait --for=condition=Ready "pod/$DB_POD" --timeout=180s >/dev/null 2>&1 || die "helper pod $DB_POD did not become ready (image pull? NetworkPolicy?): kubectl -n $NS describe pod $DB_POD"
  sqlq -c 'SELECT 1' >/dev/null 2>&1 || die "helper pod $DB_POD cannot reach the database at $DB_HOST (host, credentials, SSL mode)."
}

start_files_pod() {
  k delete pod "$FILES_POD" --ignore-not-found --wait=true >/dev/null 2>&1 || true
  k get deploy "$DEPLOY" -o json | python3 "$TOOLDIR/pods.py" files | k apply -f - >/dev/null
  k wait --for=condition=Ready "pod/$FILES_POD" --timeout=180s >/dev/null 2>&1 || die "helper pod $FILES_POD did not become ready (the PVC is ReadWriteOnce: same node as Synapse?): kubectl -n $NS describe pod $FILES_POD"
}

fx() { k exec -i "$FILES_POD" -- "$@"; }

# ---------------------------------------------------------------- Argo CD: pause auto-sync, restore it
argo_present() {
  kg get crd applications.argoproj.io >/dev/null 2>&1 || return 1
  local a
  for a in $ARGO_APPS; do
    kg -n "$ARGO_NS" get application "$a" >/dev/null 2>&1 || return 1
  done
}

argo_pause() {
  local a cur
  if ! argo_present; then
    info "Argo CD applications ($ARGO_APPS) not found: nothing to pause."
    return 0
  fi
  for a in $ARGO_APPS; do
    cur=$(kg -n "$ARGO_NS" get application "$a" -o jsonpath='{.spec.syncPolicy.automated}')
    if [ -n "$cur" ]; then
      state_set "argo_$a" "$cur"
      kg -n "$ARGO_NS" patch application "$a" --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}' >/dev/null
      info "Argo CD auto-sync of $a paused (restored at the end)."
    fi
  done
}

argo_restore() {
  local a cur rev=""
  argo_present || return 0
  for a in $ARGO_APPS; do rev="$a $rev"; done   # child first, root last
  for a in $rev; do
    cur=$(state_get "argo_$a")
    [ -n "$cur" ] || continue
    kg -n "$ARGO_NS" patch application "$a" --type merge -p "{\"spec\":{\"syncPolicy\":{\"automated\":$cur}}}" >/dev/null
    state_set "argo_$a" -
    info "Argo CD auto-sync of $a restored."
  done
}

# ---------------------------------------------------------------- Synapse replicas
synapse_scale_down() {
  local cur
  cur=$(k get deploy "$DEPLOY" -o jsonpath='{.spec.replicas}')
  if [ "${cur:-0}" != 0 ]; then state_set scaled_from "$cur"; fi
  k scale deploy "$DEPLOY" --replicas=0 >/dev/null
  for _ in $(seq 1 90); do
    [ -z "$(k get pods -l "app.kubernetes.io/name=$DEPLOY" -o name 2>/dev/null)" ] && return 0
    sleep 2
  done
  die "Synapse pods did not stop within 180 s."
}

synapse_scale_up() {
  local n
  n=$(state_get scaled_from)
  k scale deploy "$DEPLOY" --replicas="${n:-1}" >/dev/null
  k rollout status "deploy/$DEPLOY" --timeout=900s >/dev/null 2>&1 || die "Synapse did not become ready after the import: kubectl -n $NS logs deploy/$DEPLOY"
  state_set scaled_from -
}

# The entrypoint creates the lab admin after Synapse is healthy; wait for that row before anything counts users.
wait_lab_admin() {
  local n
  for _ in $(seq 1 60); do
    n=$(sqls <<'SQL' 2>/dev/null || true
SELECT count(*) FROM users WHERE split_part(name, ':', 1) = '@' || :'labadmin';
SQL
)
    [ "$n" = 1 ] && return 0
    sleep 2
  done
  die "the lab admin '$LABADMIN' did not appear in the database within 120 s (kubectl -n $NS logs deploy/$DEPLOY)."
}

# ---------------------------------------------------------------- the dump: inspect, versions, identity
# Sets META (JSON file), DUMP_SHA, SERVER_NAME, SRC_VERSION and the INS_* numbers.
open_dump() {
  [ -f "$DUMP" ] || die "dump file not found: $DUMP"
  [ -r "$AGE_KEY" ] || die "age key file not readable: $AGE_KEY (--age-key FILE or SOPS_AGE_KEY_FILE)."
  need_tool age "open the dump"
  DUMP_SHA=$(sha256sum "$DUMP" | awk '{ print $1 }')
  info "reading the whole dump once to verify it (decrypted into a pipe, nothing is written to disk) ..."
  dt_pipe inspect >"$SCRATCH/inspect.json" || die "the dump is not usable (see the error above). Make a new one with scripts/matrix-import-vps-dump.sh."
  python3 -c 'import json,sys; json.dump(json.load(open(sys.argv[1]))["meta"], sys.stdout)' "$SCRATCH/inspect.json" >"$SCRATCH/meta.json"
  SERVER_NAME=$(json_get server_name <"$SCRATCH/meta.json")
  SRC_VERSION=$(version_of "$(json_get synapse_version <"$SCRATCH/meta.json")")
  [ -n "$SERVER_NAME" ] || die "the dump meta has no server_name."
  [ -n "$SRC_VERSION" ] || die "the dump meta has no readable Synapse version."
  INS_media_files=$(json_get observed.media_files <"$SCRATCH/inspect.json")
  INS_media_bytes=$(json_get observed.media_bytes <"$SCRATCH/inspect.json")
  INS_db_bytes=$(json_get observed.db_bytes <"$SCRATCH/inspect.json")
}

report_dump() {
  local created host cont zone age_h
  created=$(json_get created_utc <"$SCRATCH/meta.json")
  host=$(json_get source_host <"$SCRATCH/meta.json")
  cont=$(json_get source_container <"$SCRATCH/meta.json")
  zone=$(date -d "$created" '+%F %T %Z' 2>/dev/null || echo "?")
  age_h=$(python3 -c 'import datetime,sys
try:
    t=datetime.datetime.strptime(sys.argv[1], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
    d=datetime.datetime.now(datetime.timezone.utc)-t
    print(int(d.total_seconds()//60))
except ValueError:
    print(-1)' "$created")
  info "dump: sha256 ${DUMP_SHA:0:12}..., made $created UTC (here: $zone), $(( age_h / 60 )) h $(( age_h % 60 )) min ago"
  info "dump: source host '$host' (container '$cont'), server_name $SERVER_NAME, Synapse $SRC_VERSION, Postgres $(json_get pg_version <"$SCRATCH/meta.json")"
  info "dump: $(json_get users <"$SCRATCH/meta.json") users, $(json_get rooms <"$SCRATCH/meta.json") rooms, $(json_get events <"$SCRATCH/meta.json") events, media $INS_media_files files / $((INS_media_bytes / 1048576)) MiB, SQL $((INS_db_bytes / 1048576)) MiB"
  if [ "$age_h" -lt 0 ]; then
    warn "cannot read the creation time of the dump."
  elif [ "$age_h" -gt $((MAX_AGE * 60)) ]; then
    warn "the dump is older than --max-age ${MAX_AGE} h. Everything written on the source since then is missing. Fine for a rehearsal; make a fresh dump before a cutover."
  fi
  info "dump: signing key (public part) $(json_get verify_key.id <"$SCRATCH/meta.json") $(json_get verify_key.key <"$SCRATCH/meta.json")"
}

check_dump_versions() {
  local lab pg_src pg_lab
  lab=$(lab_version)
  info "lab Synapse $lab, dump from Synapse $SRC_VERSION"
  version_ge "$lab" "$SRC_VERSION" || abort "the lab Synapse ($lab) is older than the Synapse of the dump ($SRC_VERSION). A newer schema cannot be run by an older Synapse: raise the image in gitops/charts/matrix/templates/deployment-synapse.yaml first (pin tag and digest)."
  pg_src=$(version_of "$(json_get pg_version <"$SCRATCH/meta.json")")
  pg_lab=$(($(sqlq -c 'SHOW server_version_num') / 10000))
  [ -n "$pg_src" ] || warn "the dump meta has no Postgres version."
  if [ -n "$pg_src" ] && [ "${pg_src%%.*}" -gt "$pg_lab" ]; then
    abort "the dump comes from Postgres ${pg_src%%.*}, the lab runs Postgres $pg_lab: a newer pg_dump may write SQL an older server cannot read."
  fi
  [ "$(json_get datcollate <"$SCRATCH/meta.json")" = C ] || abort "the source database collation is '$(json_get datcollate <"$SCRATCH/meta.json")', Synapse needs C (and the lab database is C)."
  [ "$(json_get password_pepper <"$SCRATCH/meta.json")" != True ] || abort "the source uses password_config.pepper: the pepper is a secret that is not in the dump, so no imported password would work."
  [ "$(json_get media_storage_providers <"$SCRATCH/meta.json")" != True ] || abort "the source uses media_storage_providers: media outside the media store is not in the dump."
}

# server_name and signing key: prepare decides them, the import only checks them.
check_identity() {
  local lab_name d_sha s_sha
  lab_name=$(lab_server_name)
  [ -n "$lab_name" ] || die "cannot read server_name from the ConfigMap $HOMESERVER_CM."
  [ "$lab_name" = "$SERVER_NAME" ] || abort "the lab Matrix runs as '$lab_name', the dump is from '$SERVER_NAME'. The server_name is the identity and cannot change after the import: run 'bash scripts/lab.sh matrix-import prepare DUMP', then customize, init, commit, push, wait until Argo CD synced, and import again. Nothing was changed."
  d_sha=$(dt secret-sha signing.key) || die "the dump has no signing key."
  s_sha=$(k get secret "$SIGNING_SECRET" -o jsonpath='{.data.signing\.key}' 2>/dev/null | base64 -d 2>/dev/null | python3 -c 'import hashlib,sys
v=sys.stdin.read().strip()
print(hashlib.sha256(v.encode()).hexdigest() if v else "")' || true)
  [ -n "$s_sha" ] || abort "the lab secret $SIGNING_SECRET is empty: the signing key would live only on the volume and a plain rebuild would throw it away. Run 'prepare' (it writes the key to the file that 'lab.sh init' encrypts into SOPS), init, commit, push, wait for Argo CD. Nothing was changed."
  [ "$s_sha" = "$d_sha" ] || abort "the lab secret $SIGNING_SECRET holds another signing key than the dump. Refusing to guess which is right. Nothing was changed."
  SIGNING_SHA=$d_sha
  info "identity: server_name $SERVER_NAME and signing key match the lab configuration (key hash ${SIGNING_SHA:0:12}..., secret $SIGNING_SECRET)."
}

report_config() {
  local out cfg
  cfg="$SCRATCH/lab-homeserver.yaml"
  k get cm "$HOMESERVER_CM" -o jsonpath='{.data.homeserver\.yaml}' >"$cfg"
  info "lab config (not touched): federation off, registration off; the source settings are NOT carried over:"
  out=$(python3 "$TOOLDIR/dump-tool.py" diff "$cfg" <"$SCRATCH/meta.json" || true)
  if [ -n "$out" ]; then printf '%s\n' "$out" | sed 's/^/matrix-import:   INFO  /'; fi
  if grep -q '^ *oidc_providers:' "$cfg"; then
    if grep -Eq '^ *allow_existing_users: *true' "$cfg"; then
      info "login: OIDC is configured with allow_existing_users: true, imported accounts link to Keycloak users with the same localpart."
    else
      warn "OIDC is configured but allow_existing_users is not true: a Keycloak login for an imported localpart is refused (no second account is made). Passwords of the imported accounts keep working. See docs/how-to/matrix-import.md, section Keycloak."
    fi
  fi
  grep -Eq '^ *federation_domain_whitelist: *\[\] *$' "$cfg" || warn "federation_domain_whitelist is not [] in the lab config: federation would not be off."
}

# ---------------------------------------------------------------- the lab database
live_has_table() { [ "$(sqlq -c "SELECT to_regclass('public.$1') IS NOT NULL")" = t ]; }

# Prints "USERS ROOMS MEDIA" of the live database without the lab admin.
live_counts() {
  if ! live_has_table users || ! live_has_table rooms || ! live_has_table local_media_repository; then echo "0 0 0"; return 0; fi
  local u r m
  u=$(sqls <<'SQL'
SELECT count(*) FROM users WHERE split_part(name, ':', 1) <> '@' || :'labadmin';
SQL
)
  r=$(sqlq -c 'SELECT count(*) FROM rooms')
  m=$(sqlq -c 'SELECT count(*) FROM local_media_repository')
  echo "$u $r $m"
}

live_fingerprint() {
  if ! live_has_table users || ! live_has_table rooms || ! live_has_table events || ! live_has_table local_media_repository; then
    echo "none"; return 0
  fi
  sqls <"$TOOLDIR/fingerprint.sql"
}

check_swap_rights() {
  local ok
  ok=$(sqlq -c "SELECT (nspowner = 'pg_database_owner'::regrole OR pg_has_role(current_user, nspowner, 'USAGE')) FROM pg_namespace WHERE nspname = 'public'")
  [ "$ok" = t ] || abort "the database user cannot rename and recreate the schema public (owner is not the database owner). Nothing was changed."
}

# load_dump commit|rollback: one transaction. Output goes to $SCRATCH/load.out; sets the manifest in $SCRATCH/manifest.txt.
load_dump() {
  local mode=$1 rc=0 tail_sql
  tail_sql=$(if [ "$mode" = commit ]; then printf '%s\n' "SET LOCAL lock_timeout = '30s';" 'DROP SCHEMA mxi_old CASCADE;' 'COMMIT;' '\echo MXI-COMMITTED'; else printf '%s\n' 'ROLLBACK;' '\echo MXI-ROLLED-BACK'; fi)
  if [ "$mode" = commit ]; then
    # Synapse is scaled to 0, but its old database sessions can outlive the pod (a half-dead TCP connection), and so can
    # the sessions of earlier helper pods. One of them in the middle of a CREATE INDEX CONCURRENTLY (a Synapse
    # background update) would block the schema swap for ever. Only the sessions of the pod that runs this import stay.
    local gone
    gone=$(sqlq -c "SELECT count(*) FROM (SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = current_database() AND usename = current_user AND pid <> pg_backend_pid() AND client_addr IS DISTINCT FROM inet_client_addr()) t")
    info "closed $gone stale database session(s) of other pods (Synapse is down)."
  fi
  info "loading the dump SQL in one transaction ($mode) ..."
  {
    cat "$TOOLDIR/load-head.sql"
    dt db || exit 1
    cat "$TOOLDIR/load-tail.sql" "$TOOLDIR/manifest.sql"
    printf '%s\n' '\echo MXI-LOADED'
    printf '%s\n' "$tail_sql"
  } | sqls >"$SCRATCH/load.out" 2>"$SCRATCH/load.err" || rc=$?
  if grep -q '^MXI-ABORT ' "$SCRATCH/load.out"; then
    abort "$(sed -n 's/^MXI-ABORT //p' "$SCRATCH/load.out" | head -n 1). Nothing was changed."
  fi
  if [ "$rc" != 0 ] || ! grep -q '^MXI-LOADED$' "$SCRATCH/load.out"; then
    sed 's/^\(.\{0,200\}\).*/\1/' "$SCRATCH/load.err" | tail -n 8 >&2 || true
    if grep -q 'lock timeout' "$SCRATCH/load.err"; then
      warn "another database session holds a lock on the live schema (Synapse still running, a background job?): scale Synapse down or retry; a real import closes stale sessions itself."
    fi
    die "the dump SQL could not be loaded or checked (psql status $rc, last lines above). The transaction was rolled back: the lab database is unchanged."
  fi
  if [ "$mode" = commit ] && ! grep -q '^MXI-COMMITTED$' "$SCRATCH/load.out"; then
    die "the load finished but the COMMIT was not confirmed. Run the same command again (it resumes)."
  fi
  grep '^M ' "$SCRATCH/load.out" >"$SCRATCH/manifest.txt"
  LOADED_SCHEMA=$(sed -n 's/^V //p' "$SCRATCH/load.out" | head -n 1)
}

# ---------------------------------------------------------------- snapshot (fresh CNPG base backup + K8up backup, Matrix only)
wait_condition() { # wait_condition KIND NAME JSONPATH GOODVALUE BADVALUE TRIES
  local v
  for _ in $(seq 1 "$6"); do
    v=$(k get "$1" "$2" -o jsonpath="$3" 2>/dev/null || true)
    [ "$v" = "$4" ] && return 0
    [ -n "$5" ] && [ "$v" = "$5" ] && return 1
    sleep 5
  done
  return 1
}

# A K8up Backup (files) and a CNPG Backup (database) of the CURRENT state, both awaited. Aborts when no snapshot can be
# made. A fresh base backup is what 'rebuild --restore' restores from, so the imported state survives a rebuild.
take_snapshot() { # take_snapshot LABEL
  local stamp name have_k8up=0 have_cnpg=0 label=$1
  stamp=$(date +%Y%m%d-%H%M%S)
  kg get crd backups.k8up.io >/dev/null 2>&1 && k get schedule.k8up.io "$SCHEDULE" >/dev/null 2>&1 && have_k8up=1
  kg get crd backups.postgresql.cnpg.io >/dev/null 2>&1 && k get cluster.postgresql.cnpg.io "$CLUSTER" >/dev/null 2>&1 && have_cnpg=1
  if [ "$have_k8up" = 0 ] || [ "$have_cnpg" = 0 ]; then
    return 3
  fi
  name="matrix-import-$label-$stamp"
  info "snapshot: K8up backup of the Matrix files ($name) ..."
  k get schedule.k8up.io "$SCHEDULE" -o json | python3 -c '
import json, sys
s = json.load(sys.stdin)["spec"]
b = {"apiVersion": "k8up.io/v1", "kind": "Backup", "metadata": {"name": sys.argv[1]},
     "spec": {"backend": s["backend"], "failedJobsHistoryLimit": 1, "successfulJobsHistoryLimit": 1}}
if "podConfigRef" in s:
    b["spec"]["podConfigRef"] = s["podConfigRef"]
json.dump(b, sys.stdout)' "$name" | k apply -f - >/dev/null
  wait_condition backup.k8up.io "$name" '{.status.conditions[?(@.type=="Completed")].reason}' Succeeded Failed 360 || return 4
  info "snapshot: CNPG base backup of $CLUSTER ($name) ..."
  python3 -c '
import json, sys
json.dump({"apiVersion": "postgresql.cnpg.io/v1", "kind": "Backup", "metadata": {"name": sys.argv[1]},
           "spec": {"cluster": {"name": sys.argv[2]}, "method": "plugin",
                    "pluginConfiguration": {"name": "barman-cloud.cloudnative-pg.io"}}}, sys.stdout)' "$name" "$CLUSTER" | k apply -f - >/dev/null
  wait_condition backup.postgresql.cnpg.io "$name" '{.status.phase}' completed failed 360 || return 5
  python3 "$HERE/lab-wal-ready.py" --cluster "$NS/$CLUSTER" || return 6
  state_set "snapshot_$label" "$name"
  info "snapshot done ($name)."
}

snapshot_or_abort() { # before the content is replaced: no snapshot, no replace
  local rc=0 label=$1
  if [ "$NO_BACKUP" = 1 ]; then warn "--no-backup: no snapshot is taken before the content is replaced."; return 0; fi
  take_snapshot "$label" || rc=$?
  case $rc in
    0) ;;
    3) abort "no snapshot possible (K8up Schedule $SCHEDULE or CNPG cluster $CLUSTER not found). Replacing existing content without a snapshot needs --no-backup." ;;
    *) abort "the snapshot failed (code $rc; kubectl -n $NS get backup.k8up.io,backup.postgresql.cnpg.io). Nothing was changed." ;;
  esac
}

# ---------------------------------------------------------------- files: media store and secrets
check_free_space() {
  local avail used need
  avail=$(fx df -Pk /data | awk 'NR == 2 { print $4 }')
  used=$(fx sh -c 'du -sk /data/media_store 2>/dev/null | cut -f1' </dev/null || echo 0)
  need=$(( INS_media_bytes / 1024 * 105 / 100 + 1024 ))
  info "volume: ${avail} KiB free, media store now ${used:-0} KiB (it is replaced), the dump needs about ${need} KiB"
  [ $((avail + ${used:-0})) -ge "$need" ] || abort "the volume matrix-data is too small for the media of the dump (need about $((need / 1024)) MiB, have $(( (avail + ${used:-0}) / 1024 )) MiB). Raise the size of the PVC in gitops/workloads/matrix/manifests/pvc.yaml. Nothing was changed."
}

restore_files() {
  local name
  start_files_pod
  info "files: replacing the media store ($INS_media_files files) ..."
  fx sh -c 'set -e; mkdir -p /data/media_store; find /data/media_store -mindepth 1 -delete' </dev/null
  dt_pipe media | fx tar -xf - -C /data/media_store || die "unpacking the media into the volume failed."
  info "files: installing the signing key and the secrets (values are never printed) ..."
  dt_pipe secret signing.key | fx sh -c 'set -e; umask 077; cat >/data/signing.key.new; [ -s /data/signing.key.new ]; mv /data/signing.key.new /data/signing.key'
  for name in macaroon.secret form.secret; do
    if dt secret-sha "$name" >/dev/null 2>&1; then
      if dt_pipe secret "$name" | python3 -c 'import sys
v = sys.stdin.read().strip()
if not v or any(c in v for c in "\"\\\n"):
    sys.exit(1)
print(v)' | fx sh -c "set -e; umask 077; cat >/data/$name.new; [ -s /data/$name.new ]; mv /data/$name.new /data/$name"; then
        info "files: $name carried over"
      else
        fx rm -f "/data/$name.new" </dev/null || true
        warn "$name of the source has characters the lab config cannot hold (quote or backslash): not carried over, Synapse makes a new one. Only login tokens older than the first Synapse of the source are affected."
      fi
    fi
  done
}

# ---------------------------------------------------------------- acceptance
PASS=0
FAILS=0
check() { # check "label" "ok|fail [detail]"
  local st=${2%% *} d=""
  [ "$2" = "$st" ] || d=${2#* }
  if [ "$st" = ok ]; then PASS=$((PASS + 1)); echo "  PASS  $1"; else FAILS=$((FAILS + 1)); echo "  FAIL  $1${d:+ ($d)}"; fi
}
okfail() { if [ "$1" = 0 ]; then echo ok; else echo fail; fi; }

mval() { sed -n "s/^M $2 //p" "$1" | head -n 1; }

http_opts() {
  HTTP_OPTS=()
  [ -z "$CACERT" ] || HTTP_OPTS+=(--cacert "$CACERT")
  [ -z "$RESOLVE" ] || HTTP_OPTS+=(--resolve "$RESOLVE")
}

media_where() { # prints the WHERE of local media that must have a file (URL cache is not dumped)
  if [ "$(sqlq -c "SELECT count(*) FROM information_schema.columns WHERE table_name = 'local_media_repository' AND column_name = 'url_cache'")" = 1 ]; then
    echo "url_cache IS NULL"
  else
    echo "true"
  fi
}

# acceptance STRICT(1|0): counts must be equal when strict; otherwise nothing of the dump may have gone missing.
acceptance() {
  local strict=$1 cfg key live l e rooms_n devs bk media mid pair u p pw line
  PASS=0
  FAILS=0
  info "acceptance:"
  cfg="$SCRATCH/lab-homeserver.yaml"
  k get cm "$HOMESERVER_CM" -o jsonpath='{.data.homeserver\.yaml}' >"$cfg"
  state_get manifest >"$SCRATCH/manifest.exp"
  live="$SCRATCH/manifest.live"
  sqls <"$TOOLDIR/manifest.sql" | grep '^M ' >"$live" || true
  SERVER_NAME=$(state_get server_name)
  check "server_name of the lab is $SERVER_NAME" "$([ "$(lab_server_name)" = "$SERVER_NAME" ] && echo ok || echo fail)"
  check "every account in the database belongs to $SERVER_NAME" "$([ "$(sqlq -c "SELECT count(*) FROM users WHERE name NOT LIKE '%:$SERVER_NAME'")" = 0 ] && echo ok || echo fail)"
  for key in users rooms events local_media e2e_device_keys e2e_one_time_keys e2e_room_keys; do
    l=$(mval "$live" "$key")
    e=$(mval "$SCRATCH/manifest.exp" "$key")
    if [ "$strict" = 1 ]; then
      case $key in
        # E2EE key tables change on every client login (one-time keys are claimed and re-uploaded, key backups are
        # replaced), without the fingerprint noticing. A difference is reported, it is not missing data.
        e2e_*) if [ "$l" = "$e" ]; then check "$key: $l in the lab, $e in the dump (without the lab admin)" ok
          else info "INFO  $key: $l in the lab, $e in the dump (changes with client logins, not checked)"; fi ;;
        *) check "$key: $l in the lab, $e in the dump (without the lab admin)" "$([ "$l" = "$e" ] && echo ok || echo fail)" ;;
      esac
    else
      case $key in
        users | rooms | local_media | events) check "$key: $l in the lab, at least $e from the dump" "$([ "${l:-0}" -ge "${e:-0}" ] && echo ok || echo fail)" ;;
        *) ;;
      esac
    fi
  done
  for key in devices access_tokens; do
    l=$(mval "$live" "$key")
    e=$(mval "$SCRATCH/manifest.exp" "$key")
    check "$key: $l in the lab, at least $e from the dump (logins add more)" "$([ "${l:-0}" -ge "${e:-0}" ] && echo ok || echo fail)"
  done
  acceptance_files
  acceptance_identity
  if grep -Eq '^ *federation_domain_whitelist: *\[\] *$' "$cfg" && ! grep -Eq 'names: *\[[^]]*(federation|keys|openid)' "$cfg"; then
    check "federation is off in the Synapse config (empty whitelist, no federation or key listener)" ok
  else
    check "federation is off in the Synapse config (empty whitelist, no federation or key listener)" fail
  fi
  http_opts
  while read -r line; do
    case $line in "RESULT ok "*) check "${line#RESULT ok }" ok ;; "RESULT fail "*) check "${line#RESULT fail }" fail ;; *) ;; esac
  done < <(python3 "$TOOLDIR/accept-http.py" anon "$BASE_URL" "${HTTP_OPTS[@]}")
  pw=$(k get secret "$ADMIN_SECRET" -o go-template='{{index .data "password"}}' | base64 -d)
  while read -r line; do
    case $line in "RESULT ok "*) check "lab admin: ${line#RESULT ok }" ok ;; "RESULT fail "*) check "lab admin: ${line#RESULT fail }" fail ;; *) ;; esac
  done < <(MXI_PASSWORD=$pw python3 "$TOOLDIR/accept-http.py" user "$BASE_URL" "$SERVER_NAME" "$LABADMIN" "${HTTP_OPTS[@]}")
  pw=""
  if [ -n "${MATRIX_IMPORT_VERIFY_LOGIN:-}" ]; then
    media=$(sqlq -c "SELECT media_id || ':' || media_length FROM local_media_repository WHERE $(media_where) ORDER BY media_length DESC LIMIT 1")
    for pair in $MATRIX_IMPORT_VERIFY_LOGIN; do
      u=${pair%%:*}
      p=${pair#*:}
      rooms_n=$(sqlq -c "SELECT count(*) FROM local_current_membership WHERE user_id = '@$u:$SERVER_NAME' AND membership = 'join'")
      devs=$(sqlq -c "SELECT count(*) FROM e2e_device_keys_json WHERE user_id = '@$u:$SERVER_NAME'")
      bk=$(sqlq -c "SELECT count(*) FROM e2e_room_keys_versions WHERE user_id = '@$u:$SERVER_NAME' AND deleted = 0")
      [ "$bk" = 0 ] || bk=1
      while read -r line; do
        case $line in "RESULT ok "*) check "${line#RESULT ok }" ok ;; "RESULT fail "*) check "${line#RESULT fail }" fail ;; *) ;; esac
      done < <(MXI_PASSWORD=$p python3 "$TOOLDIR/accept-http.py" user "$BASE_URL" "$SERVER_NAME" "$u" "${HTTP_OPTS[@]}" \
        --rooms "$rooms_n" --e2e-devices "$devs" --backup "$bk" ${media:+--media "$media"})
    done
  fi
  mid=$(state_get snapshot_post)
  if [ -n "$mid" ]; then check "backup after the import: $mid (CNPG base backup and K8up backup)" ok; else info "  INFO  no backup after the import is recorded (bash scripts/lab.sh matrix-import backup)."; fi
  info "acceptance: $PASS passed, $FAILS failed"
  [ "$FAILS" = 0 ]
}

acceptance_files() {
  local out total missing mismatch
  start_files_pod
  total=$(sqlq -c "SELECT count(*) FROM local_media_repository WHERE $(media_where)")
  out=$(sqlq -c "SELECT media_id || ' ' || media_length FROM local_media_repository WHERE $(media_where)" | fx python -c '
import os, sys
missing = bad = 0
for line in sys.stdin:
    mid, size = line.split()
    path = "/data/media_store/local_content/%s/%s/%s" % (mid[0:2], mid[2:4], mid[4:])
    if not os.path.isfile(path):
        missing += 1
    elif os.path.getsize(path) != int(size):
        bad += 1
print(missing, bad)')
  missing=${out% *}
  mismatch=${out#* }
  check "media: all $total local media records have their file, with the recorded size" "$([ "$missing" = 0 ] && [ "$mismatch" = 0 ] && echo ok || echo "fail $missing missing, $mismatch wrong size")"
}

acceptance_identity() {
  local vol_sha vk exp_id exp_key
  vol_sha=$(fx sh -c 'if [ -f /data/signing.key ]; then printf "%s" "$(cat /data/signing.key)" | sha256sum | cut -d" " -f1; fi' </dev/null)
  check "signing key on the volume is the key of the dump (hash compared, never printed)" "$([ -n "$vol_sha" ] && [ "$vol_sha" = "$(state_get signing_sha)" ] && echo ok || echo fail)"
  vk=$(fx python -c '
from signedjson.key import encode_verify_key_base64, get_verify_key, read_signing_keys
with open("/data/signing.key") as h:
    for key in read_signing_keys(h):
        print(key.alg + ":" + key.version, encode_verify_key_base64(get_verify_key(key)))' </dev/null 2>/dev/null || true)
  exp_id=$(state_get verify_key_id)
  exp_key=$(state_get verify_key)
  check "verify key (public) of the lab is $exp_id $exp_key" "$([ "$vk" = "$exp_id $exp_key" ] && echo ok || echo fail)"
  vol_sha=$(k get secret "$SIGNING_SECRET" -o jsonpath='{.data.signing\.key}' 2>/dev/null | base64 -d 2>/dev/null | python3 -c 'import hashlib,sys
v=sys.stdin.read().strip()
print(hashlib.sha256(v.encode()).hexdigest() if v else "")' || true)
  check "the signing key is in the SOPS secret $SIGNING_SECRET (a rebuild keeps the identity)" "$([ -n "$vol_sha" ] && [ "$vol_sha" = "$(state_get signing_sha)" ] && echo ok || echo fail)"
}

# ---------------------------------------------------------------- main flows
NEED_CLUSTER=0
PHASE=idle   # idle | pre-swap (nothing changed yet: undo automatically) | post-swap (leave the state, say what to do)

finish_pre_swap() {
  argo_restore || true
  if [ "$(state_get scaled_from)" != "" ]; then synapse_scale_up || true; fi
}

on_exit() {
  local rc=$?
  trap - EXIT
  if [ "$rc" != 0 ]; then
    case $PHASE in
      pre-swap)
        warn "failed before the swap: undoing (Synapse up, Argo CD restored). The content was not changed."
        finish_pre_swap
        ;;
      post-swap)
        state_set status failed >/dev/null 2>&1 || true
        warn "failed AFTER the database swap: Synapse stays scaled to 0 and Argo CD auto-sync stays paused, because database and files may not match."
        warn "Run the same command again with the same dump (it resumes), or 'bash scripts/lab.sh matrix-import recover' to bring Synapse up as it is."
        ;;
    esac
  fi
  [ "$NEED_CLUSTER" = 0 ] || delete_pods
  cleanup_scratch
  exit "$rc"
}

# The database sessions that an interrupted run left behind (kubectl exec does not stop the psql in the helper pod when
# the client dies, so an open transaction can stay) are closed from the CNPG primary, as the postgres superuser over the
# local socket: no helper pod and no password are needed. Only sessions of the database of Matrix are touched.
db_close_stale_sessions() {
  local primary gone
  primary=$(k get pod -l "cnpg.io/cluster=$CLUSTER,cnpg.io/instanceRole=primary" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [ -z "$primary" ]; then warn "no primary pod of $CLUSTER found: stale database sessions were not closed."; return 0; fi
  gone=$(k exec "$primary" -c postgres -- psql -X -q -At -d "$DB_NAME" -c "SELECT count(*) FROM (SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = current_database() AND pid <> pg_backend_pid() AND backend_type = 'client backend') t" 2>/dev/null </dev/null || true)
  info "closed ${gone:-?} stale database session(s)."
}

do_recover() {
  info "recover: bringing the lab back to normal operation ..."
  delete_pods
  # only while Synapse is down: a running Synapse keeps its own sessions
  if [ "$(k get deploy "$DEPLOY" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)" = 0 ]; then db_close_stale_sessions; fi
  if [ -n "$(state_get scaled_from)" ]; then synapse_scale_up; else info "Synapse was not scaled down by this tool."; fi
  argo_restore
  state_set status recovered >/dev/null 2>&1 || true
  info "recover: done. State: $(k get deploy "$DEPLOY" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true) ready replica(s)."
}

do_recipients() {
  local f="$HERE/../.sops.yaml" keys args="" a
  # the SSH target of the old VPS: export MATRIX_IMPORT_SSH=user@address (ansible_user and ansible_host of the VPS inventory)
  local target=${MATRIX_IMPORT_SSH:-USER@VPS-ADDRESS}
  [ -f "$f" ] || die "$f not found."
  # grep finds nothing in a fresh clone (placeholder key); with pipefail that must not end the script silently.
  keys=$(grep -o 'age1[a-z0-9]\{50,\}' "$f" | awk '!seen[$0]++' || true)
  [ -n "$keys" ] || die "no age recipient found in .sops.yaml."
  echo "Public age recipients of .sops.yaml (the dump is encrypted for these; the private key opens it):"
  for a in $keys; do echo "  $a"; args="$args --recipient $a"; done
  echo
  echo "The VPS script only READS (pg_dump, tar of the media store and the signing key). It is streamed over SSH: nothing is"
  echo "installed or written on the VPS, and the dump leaves it encrypted (age is on the VPS, a private key is not)."
  echo "  1. Read-only checks, no dump:"
  echo "       ssh $target 'bash -s -- --check' < scripts/matrix-import-vps-dump.sh"
  echo "  2. The encrypted dump (the .partial name stays until the last line says done):"
  echo "       ssh $target 'bash -s --$args' < scripts/matrix-import-vps-dump.sh > matrix-dump.age.partial && mv matrix-dump.age.partial matrix-dump.age"
  echo "  3. bash scripts/lab.sh matrix-import prepare matrix-dump.age     (server_name and signing key; then customize, init, commit, push)"
  echo "  4. bash scripts/lab.sh matrix-import matrix-dump.age --dry-run"
  echo "  5. bash scripts/lab.sh matrix-import matrix-dump.age"
  echo "  6. bash scripts/lab.sh matrix-import accept"
}

do_prepare() {
  local keyfile repo local_yaml lab_yaml l_cur y_cur name d_sha f_sha dir secret_file s_sha
  need_tool age "open the dump"
  [ -f "$DUMP" ] || die "dump file not found: $DUMP"
  [ -r "$AGE_KEY" ] || die "age key file not readable: $AGE_KEY (--age-key FILE or SOPS_AGE_KEY_FILE)."
  keyfile=${MATRIX_IMPORT_SIGNING_KEY_FILE:-$HOME/.config/k8s-lab/matrix-k3s-lab-signing.key}
  repo=${MATRIX_IMPORT_REPO:-$(cd "$HERE/.." && pwd)}
  local_yaml="$repo/infra/envs/local/lab.local.yaml"
  dt meta >"$SCRATCH/meta.json" || die "the dump has no readable meta (make it with scripts/matrix-import-vps-dump.sh)."
  name=$(json_get server_name <"$SCRATCH/meta.json")
  case $name in '' | *[!a-z0-9.:-]* | .* | *..*) die "the server_name in the dump ('$name') is not a plain host name." ;; esac
  info "prepare: the dump is from server_name $name (Synapse $(json_get synapse_version <"$SCRATCH/meta.json"), host $(json_get source_host <"$SCRATCH/meta.json"))."

  # 1. the signing key file that lab.sh init encrypts into secrets/matrix/matrix-signing-key.sops.yaml
  d_sha=$(dt secret-sha signing.key) || die "the dump has no signing key."
  if [ -f "$keyfile" ]; then
    f_sha=$(python3 -c 'import hashlib,sys
v=open(sys.argv[1]).read().strip()
print(hashlib.sha256(v.encode()).hexdigest() if v else "")' "$keyfile")
    if [ "$f_sha" = "$d_sha" ]; then
      info "SKIP: $keyfile already holds the signing key of this dump."
    else
      abort "$keyfile exists and holds another signing key (or none). Move it away yourself if you are sure it is not needed; nothing was changed."
    fi
  else
    dir=$(dirname "$keyfile")
    mkdir -p "$dir"
    chmod 700 "$dir" 2>/dev/null || true
    (umask 077; dt_pipe secret signing.key >"$keyfile.new") || { rm -f "$keyfile.new"; die "could not read the signing key from the dump."; }
    [ -s "$keyfile.new" ] || { rm -f "$keyfile.new"; die "the signing key of the dump is empty."; }
    mv "$keyfile.new" "$keyfile"
    chmod 600 "$keyfile"
    info "prepare: signing key written to $keyfile (mode 600, value not shown)."
  fi

  # 1b. the lab's own signing key as SOPS secret (in Git since the first Matrix setup). lab.sh init encrypts the key file above
  # into the same path and ABORTs when the file exists with other content (ansible/scripts/sops-secret.sh from-json).
  # A different key is the lab's own throwaway identity: remove it on purpose, so init writes the key of the dump (issue 49).
  # Same key = SKIP. The key file above already holds the key of the dump, so nothing is lost. Values are never printed.
  secret_file="$repo/secrets/matrix/matrix-signing-key.sops.yaml"
  if [ ! -e "$secret_file" ]; then
    info "SKIP: $secret_file does not exist, lab.sh init creates it from the key file."
  else
    need_tool sops "read the existing signing key secret (decrypted only into a pipe)"
    s_sha=$(SOPS_AGE_KEY_FILE="$AGE_KEY" sops decrypt --input-type yaml --output-type json "$secret_file" 2>/dev/null | python3 -c 'import base64,hashlib,json,sys
o=json.load(sys.stdin)
v=(o.get("data") or {}).get("signing.key")
v=base64.b64decode(v).decode() if v is not None else (o.get("stringData") or {}).get("signing.key") or ""
v=v.strip()
print(hashlib.sha256(v.encode()).hexdigest() if v else "")') || abort "could not decrypt $secret_file with $AGE_KEY (or it has no signing.key). It is not removed: nothing was changed."
    if [ "$s_sha" = "$d_sha" ]; then
      info "SKIP: $secret_file already holds the signing key of this dump."
    else
      if [ -n "$s_sha" ]; then
        info "prepare: $secret_file holds another signing key (the lab's own, key hash ${s_sha:0:12}...), the dump has ${d_sha:0:12}...."
      else
        info "prepare: $secret_file holds no signing key, the dump has ${d_sha:0:12}...."
      fi
      if git -C "$repo" ls-files --error-unmatch -- secrets/matrix/matrix-signing-key.sops.yaml >/dev/null 2>&1 \
        && git -C "$repo" rm -q -f -- secrets/matrix/matrix-signing-key.sops.yaml >/dev/null 2>&1; then
        info "REMOVED: $secret_file (git rm, staged). lab.sh init encrypts the key of the dump into the same path; Git history keeps the old file."
      else
        rm -f -- "$secret_file"
        info "REMOVED: $secret_file (plain delete, the file was not tracked by Git). lab.sh init encrypts the key of the dump into the same path."
      fi
    fi
  fi

  # 2. matrix_server_name: the tracked lab.yaml is the one place the tests and lab.sh customize read, so its line is updated in
  # place (comments and every other line stay). lab.local.yaml, which overrides it, gets the same line when it has none.
  # A different value in lab.local.yaml is the operator's own choice: ABORT before anything is written.
  lab_yaml="$repo/infra/envs/local/lab.yaml"
  l_cur=$(sed -n 's/^matrix_server_name: *"\{0,1\}\([^" #]*\)"\{0,1\}.*$/\1/p' "$local_yaml" 2>/dev/null | head -n 1 || true)
  y_cur=$(sed -n 's/^matrix_server_name: *"\{0,1\}\([^" #]*\)"\{0,1\}.*$/\1/p' "$lab_yaml" 2>/dev/null | head -n 1 || true)
  if [ -n "$l_cur" ] && [ "$l_cur" != "$name" ]; then
    abort "$local_yaml sets matrix_server_name to '$l_cur', the dump is from '$name'. Edit that one line yourself; nothing was changed."
  elif [ "$y_cur" = "$name" ]; then
    info "SKIP: matrix_server_name is already $name."
  else
    if [ ! -f "$lab_yaml" ]; then
      warn "$lab_yaml does not exist: matrix_server_name is not written there."
    elif grep -q '^matrix_server_name:' "$lab_yaml"; then
      sed -i "s|^matrix_server_name:.*\$|matrix_server_name: $name|" "$lab_yaml"
      info "prepare: matrix_server_name: $name written to $lab_yaml (was '$y_cur')."
    else
      {
        [ -z "$(tail -c 1 "$lab_yaml")" ] || echo
        printf '%s\n' "matrix_server_name: $name"
      } >>"$lab_yaml"
      info "prepare: matrix_server_name: $name appended to $lab_yaml."
    fi
    if [ -z "$l_cur" ]; then
      {
        [ ! -s "$local_yaml" ] || [ -z "$(tail -c 1 "$local_yaml")" ] || echo
        printf '%s\n' "# Matrix server_name of the imported homeserver (written by scripts/matrix-import.sh prepare)"
        printf '%s\n' "matrix_server_name: $name"
      } >>"$local_yaml"
      info "prepare: matrix_server_name: $name written to $local_yaml."
    fi
  fi
  echo
  echo "Next, in this order (nothing of this touches the old VPS):"
  echo "  bash scripts/lab.sh init        # encrypts the signing key into secrets/matrix/matrix-signing-key.sops.yaml"
  echo "  bash scripts/lab.sh customize   # writes serverName into gitops/charts/matrix/values.yaml"
  echo "  git add -A secrets gitops infra/envs/local/lab.yaml && git commit -m 'Matrix: server_name and signing key of the imported homeserver' && git push"
  echo "  (wait until Argo CD synced: kubectl -n argocd get applications)"
  echo "  bash scripts/lab.sh matrix-import $DUMP --dry-run"
}

do_accept() {
  local state_rc=0
  python3 "$HERE/import-state.py" restore matrix --namespace "$NS" --deployment "$DEPLOY" "${KCTX[@]}" || state_rc=$?
  case "$state_rc" in
    0 | 3) ;;
    *) die "could not restore import evidence; refusing acceptance." ;;
  esac
  [ -n "$(state_get manifest)" ] || die "no saved import baseline (ConfigMap $STATE_CM, backed-up volume and control machine). Legacy backup: follow the manual checks in docs/how-to/rebuild.md; do not re-import just for acceptance."
  SERVER_NAME=$(state_get server_name)
  start_db_pod
  local strict=0
  [ "$(live_fingerprint)" = "$(state_get fingerprint)" ] && strict=1
  [ "$strict" = 1 ] || info "the lab content differs from the last import (the lab was used since): relaxed counts."
  python3 "$HERE/import-state.py" verify matrix --namespace "$NS" --deployment "$DEPLOY" "${KCTX[@]}" || die "pre-destroy count verification failed."
  acceptance "$strict"
}

do_backup() {
  python3 "$HERE/import-state.py" save matrix --namespace "$NS" --deployment "$DEPLOY" "${KCTX[@]}" || die "could not persist import evidence."
  local rc=0
  take_snapshot manual || rc=$?
  [ "$rc" = 0 ] || die "the snapshot failed (code $rc; kubectl -n $NS get backup.k8up.io,backup.postgresql.cnpg.io)."
  info "backup done: the state of now is in the K8up and the CNPG archive (rebuild --restore brings it back)."
}

do_import() {
  local prev_hash prev_status prev_fp counts lu lr lm fp foreign=0 label="" mf
  prev_hash=$(state_get dump_hash)
  prev_status=$(state_get status)
  [ -f "$DUMP" ] || die "dump file not found: $DUMP"
  DUMP_SHA_EARLY=$(sha256sum "$DUMP" | awk '{ print $1 }')
  start_db_pod

  if [ "$REIMPORT" = 0 ] && [ "$DRY_RUN" = 0 ] && [ -n "$prev_hash" ] && [ "$prev_hash" = "$DUMP_SHA_EARLY" ] && [ "$prev_status" = ok ]; then
    info "SKIP: this dump (sha256 ${DUMP_SHA_EARLY:0:12}...) is already imported ($(state_get imported_at)). Use --reimport to run it again."
    do_accept
    return $?
  fi

  open_dump
  report_dump
  check_dump_versions
  check_identity
  report_config
  start_files_pod
  check_free_space
  prev_fp=$(state_get fingerprint)
  counts=$(live_counts)
  lu=${counts%% *}
  lm=${counts##* }
  lr=${counts#* }
  lr=${lr%% *}
  fp=$(live_fingerprint)
  if [ "$lu" = 0 ] && [ "$lr" = 0 ] && [ "$lm" = 0 ]; then
    info "lab Matrix is empty (only the lab admin '$LABADMIN'): plain import."
  elif [ -n "$prev_fp" ] && [ "$fp" = "$prev_fp" ]; then
    info "lab Matrix holds exactly the result of an earlier import run (state '${prev_status:-?}', $lu accounts, $lr rooms): it is replaced by this dump, no question."
  else
    foreign=1
    info "lab Matrix holds content that is not the result of an import ($lu accounts besides the lab admin, $lr rooms, $lm media files)."
    [ "$REPLACE" = 1 ] || abort "refusing to overwrite it. Run again with --replace (destructive, asks [y/N], takes a K8up and a CNPG snapshot first), or empty the lab Matrix yourself."
  fi
  check_swap_rights

  if [ "$DRY_RUN" = 1 ]; then
    load_dump rollback
    report_manifest
    info "--dry-run: the dump loads and passes every check (schema version $LOADED_SCHEMA); the transaction was rolled back. Would $([ "$foreign" = 1 ] && echo 'REPLACE foreign content after [y/N] and a snapshot' || echo import) now. Nothing was changed."
    return 0
  fi

  if [ "$foreign" = 1 ] && [ "$YES" != 1 ]; then
    ask_yn "This DELETES all $lu accounts, $lr rooms and $lm media files now in the lab Matrix and imports the dump instead. Continue?" || abort "not confirmed (answer y, or use --yes). Nothing was changed."
  fi
  if [ "$foreign" = 1 ]; then snapshot_or_abort pre; fi

  PHASE=pre-swap
  argo_pause
  synapse_scale_down
  load_dump commit
  PHASE=post-swap
  # from here on the lab content is ours (its fingerprint is recorded): an interrupted run is resumed without a question
  state_set status running dump_hash "$DUMP_SHA" started_at "$(date -u +%FT%TZ)" fingerprint "$(live_fingerprint)" >/dev/null
  report_manifest
  sqlq -c 'ANALYZE' >/dev/null 2>&1 || true
  restore_files
  synapse_scale_up
  PHASE=idle
  argo_restore
  wait_lab_admin

  fp=$(live_fingerprint)
  mf=$(cat "$SCRATCH/manifest.txt")
  state_set restore_counts - status ok dump_hash "$DUMP_SHA" fingerprint "$fp" imported_at "$(date -u +%FT%TZ)" \
    manifest "$mf" server_name "$SERVER_NAME" signing_sha "$SIGNING_SHA" \
    verify_key_id "$(json_get verify_key.id <"$SCRATCH/meta.json")" verify_key "$(json_get verify_key.key <"$SCRATCH/meta.json")" \
    source_host "$(json_get source_host <"$SCRATCH/meta.json")" source_created "$(json_get created_utc <"$SCRATCH/meta.json")" \
    synapse_dump_version "$SRC_VERSION" snapshot_post - >/dev/null
  python3 "$HERE/import-state.py" save matrix --namespace "$NS" --deployment "$DEPLOY" "${KCTX[@]}" || die "could not persist import evidence."
  if [ "$NO_BACKUP" = 1 ]; then
    warn "--no-backup: no backup after the import. Until one runs, a rebuild --restore brings back the state BEFORE the import: bash scripts/lab.sh matrix-import backup"
  else
    label=post
    take_snapshot "$label" || die "the import is done, but the backup after it failed. Run 'bash scripts/lab.sh matrix-import backup' (a rebuild --restore would otherwise bring back the old state)."
  fi
  if acceptance 1; then
    info "IMPORT OK: $(mval "$SCRATCH/manifest.txt" users) accounts, $(mval "$SCRATCH/manifest.txt" rooms) rooms, $(mval "$SCRATCH/manifest.txt" events) events from dump ${DUMP_SHA:0:12}... (server_name $SERVER_NAME)"
  else
    die "the import ran, but the acceptance checks failed (see FAIL lines)."
  fi
}

report_manifest() {
  info "dump content as loaded: $(mval "$SCRATCH/manifest.txt" users) accounts, $(mval "$SCRATCH/manifest.txt" rooms) rooms, $(mval "$SCRATCH/manifest.txt" events) events, $(mval "$SCRATCH/manifest.txt" local_media) media records, $(mval "$SCRATCH/manifest.txt" devices) devices, $(mval "$SCRATCH/manifest.txt" e2e_device_keys) device key sets, $(mval "$SCRATCH/manifest.txt" e2e_room_keys) backed-up room keys"
}

main() {
  parse_args "$@"
  case $MODE in
    recipients) do_recipients; return 0 ;;
  esac
  make_scratch
  trap on_exit EXIT
  case $MODE in
    prepare) do_prepare; return 0 ;;
  esac
  NEED_CLUSTER=1
  preflight
  case $MODE in
    recover) do_recover ;;
    accept) do_accept ;;
    backup) do_backup ;;
    import) do_import ;;
  esac
}

main "$@"
