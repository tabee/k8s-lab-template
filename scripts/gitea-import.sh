#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
# gitea-import.sh: restore a `gitea dump` of another forge (the production Gitea on the VPS) into the lab Gitea.
# Meant to be re-run and reused: the same procedure restores a dump into the cluster Gitea after a rebuild and
# is the rehearsal for a later move of the production forge. Call it as `bash scripts/lab.sh gitea-import ...` (lab.sh
# loads lab.yaml and the KUBECONFIG first); it also runs on its own with KUBECONFIG set.
#
#   bash scripts/lab.sh gitea-import DUMPFILE        import (SKIP / ABORT / import, see below)
#   bash scripts/lab.sh gitea-import recipients      print the age recipients of .sops.yaml (the public keys the
#                                                    VPS script encrypts for) and the exact command for the VPS
#   bash scripts/lab.sh gitea-import accept          run only the acceptance checks against the last import
#   bash scripts/lab.sh gitea-import recover         undo what an interrupted run left: Gitea scaled up again, Argo CD
#                                                    auto-sync restored, helper pods deleted
#
# DUMPFILE is the encrypted file made by scripts/gitea-import-vps-dump.sh (age stream or sops JSON). Its sha256
# is the identity of the import. What is imported: users, organisations, teams, repositories (git data, wiki,
# LFS objects, attachments, avatars) with their issues, pull requests, releases and the access between them.
# NOT imported: webhooks, template repositories (is_template), mirrors, tokens, sessions, 2FA/WebAuthn, SSH/GPG/
# deploy keys, secrets, OAuth2 apps, Actions, packages (see docs/how-to/gitea-import.md). Password hashes are kept.
#
# Decision per run (state in the ConfigMap gitea-import-state, namespace gitea):
#   same dump (same sha256) already imported  -> SKIP (acceptance only), --reimport forces a new run
#   lab Gitea empty (only the lab admin)       -> import
#   lab Gitea holds the result of an earlier import (fingerprint unchanged) -> import (replaces it)
#   lab Gitea holds anything else               -> ABORT; --replace replaces it after [y/N] (destructive) and
#                                                  after a K8up file snapshot and a CNPG database backup
#
# Options: --replace, --yes (answer the [y/N] of --replace), --dry-run (load and check the dump in a scratch
#   schema, print what would happen, change nothing), --reimport, --no-backup (skip the snapshot; explicit),
#   --base-url URL (default https://git.lab.example), --cacert FILE (default ~/.config/k8s-lab/lab-ca.crt),
#   --resolve HOST:PORT:IP (for curl and git, when the name does not resolve), --age-key FILE (default
#   $SOPS_AGE_KEY_FILE or ~/.config/sops/age/keys.txt), --namespace NS (default gitea), --context CTX.
# Environment (tests and other clusters): GITEA_IMPORT_DB_HOST (default gitea-db-rw, the direct service, not the
#   pooler), GITEA_IMPORT_PSQL_IMAGE (default: image of the CNPG cluster gitea-db), GITEA_IMPORT_DEPLOY (gitea),
#   GITEA_IMPORT_ARGO_NS (argocd), GITEA_IMPORT_ARGO_APPS (root gitea; root FIRST), GITEA_IMPORT_VERIFY_LOGIN
#   (USER:PASSWORD of a dump user whose old password must still work; test only), GITEA_IMPORT_SCRATCH (directory
#   for the plaintext; default: a tmpfs under $XDG_RUNTIME_DIR or /dev/shm).
# The plaintext of the dump only ever lives in a tmpfs directory that is shredded on exit. No secret value is
# printed or put on a command line. Exit codes: 0 ok / SKIP, 1 error or ABORT, 2 usage.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TOOLDIR="$HERE/gitea-import"
# shellcheck source=scripts/gitea-sso.sh
source "$HERE/gitea-sso.sh"

NS=${GITEA_IMPORT_NS:-gitea}
KCTX=()
DEPLOY=${GITEA_IMPORT_DEPLOY:-gitea}
DB_HOST=${GITEA_IMPORT_DB_HOST:-gitea-db-rw}
DB_SECRET=${GITEA_IMPORT_DB_SECRET:-gitea-db-owner}
ADMIN_SECRET=${GITEA_IMPORT_ADMIN_SECRET:-gitea-admin}
ARGO_NS=${GITEA_IMPORT_ARGO_NS:-argocd}
ARGO_APPS=${GITEA_IMPORT_ARGO_APPS:-root gitea}
STATE_CM=gitea-import-state
DB_POD=gitea-import-db
FILES_POD=gitea-import-files
STAGE=gi_stage
BASE_URL=https://git.lab.example
CACERT=""
RESOLVE=""
AGE_KEY=""
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
info() { echo "gitea-import: $*"; }
warn() { echo "gitea-import: WARNING: $*" >&2; }
die() { echo "gitea-import: ERROR: $*" >&2; exit 1; }
abort() { echo "gitea-import: ABORT: $*" >&2; exit 1; }
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
      --base-url) [ $# -ge 2 ] || usage; BASE_URL=${2%/}; shift 2 ;;
      --cacert) [ $# -ge 2 ] || usage; CACERT=$2; shift 2 ;;
      --resolve) [ $# -ge 2 ] || usage; RESOLVE=$2; shift 2 ;;
      --age-key) [ $# -ge 2 ] || usage; AGE_KEY=$2; shift 2 ;;
      --namespace) [ $# -ge 2 ] || usage; NS=$2; shift 2 ;;
      --context) [ $# -ge 2 ] || usage; KCTX=(--context "$2"); shift 2 ;;
      -h | --help | help) usage ;;
      -*) echo "gitea-import: unknown option: $1" >&2; usage ;;
      *)
        if [ "$sub" = 0 ] && [ -z "$DUMP" ]; then
          case "$1" in
            recipients | accept | recover) MODE=$1; sub=1; shift; continue ;;
          esac
        fi
        [ -z "$DUMP" ] || { echo "gitea-import: more than one dump file given" >&2; usage; }
        DUMP=$1; shift ;;
    esac
  done
  case $MODE in
    import) [ -n "$DUMP" ] || { echo "gitea-import: no dump file given" >&2; usage; } ;;
    *) [ -z "$DUMP" ] || { echo "gitea-import: '$MODE' takes no dump file" >&2; usage; } ;;
  esac
  if [ "$MODE" != import ] && { [ "$REPLACE" = 1 ] || [ "$DRY_RUN" = 1 ] || [ "$REIMPORT" = 1 ] || [ "$NO_BACKUP" = 1 ]; }; then
    echo "gitea-import: --replace, --dry-run, --reimport and --no-backup only apply to an import" >&2; usage
  fi
  if [ "$YES" = 1 ] && [ "$REPLACE" != 1 ]; then
    echo "gitea-import: --yes only answers the question of --replace" >&2; usage
  fi
  if [ -z "$CACERT" ] && [ -f "$HOME/.config/k8s-lab/lab-ca.crt" ]; then
    CACERT="$HOME/.config/k8s-lab/lab-ca.crt"
  fi
  return 0
}

# ---------------------------------------------------------------- scratch space (plaintext lives only here)
cleanup_scratch() {
  [ -n "$SCRATCH" ] && [ -d "$SCRATCH" ] || return 0
  find "$SCRATCH" -type f -exec shred -u {} + 2>/dev/null || true
  rm -rf "$SCRATCH"
}

make_scratch() {
  local need_kb=$1 base avail
  if [ -n "${GITEA_IMPORT_SCRATCH:-}" ]; then
    [ -d "$GITEA_IMPORT_SCRATCH" ] || die "GITEA_IMPORT_SCRATCH is not a directory."
    SCRATCH=$(mktemp -d "$GITEA_IMPORT_SCRATCH/gitea-import.XXXXXX")
    return 0
  fi
  for base in "${XDG_RUNTIME_DIR:-}" /dev/shm; do
    [ -n "$base" ] && [ -d "$base" ] && [ -w "$base" ] || continue
    avail=$(df -Pk "$base" | awk 'NR == 2 { print $4 }')
    if [ "${avail:-0}" -ge "$need_kb" ]; then
      SCRATCH=$(mktemp -d "$base/gitea-import.XXXXXX")
      return 0
    fi
  done
  warn "no tmpfs with $((need_kb / 1024)) MiB free: the decrypted dump goes to a normal temp directory and is shredded on exit."
  SCRATCH=$(mktemp -d)
}

# ---------------------------------------------------------------- generic helpers
need_tool() { command -v "$1" >/dev/null 2>&1 || die "$1 is not installed (needed: $2)."; }

# Compare dotted versions: version_ge A B is true when A >= B.
version_ge() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1)" = "$2" ]; }

# Reduce "1.27.3-rootless@sha256:..." or "gitea version 1.27.3 built with ..." to 1.27.3.
version_of() { printf '%s\n' "$1" | sed -n 's/^[^0-9]*\([0-9][0-9]*\.[0-9][0-9]*\(\.[0-9][0-9]*\)\{0,1\}\).*/\1/p' | head -n 1; }

json_get() { python3 -c 'import json,sys
d=json.load(sys.stdin)
v=d.get(sys.argv[1], "")
print(v if v is not None else "")' "$1"; }

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

# psql in the helper pod; arguments are psql arguments, stdin is passed through.
sql() { k exec -i "$DB_POD" -c psql -- psql -X -q -v ON_ERROR_STOP=1 "$@"; }
sqlq() { sql -At "$@"; }                   # query, bare output
sqls() { sqlq -v "stage=$STAGE" -v "labadmin=$LABADMIN" "$@"; }

# ---------------------------------------------------------------- preflight
preflight() {
  need_tool kubectl "talk to the cluster"
  need_tool python3 "read the dump and build JSON"
  need_tool curl "acceptance over HTTPS"
  need_tool git "acceptance (ls-remote, clone, fsck)"
  need_tool sha256sum "dump identity"
  kg get ns "$NS" >/dev/null 2>&1 || die "namespace $NS not reachable (KUBECONFIG? cluster up?)."
  k get deploy "$DEPLOY" >/dev/null 2>&1 || die "deployment $DEPLOY not found in namespace $NS."
  k get secret "$DB_SECRET" >/dev/null 2>&1 || die "secret $DB_SECRET not found in namespace $NS."
  k get secret "$ADMIN_SECRET" >/dev/null 2>&1 || die "secret $ADMIN_SECRET not found in namespace $NS."
  LABADMIN=$(k get secret "$ADMIN_SECRET" -o go-template='{{index .data "username"}}' | base64 -d)
  [ -n "$LABADMIN" ] || die "secret $ADMIN_SECRET has no username."
}

lab_image() { k get deploy "$DEPLOY" -o jsonpath='{.spec.template.spec.containers[0].image}'; }
lab_version() {
  local v img
  img=$(lab_image)
  img=${img%%@*}
  v=$(version_of "${img##*:}")
  [ -n "$v" ] || die "cannot read the lab Gitea version from the image tag of deployment $DEPLOY."
  printf '%s\n' "$v"
}

# ---------------------------------------------------------------- helper pods
delete_pods() {
  k delete pod "$DB_POD" "$FILES_POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}

start_db_pod() {
  local img cfg name ssl
  img=${GITEA_IMPORT_PSQL_IMAGE:-$(k get cluster.postgresql.cnpg.io gitea-db -o jsonpath='{.spec.imageName}' 2>/dev/null || true)}
  [ -n "$img" ] || die "no psql image: the CNPG cluster gitea-db has no spec.imageName; set GITEA_IMPORT_PSQL_IMAGE (digest-pinned)."
  name=gitea
  ssl=require
  cfg=$(k get secret gitea-inline-config -o go-template='{{index .data "database"}}' 2>/dev/null | base64 -d 2>/dev/null || true)
  if [ -n "$cfg" ]; then
    name=$(printf '%s\n' "$cfg" | sed -n 's/^NAME=//p' | head -n 1)
    ssl=$(printf '%s\n' "$cfg" | sed -n 's/^SSL_MODE=//p' | head -n 1)
  fi
  : "${name:=gitea}" "${ssl:=require}"
  DB_NAME=${GITEA_IMPORT_DB_NAME:-$name}
  k delete pod "$DB_POD" --ignore-not-found --wait=true >/dev/null 2>&1 || true
  python3 "$TOOLDIR/pods.py" db "$img" "$DB_HOST" 5432 "$DB_NAME" "$ssl" "$DB_SECRET" | k apply -f - >/dev/null
  k wait --for=condition=Ready "pod/$DB_POD" --timeout=180s >/dev/null 2>&1 || die "helper pod $DB_POD did not become ready (image pull? NetworkPolicy?): kubectl -n $NS describe pod $DB_POD"
  sqlq -c 'SELECT 1' >/dev/null 2>&1 || die "helper pod $DB_POD cannot reach the database at $DB_HOST (host, credentials, SSL mode)."
}

start_files_pod() {
  k delete pod "$FILES_POD" --ignore-not-found --wait=true >/dev/null 2>&1 || true
  k get deploy "$DEPLOY" -o json | python3 "$TOOLDIR/pods.py" files "$DB_SECRET" | k apply -f - >/dev/null
  k wait --for=condition=Ready "pod/$FILES_POD" --timeout=180s >/dev/null 2>&1 || die "helper pod $FILES_POD did not become ready: kubectl -n $NS describe pod $FILES_POD"
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

# ---------------------------------------------------------------- Gitea replicas
gitea_scale_down() {
  local cur
  cur=$(k get deploy "$DEPLOY" -o jsonpath='{.spec.replicas}')
  if [ "${cur:-0}" != 0 ]; then state_set scaled_from "$cur"; fi
  k scale deploy "$DEPLOY" --replicas=0 >/dev/null
  for _ in $(seq 1 90); do
    [ -z "$(k get pods -l "app.kubernetes.io/name=$DEPLOY,app.kubernetes.io/instance=$DEPLOY" -o name 2>/dev/null)" ] && return 0
    sleep 2
  done
  die "Gitea pods did not stop within 180 s."
}

gitea_scale_up() {
  local n
  n=$(state_get scaled_from)
  k scale deploy "$DEPLOY" --replicas="${n:-1}" >/dev/null
  k rollout status "deploy/$DEPLOY" --timeout=600s >/dev/null 2>&1 || die "Gitea did not become ready after the import: kubectl -n $NS logs deploy/$DEPLOY"
  state_set scaled_from -
}

# Keycloak SSO. The import replaces the whole Gitea database, and with it the
# login source "keycloak" (table login_source). The configure-oidc init
# container of the Gitea pod installs it again on every start, so the restart
# at the end of the import already does it. This is the safety net: if the
# source is still missing (Keycloak was down for longer than the init
# container waits), restart Gitea once more. Only when the lab uses Keycloak
# (secret gitea-oidc exists).
sso_expected() { k get secret gitea-oidc >/dev/null 2>&1; }
sso_source_present() {
  GITEA_SSO_DEPLOY=$DEPLOY sso_source_present_with k
}
ensure_sso_source() {
  sso_expected || return 0
  if sso_source_present; then
    info "SSO: login source keycloak is present again (configure-oidc ran on the restart)."
    return 0
  fi
  info "SSO: login source keycloak is missing after the import; restarting Gitea so that configure-oidc installs it (waits up to 180 s for Keycloak) ..."
  k rollout restart "deploy/$DEPLOY" >/dev/null
  k rollout status "deploy/$DEPLOY" --timeout=600s >/dev/null 2>&1 || die "Gitea did not become ready after the restart: kubectl -n $NS logs deploy/$DEPLOY"
  if sso_source_present; then
    info "SSO: login source keycloak installed."
  else
    warn "SSO: login source keycloak is still missing. Is Keycloak up? Then: kubectl -n $NS rollout restart deploy/$DEPLOY (details: docs/how-to/gitea-import.md, section Keycloak)."
  fi
}

# ---------------------------------------------------------------- the dump: decrypt, inspect
inspect_val() { sed -n "s/^$1=//p" "$SCRATCH/inspect.txt" | head -n 1 | tr -cd 'a-z0-9_'; }

# Sets PLAIN (decrypted tar in $SCRATCH), DUMP_SHA, SRC_VERSION, SRC_DB.
open_dump() {
  local head1 key
  [ -f "$DUMP" ] || die "dump file not found: $DUMP"
  DUMP_SHA=$(sha256sum "$DUMP" | awk '{ print $1 }')
  key=${AGE_KEY:-${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}}
  [ -r "$key" ] || die "age key file not readable: $key (--age-key FILE or SOPS_AGE_KEY_FILE)."
  PLAIN="$SCRATCH/dump.tar"
  head1=$(head -c 1 "$DUMP")
  if [ "$head1" = "{" ]; then
    need_tool sops "open a sops-format dump"
    info "dump format: sops (JSON, binary mode)"
    SOPS_AGE_KEY_FILE=$key sops -d --input-type json --output-type binary "$DUMP" >"$PLAIN" || die "sops could not decrypt the dump (wrong key?)."
  else
    need_tool age "open an age-format dump"
    info "dump format: age"
    age -d -i "$key" -o "$PLAIN" "$DUMP" || die "age could not decrypt the dump (wrong key?)."
  fi
  python3 "$TOOLDIR/dump-tool.py" meta "$PLAIN" >"$SCRATCH/meta.json" || die "the dump has no gitea-import-meta.json: use scripts/gitea-import-vps-dump.sh on the VPS."
  SRC_VERSION=$(json_get gitea_version <"$SCRATCH/meta.json")
  SRC_DB=$(json_get db_type <"$SCRATCH/meta.json")
  SRC_VERSION=$(version_of "$SRC_VERSION")
  [ -n "$SRC_VERSION" ] || die "the dump meta has no readable Gitea version."
  python3 "$TOOLDIR/dump-tool.py" inspect "$PLAIN" >"$SCRATCH/inspect.txt" || die "the dump is not a readable tar archive."
  INS_has_sql=$(inspect_val has_sql)
  INS_sql_dialect=$(inspect_val sql_dialect)
  INS_has_lfs=$(inspect_val has_lfs)
  INS_repos_dirs=$(inspect_val repos_dirs)
  [ "$INS_has_sql" = 1 ] || die "the dump has no gitea-db.sql."
  info "dump: sha256 ${DUMP_SHA:0:12}..., Gitea $SRC_VERSION, source database ${SRC_DB:-unknown}, ${INS_repos_dirs:-0} repository directories"
}

check_dump_versions() {
  local lab
  lab=$(lab_version)
  info "lab Gitea $lab, dump from Gitea $SRC_VERSION"
  version_ge "$lab" "$SRC_VERSION" || abort "the lab Gitea ($lab) is older than the Gitea of the dump ($SRC_VERSION). A newer dump cannot be loaded into an older Gitea: raise the image in gitops/workloads/gitea/values-gitea.yaml first."
  case "$INS_sql_dialect" in
    postgres) ;;
    *) abort "the SQL of the dump is written for '$INS_sql_dialect', not for postgres. Make the dump with scripts/gitea-import-vps-dump.sh (it passes --database postgres; sqlite3, mysql and postgres sources all work)." ;;
  esac
  case "${SRC_DB:-unknown}" in
    postgres | postgresql | sqlite3 | mysql | mssql | unknown) ;;
    *) warn "unknown source database type '$SRC_DB'; the SQL is postgres syntax, so loading is tried anyway." ;;
  esac
}

# ---------------------------------------------------------------- the lab database
live_has_table() { [ "$(sqlq -c "SELECT to_regclass('public.\"$1\"') IS NOT NULL")" = t ]; }

# Prints "USERS REPOS" of the live database without the lab admin and the ghost user.
live_counts() {
  if ! live_has_table user; then echo "0 0"; return 0; fi
  local u r
  u=$(sqls <<'SQL'
SELECT count(*) FROM "user" WHERE id > 0 AND lower_name <> lower(:'labadmin');
SQL
)
  r=0
  if live_has_table repository; then r=$(sqlq -c 'SELECT count(*) FROM repository'); fi
  echo "$u $r"
}

live_fingerprint() {
  if ! live_has_table user || ! live_has_table repository || ! live_has_table issue \
    || ! live_has_table comment || ! live_has_table pull_request || ! live_has_table release; then
    echo "none"; return 0
  fi
  sqls <"$TOOLDIR/fingerprint.sql"
}

# Load the dump SQL into the scratch schema, filter it, write $SCRATCH/manifest.txt.
stage_dump() {
  info "loading the dump SQL into the scratch schema $STAGE (the live tables are not touched) ..."
  sqlq -c "DROP SCHEMA IF EXISTS $STAGE CASCADE; CREATE SCHEMA $STAGE" >/dev/null
  {
    printf 'SET client_min_messages TO warning;\nSET search_path TO %s;\n' "$STAGE"
    python3 "$TOOLDIR/dump-tool.py" sql "$PLAIN" | sed -e "s/^\\(CREATE TABLE IF NOT EXISTS \\)\"public\"\\./\\1\"$STAGE\"./"
  } | sql -1 >/dev/null || { sqlq -c "DROP SCHEMA IF EXISTS $STAGE CASCADE" >/dev/null 2>&1 || true; die "the dump SQL could not be loaded (see the psql error above); nothing was changed."; }
  local n
  n=$(sqlq -c "SELECT count(*) FROM information_schema.tables WHERE table_schema = '$STAGE' AND table_name IN ('user','repository','version','team','access')")
  [ "$n" = 5 ] || die "the dump SQL did not create the expected Gitea tables in $STAGE (found $n of 5)."
  # manifest before the filter: external-login users (they lose their login source below)
  {
    printf 'SET search_path TO %s;\n' "$STAGE"
    cat "$TOOLDIR/manifest.sql"
  } | sqls | grep '^X ' >"$SCRATCH/manifest.pre" || true
  {
    printf 'SET search_path TO %s;\n' "$STAGE"
    cat "$TOOLDIR/filter.sql"
  } | sqls -1 >/dev/null || die "filter.sql failed on the staged dump."
  {
    printf 'SET search_path TO %s;\n' "$STAGE"
    cat "$TOOLDIR/manifest.sql"
  } | sqls | grep -v '^X ' >"$SCRATCH/manifest.txt"
  cat "$SCRATCH/manifest.pre" >>"$SCRATCH/manifest.txt"
}

# ---------------------------------------------------------------- snapshot before replacing existing content
wait_condition() { # wait_condition KIND NAME JSONPATH GOODVALUE BADVALUE SECONDS
  local v
  for _ in $(seq 1 "$6"); do
    v=$(k get "$1" "$2" -o jsonpath="$3" 2>/dev/null || true)
    [ "$v" = "$4" ] && return 0
    [ -n "$5" ] && [ "$v" = "$5" ] && return 1
    sleep 5
  done
  return 1
}

# A K8up Backup (files) and a CNPG Backup (database) of the CURRENT state, both awaited. Aborts when no
# snapshot can be made, unless --no-backup was given.
take_snapshot() {
  local stamp name have_k8up=0 have_cnpg=0
  if [ "$NO_BACKUP" = 1 ]; then warn "--no-backup: no snapshot is taken before the content is replaced."; return 0; fi
  stamp=$(date +%Y%m%d-%H%M%S)
  kg get crd backups.k8up.io >/dev/null 2>&1 && k get schedule.k8up.io gitea-files >/dev/null 2>&1 && have_k8up=1
  kg get crd backups.postgresql.cnpg.io >/dev/null 2>&1 && k get cluster.postgresql.cnpg.io gitea-db >/dev/null 2>&1 && have_cnpg=1
  if [ "$have_k8up" = 0 ] || [ "$have_cnpg" = 0 ]; then
    abort "no snapshot possible (K8up Schedule gitea-files: $([ $have_k8up = 1 ] && echo found || echo missing); CNPG cluster gitea-db: $([ $have_cnpg = 1 ] && echo found || echo missing)). Replacing existing content without a snapshot needs --no-backup."
  fi
  name="gitea-import-$stamp"
  info "snapshot: K8up backup of the Gitea files ($name) ..."
  k get schedule.k8up.io gitea-files -o json | python3 -c '
import json, sys
s = json.load(sys.stdin)["spec"]
b = {"apiVersion": "k8up.io/v1", "kind": "Backup", "metadata": {"name": sys.argv[1]},
     "spec": {"backend": s["backend"], "failedJobsHistoryLimit": 1, "successfulJobsHistoryLimit": 1}}
if "podConfigRef" in s:
    b["spec"]["podConfigRef"] = s["podConfigRef"]
json.dump(b, sys.stdout)' "$name" | k apply -f - >/dev/null
  wait_condition backup.k8up.io "$name" '{.status.conditions[?(@.type=="Completed")].reason}' Succeeded Failed 360 \
    || abort "the K8up backup $name did not complete successfully (kubectl -n $NS describe backup.k8up.io $name). Nothing was changed."
  info "snapshot: CNPG backup of gitea-db ($name) ..."
  python3 -c '
import json, sys
json.dump({"apiVersion": "postgresql.cnpg.io/v1", "kind": "Backup", "metadata": {"name": sys.argv[1]},
           "spec": {"cluster": {"name": "gitea-db"}, "method": "plugin",
                    "pluginConfiguration": {"name": "barman-cloud.cloudnative-pg.io"}}}, sys.stdout)' "$name" | k apply -f - >/dev/null
  wait_condition backup.postgresql.cnpg.io "$name" '{.status.phase}' completed failed 360 \
    || abort "the CNPG backup $name did not complete (kubectl -n $NS describe backup.postgresql.cnpg.io $name). Nothing was changed."
  python3 "$HERE/lab-wal-ready.py" --cluster "$NS/gitea-db" \
    || abort "the CNPG backup $name completed, but its end WAL is not archived yet. Nothing else was changed."
  state_set snapshot "$name"
  info "snapshot done ($name). Restore: docs/how-to/restore-gitea.md"
}

# ---------------------------------------------------------------- the swap
db_swap() {
  info "database: replacing the schema (one transaction) ..."
  sqlq <<SQL >/dev/null
BEGIN;
DROP SCHEMA public CASCADE;
ALTER SCHEMA $STAGE RENAME TO public;
GRANT USAGE ON SCHEMA public TO PUBLIC;
COMMIT;
SQL
  [ "$(sqlq -c "SELECT count(*) FROM pg_namespace WHERE nspname = '$STAGE'")" = 0 ] || die "schema swap did not run."
}

check_swap_rights() {
  local ok
  ok=$(sqlq -c "SELECT (nspowner = 'pg_database_owner'::regrole OR pg_has_role(current_user, nspowner, 'USAGE')) FROM pg_namespace WHERE nspname = 'public'")
  [ "$ok" = t ] || abort "the database user cannot drop and recreate the schema public (owner is not the database owner). Nothing was changed."
}

# ini_paths: print "KEY=PATH" for repos, lfs, attachments, avatars, repo-avatars from the lab app.ini (only these keys
# are read in the pod, nothing else of app.ini leaves it).
ini_paths() {
  local ini
  ini=$(fx sh -c 'grep -E "^(\[|ROOT *=|PATH *=|APP_DATA_PATH *=|AVATAR_UPLOAD_PATH *=|REPOSITORY_AVATAR_UPLOAD_PATH *=)" "${GITEA_APP_INI:-/data/gitea/conf/app.ini}"' || true)
  printf '%s\n' "$ini" | awk -F' *= *' '
    /^\[/ { sec = $0; next }
    sec == "[server]" && $1 == "APP_DATA_PATH" { d = $2 }
    sec == "[repository]" && $1 == "ROOT" { r = $2 }
    sec == "[lfs]" && $1 == "PATH" { l = $2 }
    sec == "[attachment]" && $1 == "PATH" { a = $2 }
    sec == "[picture]" && $1 == "AVATAR_UPLOAD_PATH" { v = $2 }
    sec == "[picture]" && $1 == "REPOSITORY_AVATAR_UPLOAD_PATH" { p = $2 }
    END {
      print "repos=" (r != "" ? r : "/data/git/gitea-repositories")
      if (d == "") d = "/data/gitea"
      print "lfs=" (l != "" ? l : d "/lfs")
      print "attachments=" (a != "" ? a : d "/attachments")
      print "avatars=" (v != "" ? v : d "/avatars")
      print "repo-avatars=" (p != "" ? p : d "/repo-avatars")
    }'
}

restore_files() {
  local stage=/data/.gitea-import-stage line key dst
  local -a targets
  start_files_pod
  info "files: unpacking repositories, LFS objects, attachments and avatars into the PVC ..."
  fx sh -c "rm -rf $stage && mkdir -p $stage"
  python3 "$TOOLDIR/dump-tool.py" select "$PLAIN" | fx tar -xf - -C "$stage" || die "unpacking into the PVC failed."
  mapfile -t targets < <(ini_paths)
  for line in "${targets[@]}"; do
    key=${line%%=*}
    dst=${line#*=}
    case $dst in /data/?*) ;; *) die "refusing the unexpected target path '$dst' for $key (must be below /data/)." ;; esac
    case $dst in */..* | *../*) die "refusing the target path '$dst' for $key." ;; esac
    fx sh -c 'set -e; src="$1/$2"; dst="$3"; rm -rf "$dst"; mkdir -p "$(dirname "$dst")"; if [ -d "$src" ]; then mv "$src" "$dst"; else mkdir -p "$dst"; fi' _ "$stage" "$key" "$dst" </dev/null
  done
  fx rm -rf "$stage"
}

post_restore_gitea() {
  info "Gitea: database migrations to the lab version (gitea migrate) ..."
  fx gitea migrate >/dev/null 2>&1 || { fx gitea migrate 2>&1 | tail -n 15 >&2 || true; die "gitea migrate failed."; }
  info "Gitea: regenerating the git hooks of every repository ..."
  fx gitea admin regenerate hooks >/dev/null 2>&1 || { fx gitea admin regenerate hooks 2>&1 | tail -n 15 >&2 || true; die "gitea admin regenerate hooks failed."; }
  info "Gitea: gitea doctor check --all --fix ..."
  if ! fx gitea doctor check --all --fix >"$SCRATCH/doctor.txt" 2>&1; then
    warn "gitea doctor reported problems (last lines):"
    tail -n 15 "$SCRATCH/doctor.txt" >&2 || true
  else
    grep -ci 'fixed\|warn' "$SCRATCH/doctor.txt" | sed 's/^/gitea-import: doctor lines with fixed|warn: /' || true
  fi
  # the filter removed the webhook rows already; make sure nothing came back
  sqlq -c "DELETE FROM hook_task; DELETE FROM webhook" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------- HTTPS access (acceptance, template removal)
ADM_U=""
ADM_P=""
CURL_OPTS=()

load_admin() {
  [ -z "$ADM_U" ] || return 0
  ADM_U=$LABADMIN
  ADM_P=$(k get secret "$ADMIN_SECRET" -o go-template='{{index .data "password"}}' | base64 -d)
  CURL_OPTS=(--silent --show-error --connect-timeout 10 --max-time 120)
  [ -z "$CACERT" ] || CURL_OPTS+=(--cacert "$CACERT")
  [ -z "$RESOLVE" ] || CURL_OPTS+=(--resolve "$RESOLVE")
  return 0
}

# curl_auth USER PASSWORD ARGS...: credentials go through a config on stdin, never through argv.
curl_auth() {
  local u=$1 p=$2
  shift 2
  p=${p//\\/\\\\}
  p=${p//\"/\\\"}
  printf 'user = "%s:%s"\n' "$u" "$p" | curl "${CURL_OPTS[@]}" -K - "$@"
}

# api METHOD PATH: prints the HTTP status only.
api_status() {
  load_admin
  curl_auth "$ADM_U" "$ADM_P" -o /dev/null -w '%{http_code}' -X "$1" "$BASE_URL/api/v1$2" || echo 000
}

# git_with_admin ARGS...: git over HTTPS with the lab admin, secrets only in the environment of a subshell.
git_with_admin() {
  load_admin
  (
    n=1
    export GIT_TERMINAL_PROMPT=0
    export GIT_CONFIG_KEY_0=http.extraHeader
    GIT_CONFIG_VALUE_0="Authorization: Basic $(printf '%s:%s' "$ADM_U" "$ADM_P" | base64 -w0)"
    export GIT_CONFIG_VALUE_0
    if [ -n "$CACERT" ]; then
      export GIT_CONFIG_KEY_1=http.sslCAInfo GIT_CONFIG_VALUE_1=$CACERT
      n=2
    fi
    if [ -n "$RESOLVE" ]; then
      export "GIT_CONFIG_KEY_$n=http.curloptResolve" "GIT_CONFIG_VALUE_$n=$RESOLVE"
      n=$((n + 1))
    fi
    export GIT_CONFIG_COUNT=$n
    git "$@"
  )
}

delete_templates() {
  local t code n=0
  while read -r t; do
    [ -n "$t" ] || continue
    code=$(api_status DELETE "/repos/$t")
    case $code in
      204 | 404) n=$((n + 1)) ;;
      *) die "could not delete the template repository $t over the API (HTTP $code)." ;;
    esac
  done < <(sed -n 's/^T //p' "$MANIFEST")
  info "template repositories removed over the API: $n"
}

# ---------------------------------------------------------------- acceptance
PASS=0
FAILS=0
check() { # check "label" "ok|fail [detail]"
  local st=${2%% *} d=""
  [ "$2" = "$st" ] || d=${2#* }
  if [ "$st" = ok ]; then PASS=$((PASS + 1)); echo "  PASS  $1"; else FAILS=$((FAILS + 1)); echo "  FAIL  $1${d:+ ($d)}"; fi
}

# acceptance STRICT(1|0): counts must be equal when strict; otherwise every dumped name must still exist.
acceptance() {
  local strict=$1 eu eo er u o r t w names
  PASS=0
  FAILS=0
  info "acceptance:"
  eu=$(grep -c '^U ' "$MANIFEST" || true)
  eo=$(grep -c '^O ' "$MANIFEST" || true)
  er=$(grep -c '^R ' "$MANIFEST" || true)
  u=$(sqls <<'SQL'
SELECT count(*) FROM "user" WHERE id > 0 AND type = 0 AND lower_name <> lower(:'labadmin');
SQL
)
  o=$(sqlq -c 'SELECT count(*) FROM "user" WHERE id > 0 AND type = 1')
  r=$(sqlq -c 'SELECT count(*) FROM repository WHERE NOT is_template')
  t=$(sqlq -c 'SELECT count(*) FROM repository WHERE is_template')
  w=$(sqlq -c 'SELECT count(*) FROM webhook')
  if [ "$strict" = 1 ]; then
    check "users: $u in the lab, $eu in the dump manifest (without the lab admin)" "$([ "$u" = "$eu" ] && echo ok || echo fail)"
    check "organisations: $o in the lab, $eo in the dump manifest" "$([ "$o" = "$eo" ] && echo ok || echo fail)"
    check "repositories: $r in the lab, $er in the dump manifest (templates excluded)" "$([ "$r" = "$er" ] && echo ok || echo fail)"
  else
    names=$(sqlq -c 'SELECT lower_name FROM "user" WHERE id > 0' | sort)
    local miss=0 x
    while read -r x; do [ -n "$x" ] && { printf '%s\n' "$names" | grep -qx "$x" || miss=$((miss + 1)); }; done < <(sed -n 's/^[UO] //p' "$MANIFEST")
    check "all $((eu + eo)) dumped users and organisations are still there (lab content changed since the import)" "$([ "$miss" = 0 ] && echo ok || echo "fail $miss missing")"
    check "repositories: $r in the lab, at least $er from the dump" "$([ "$r" -ge "$er" ] && echo ok || echo fail)"
  fi
  check "template repositories: $t (must be 0)" "$([ "$t" = 0 ] && echo ok || echo fail)"
  check "webhooks: $w (must be 0)" "$([ "$w" = 0 ] && echo ok || echo fail)"
  if sso_expected; then
    check "SSO: login source keycloak present (secret gitea-oidc exists; imported accounts link on their first Keycloak login)" "$(sso_source_present && echo ok || echo fail)"
  fi
  acceptance_http "$er"
  info "acceptance: $PASS passed, $FAILS failed"
  [ "$FAILS" = 0 ]
}

acceptance_http() {
  local er=$1 code rc=0 repo bad=0 total=0 sample="" out body
  load_admin
  body=$(curl_auth "$ADM_U" "$ADM_P" -o "$SCRATCH/user.json" -w '%{http_code}' "$BASE_URL/api/v1/user" || echo 000)
  if [ "$body" = 200 ] && python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("is_admin") else 1)' "$SCRATCH/user.json"; then
    check "admin login over the API (credentials from secret $ADMIN_SECRET)" ok
  else
    check "admin login over the API (credentials from secret $ADMIN_SECRET)" fail "HTTP $body at $BASE_URL"
  fi
  rm -f "$SCRATCH/user.json"
  if [ -n "${GITEA_IMPORT_VERIFY_LOGIN:-}" ]; then
    local pair u p
    for pair in $GITEA_IMPORT_VERIFY_LOGIN; do
      u=${pair%%:*}
      p=${pair#*:}
      code=$(curl_auth "$u" "$p" -o /dev/null -w '%{http_code}' "$BASE_URL/api/v1/user" || echo 000)
      check "old password of imported user $u still works" "$([ "$code" = 200 ] && echo ok || echo "fail HTTP $code")"
    done
  fi
  while read -r repo; do
    [ -n "$repo" ] || continue
    total=$((total + 1))
    out=$(git_with_admin ls-remote "$BASE_URL/$repo.git" 2>&1) && rc=0 || rc=$?
    if [ "$rc" != 0 ]; then bad=$((bad + 1)); echo "        ls-remote failed: $repo"; elif [ -z "$sample" ] && [ -n "$out" ]; then sample=$repo; fi
  done < <(sed -n 's/^R //p' "$MANIFEST")
  check "git ls-remote over HTTPS for all $total repositories" "$([ "$bad" = 0 ] && echo ok || echo "fail $bad failed")"
  if [ -z "$sample" ]; then sample=$(sed -n 's/^R //p' "$MANIFEST" | head -n 1); fi
  if [ -n "$sample" ]; then
    if git_with_admin clone --quiet "$BASE_URL/$sample.git" "$SCRATCH/sample" >/dev/null 2>&1 \
      && (cd "$SCRATCH/sample" && git fsck --full >/dev/null 2>&1); then
      check "sample clone + git fsck --full ($sample)" ok
    else
      check "sample clone + git fsck --full ($sample)" fail
    fi
    rm -rf "$SCRATCH/sample"
  elif [ "$er" = 0 ]; then
    check "sample clone (no repositories in the dump)" ok
  fi
}

# ---------------------------------------------------------------- manifest facts and warnings
report_manifest() {
  local nu no nr nt nx
  nu=$(grep -c '^U ' "$MANIFEST" || true)
  no=$(grep -c '^O ' "$MANIFEST" || true)
  nr=$(grep -c '^R ' "$MANIFEST" || true)
  nt=$(grep -c '^T ' "$MANIFEST" || true)
  nx=$(grep -c '^X ' "$MANIFEST" || true)
  info "dump manifest after filtering: $nu users, $no organisations, $nr repositories imported, $nt template repositories dropped, 0 webhooks"
  if [ "$nx" != 0 ]; then
    warn "$nx user(s) log in through an external source (LDAP/OAuth2/SMTP). The source is not imported: they become local users WITHOUT a password and need one set by an admin or the 'forgot password' mail."
  fi
  local line algo
  while read -r line; do
    algo=$(printf '%s\n' "$line" | awk '{ print $2 }')
    case $algo in
      argon2* | bcrypt* | pbkdf2* | scrypt*) ;;
      *) warn "password hash algorithm '${algo:-empty}' (${line##* } user(s)) is not known to be supported: those users need a password reset." ;;
    esac
  done < <(grep '^A ' "$MANIFEST" || true)
  if [ "${INS_has_lfs:-0}" = 1 ]; then
    local lfs
    lfs=$(k get secret gitea-inline-config -o go-template='{{index .data "server"}}' 2>/dev/null | base64 -d 2>/dev/null | sed -n 's/^LFS_START_SERVER=//p' | head -n 1 || true)
    [ "$lfs" = true ] || warn "the dump contains LFS objects but the lab Gitea does not serve LFS (LFS_START_SERVER is not true): clones work, 'git lfs' downloads fail until you enable it in gitops/workloads/gitea/values-gitea.yaml."
  fi
  return 0
}

collision_check() {
  local n
  n=$(sqls <<SQL
SELECT count(*) FROM $STAGE."user" WHERE lower_name = lower(:'labadmin');
SQL
)
  [ "$n" = 0 ] || abort "the dump contains a user with the name of the lab admin ('$LABADMIN', secret $ADMIN_SECRET). The lab admin is created by the chart on every start and would clash. Rename the admin in the lab secret or the user on the VPS, then run again. Nothing was changed."
}

# ---------------------------------------------------------------- main flows
PHASE=idle   # idle | pre-swap (nothing changed yet: undo automatically) | post-swap (leave the state, say what to do)

finish_pre_swap() {
  argo_restore || true
  if [ "$(state_get scaled_from)" != "" ]; then gitea_scale_up || true; fi
}

on_exit() {
  local rc=$?
  trap - EXIT
  if [ "$rc" != 0 ]; then
    case $PHASE in
      pre-swap)
        warn "failed before the swap: undoing (Gitea up, Argo CD restored). The content was not changed."
        finish_pre_swap
        ;;
      post-swap)
        state_set status failed >/dev/null 2>&1 || true
        warn "failed AFTER the database swap: Gitea stays scaled to 0 and Argo CD auto-sync stays paused, because database and files may not match."
        warn "Run the same command again with the same dump (it resumes), or 'bash scripts/lab.sh gitea-import recover' to bring Gitea up as it is."
        ;;
    esac
  fi
  delete_pods
  cleanup_scratch
  exit "$rc"
}

do_recover() {
  info "recover: bringing the lab back to normal operation ..."
  if [ -n "$(state_get scaled_from)" ]; then gitea_scale_up; else info "Gitea was not scaled down by this tool."; fi
  ensure_sso_source || true
  argo_restore
  start_db_pod 2>/dev/null && sqlq -c "DROP SCHEMA IF EXISTS $STAGE CASCADE" >/dev/null 2>&1 || true
  state_set status recovered >/dev/null 2>&1 || true
  info "recover: done. State: $(k get deploy "$DEPLOY" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true) ready replica(s)."
}

do_recipients() {
  local f="$HERE/../.sops.yaml" keys args="" a
  [ -f "$f" ] || die "$f not found."
  # grep finds nothing in a fresh clone (placeholder key); with pipefail that must not end the script silently.
  keys=$(grep -o 'age1[a-z0-9]\{50,\}' "$f" | awk '!seen[$0]++' || true)
  [ -n "$keys" ] || die "no age recipient found in .sops.yaml."
  echo "Public age recipients of .sops.yaml (the dump is encrypted for these; the private key opens it):"
  for a in $keys; do echo "  $a"; args="$args --recipient $a"; done
  echo
  echo "On the PC (over the VPN), with the VPS-side script streamed over SSH, nothing is installed or written on the VPS:"
  echo "  ssh VPS 'bash -s --$args' < scripts/gitea-import-vps-dump.sh > gitea-dump.tar.age"
  echo "Check first (no dump, no recipient needed):  ssh VPS 'bash -s -- --check' < scripts/gitea-import-vps-dump.sh"
  echo "Then:  bash scripts/lab.sh gitea-import gitea-dump.tar.age"
}

do_accept() {
  local state_rc=0
  python3 "$HERE/import-state.py" restore gitea --namespace "$NS" --deployment "$DEPLOY" "${KCTX[@]}" || state_rc=$?
  case "$state_rc" in
    0 | 3) ;;
    *) die "could not restore import evidence; refusing acceptance." ;;
  esac
  local cm
  cm=$(state_get manifest)
  [ -n "$cm" ] || die "no saved import baseline (ConfigMap $STATE_CM, backed-up volume and control machine). Legacy backup: follow the manual checks in docs/how-to/rebuild.md; do not re-import just for acceptance."
  printf '%s\n' "$cm" >"$SCRATCH/manifest.cm"
  MANIFEST="$SCRATCH/manifest.cm"
  start_db_pod
  local strict=0
  [ "$(live_fingerprint)" = "$(state_get fingerprint)" ] && strict=1
  [ "$strict" = 1 ] || info "the lab content differs from the last import (the lab was used since): relaxed counts."
  python3 "$HERE/import-state.py" verify gitea --namespace "$NS" --deployment "$DEPLOY" "${KCTX[@]}" || die "pre-destroy count verification failed."
  acceptance "$strict"
}

do_import() {
  local prev_hash prev_status prev_fp counts lu lr fp strict=1 foreign=0
  prev_hash=$(state_get dump_hash)
  prev_status=$(state_get status)
  [ -f "$DUMP" ] || die "dump file not found: $DUMP"
  DUMP_SHA_EARLY=$(sha256sum "$DUMP" | awk '{ print $1 }')
  start_db_pod

  if [ "$REIMPORT" = 0 ] && [ -n "$prev_hash" ] && [ "$prev_hash" = "$DUMP_SHA_EARLY" ] && [ "$prev_status" = ok ]; then
    info "SKIP: this dump (sha256 ${DUMP_SHA_EARLY:0:12}...) is already imported ($(state_get imported_at)). Use --reimport to run it again."
    do_accept
    return $?
  fi

  open_dump
  check_dump_versions
  prev_fp=$(state_get fingerprint)
  counts=$(live_counts)
  lu=${counts% *}
  lr=${counts#* }
  fp=$(live_fingerprint)
  if [ "$lu" = 0 ] && [ "$lr" = 0 ]; then
    info "lab Gitea is empty (only the lab admin '$LABADMIN'): plain import."
  elif [ "$prev_status" != ok ] && [ -n "$prev_status" ] && [ "$prev_status" != recovered ]; then
    info "an earlier import run was interrupted (state '$prev_status'): resuming, no question."
  elif [ "$prev_status" = ok ] && [ "$fp" = "$prev_fp" ]; then
    info "lab Gitea holds exactly the result of the earlier import ($lu users, $lr repositories): it is replaced by this dump."
  else
    foreign=1
    info "lab Gitea holds content that is not the result of an import ($lu accounts besides the lab admin (users and organisations), $lr repositories)."
    [ "$REPLACE" = 1 ] || abort "refusing to overwrite it. Run again with --replace (destructive, asks [y/N], takes a K8up and a CNPG snapshot first), or empty the lab Gitea yourself."
  fi

  stage_dump
  MANIFEST="$SCRATCH/manifest.txt"
  report_manifest
  collision_check
  check_swap_rights

  if [ "$DRY_RUN" = 1 ]; then
    sqlq -c "DROP SCHEMA IF EXISTS $STAGE CASCADE" >/dev/null
    info "--dry-run: the dump loads and filters cleanly. Would $([ "$foreign" = 1 ] && echo 'REPLACE foreign content after [y/N] and a snapshot' || echo import) now. Nothing was changed."
    return 0
  fi

  if [ "$foreign" = 1 ] && [ "$YES" != 1 ]; then
    ask_yn "This DELETES all $lu users and $lr repositories now in the lab Gitea and imports the dump instead. Continue?" || abort "not confirmed (answer y, or use --yes). Nothing was changed."
  fi

  if [ "$lu" != 0 ] || [ "$lr" != 0 ]; then take_snapshot; fi

  PHASE=pre-swap
  argo_pause
  gitea_scale_down
  # from here on the lab content is ours: an interrupted run is resumed without a question
  state_set status running dump_hash "$DUMP_SHA" started_at "$(date -u +%FT%TZ)" >/dev/null
  db_swap
  PHASE=post-swap
  restore_files
  post_restore_gitea
  gitea_scale_up
  ensure_sso_source
  PHASE=idle
  argo_restore

  delete_templates
  fp=$(live_fingerprint)
  state_set restore_counts - status ok dump_hash "$DUMP_SHA" fingerprint "$fp" imported_at "$(date -u +%FT%TZ)" \
    manifest "$(cat "$MANIFEST")" gitea_dump_version "$SRC_VERSION" >/dev/null
  python3 "$HERE/import-state.py" save gitea --namespace "$NS" --deployment "$DEPLOY" "${KCTX[@]}" || die "could not persist import evidence."
  strict=1
  if acceptance "$strict"; then
    info "IMPORT OK: $(grep -c '^U ' "$MANIFEST" || true) users, $(grep -c '^R ' "$MANIFEST" || true) repositories from dump ${DUMP_SHA:0:12}..."
  else
    die "the import ran, but the acceptance checks failed (see FAIL lines)."
  fi
}

main() {
  parse_args "$@"
  case $MODE in
    recipients) do_recipients; return 0 ;;
  esac
  preflight
  local kb=1024
  if [ "$MODE" = import ] && [ -f "$DUMP" ]; then kb=$(( $(wc -c <"$DUMP") / 1024 * 11 / 10 + 65536 )); fi
  make_scratch "$kb"
  trap on_exit EXIT
  case $MODE in
    recover) do_recover ;;
    accept) do_accept ;;
    import) do_import ;;
  esac
}

main "$@"
