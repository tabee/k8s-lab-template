#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
# gitea-import-vps-dump.sh: dump a Docker-based Gitea (the production forge) and stream it out ENCRYPTED.
#
# Runs ON the VPS, as a user that may call `docker`. READ-ONLY with respect to the VPS:
#   - it only runs `docker ps`, `docker exec ... gitea --version` and `gitea dump`;
#   - the dump goes to stdout (a pipe into age/sops), never to a plaintext file;
#   - gitea writes the SQL part to a temporary directory INSIDE the container, which this script creates
#     with mktemp and removes again on exit (trap);
#   - nothing is stopped, restarted, changed or installed.
#
# Output (stdout): ONE encrypted stream. Its plaintext is a tar archive that starts with the member
# gitea-import-meta.json (Gitea version, database type, UTC time) followed by the complete `gitea dump`
# tar (gitea-db.sql in PostgreSQL syntax, app.ini, repos/, data/). Whatever the source database is
# (sqlite3, mysql, postgres), the SQL is written in PostgreSQL syntax (`gitea dump --database postgres`).
# The dump contains secrets (app.ini); it is only ever useful while encrypted.
#
# Usage (recipients are PUBLIC age keys, taken from the .sops.yaml of the k8s-lab repo):
#   bash gitea-import-vps-dump.sh --recipient age1... [--recipient age1...] [--container NAME]
#                                 [--format age|sops] > gitea-dump.tar.age
#   from the PC over the VPN, without copying the script first:
#   ssh VPS 'bash -s -- --recipient age1...' < scripts/gitea-import-vps-dump.sh > gitea-dump.tar.age
#   --check   print container, Gitea version and database type, then stop (no dump, no recipient needed)
#   --format  age (default): `age` streaming, any size. sops: sops binary mode (one JSON file, whole dump in
#             memory: only for small forges). Both open with the same age private key.
#
# Messages go to stderr, stdout carries only the encrypted stream. Exit codes: 0 ok, 1 error, 2 usage.
set -euo pipefail

RECIPIENTS=()
CONTAINER=""
FORMAT="age"
CHECK=0
CONFIG="/data/gitea/conf/app.ini"

die() { echo "ERROR: $*" >&2; exit 1; }
say() { echo "gitea-import-vps-dump: $*" >&2; }
usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --recipient) [ $# -ge 2 ] || usage; RECIPIENTS+=("$2"); shift 2 ;;
    --container) [ $# -ge 2 ] || usage; CONTAINER=$2; shift 2 ;;
    --format) [ $# -ge 2 ] || usage; FORMAT=$2; shift 2 ;;
    --config) [ $# -ge 2 ] || usage; CONFIG=$2; shift 2 ;;
    --check) CHECK=1; shift ;;
    -h|--help) usage ;;
    *) echo "unknown option: $1" >&2; usage ;;
  esac
done

case "$FORMAT" in age|sops) ;; *) die "--format must be age or sops." ;; esac
command -v docker >/dev/null || die "docker is not available for this user."

# --- 1. find the Gitea container (the swarm task name looks like gitea_gitea.1.<id>)
if [ -z "$CONTAINER" ]; then
  mapfile -t CANDIDATES < <(docker ps --format '{{.Names}} {{.Image}}' | awk '$2 ~ /(^|\/)gitea(:|@|$)/ {print $1}')
  case ${#CANDIDATES[@]} in
    0) die "no running container with a gitea image found (docker ps). Name it with --container." ;;
    1) CONTAINER=${CANDIDATES[0]} ;;
    *) die "several gitea containers found: ${CANDIDATES[*]}. Name one with --container." ;;
  esac
fi
docker inspect --format '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -qx true || die "container $CONTAINER is not running."

# --- 2. Gitea version and database type (no secret is read: only DB_TYPE is picked out of app.ini)
VERSION=$(docker exec -u git "$CONTAINER" gitea --version 2>/dev/null | sed -n 's/^[Gg]itea version \([0-9][0-9.]*\).*/\1/p' | head -n 1)
[ -n "$VERSION" ] || die "cannot read the Gitea version in $CONTAINER (docker exec -u git $CONTAINER gitea --version)."
DB_TYPE=$(docker exec -u git "$CONTAINER" sh -c "sed -n 's/^DB_TYPE[[:space:]]*=[[:space:]]*//p' '$CONFIG' | head -n 1" 2>/dev/null | tr -d '\r ' || true)
[ -n "$DB_TYPE" ] || DB_TYPE=unknown
say "container=$CONTAINER version=$VERSION db_type=$DB_TYPE"
if [ "$CHECK" = 1 ]; then say "check only: nothing dumped."; exit 0; fi

[ ${#RECIPIENTS[@]} -gt 0 ] || die "give at least one --recipient age1... (public key from .sops.yaml)."
for r in "${RECIPIENTS[@]}"; do
  case "$r" in age1[0-9a-z]*) ;; *) die "recipient is not an age public key (age1...)." ;; esac
done
if [ "$FORMAT" = age ]; then
  command -v age >/dev/null || die "age is not installed here (only this tool is needed: apt install age). Or use --format sops."
else
  command -v sops >/dev/null || die "sops is not installed here. Use --format age (needs only age)."
fi
[ ! -t 1 ] || die "stdout is a terminal: redirect it into a file or pipe (> gitea-dump.tar.age)."

# --- 3. temp dir inside the container (removed on exit), meta member
TMPD=$(docker exec -u git "$CONTAINER" mktemp -d) || die "cannot create a temp dir in the container."
cleanup() { docker exec -u git "$CONTAINER" rm -rf "$TMPD" >/dev/null 2>&1 || true; [ -z "${MD:-}" ] || rm -rf "$MD"; }
trap cleanup EXIT
MD=$(mktemp -d)
printf '{"format":1,"gitea_version":"%s","db_type":"%s","dump_database":"postgres","created_utc":"%s","source_container":"%s"}\n' \
  "$VERSION" "$DB_TYPE" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$CONTAINER" > "$MD/gitea-import-meta.json"

# --- 4. stream: [meta member without end marker] + [complete gitea dump tar] -> encryption
say "dumping (the SQL part goes through $TMPD inside the container) ..."
stream() {
  # a ustar archive with one member ends in 1024 zero bytes (blocking factor 1); cut them off, then the
  # gitea tar follows, which brings its own end marker
  tar --format=ustar --blocking-factor=1 -C "$MD" -cf - gitea-import-meta.json | head -c -1024
  docker exec -u git "$CONTAINER" gitea dump -c "$CONFIG" -f - --type tar --database postgres \
    --tempdir "$TMPD" --skip-log -q
}
if [ "$FORMAT" = age ]; then
  AGE_ARGS=(); for r in "${RECIPIENTS[@]}"; do AGE_ARGS+=(-r "$r"); done
  stream | age "${AGE_ARGS[@]}"
else
  OUT=$(mktemp); [ -d /dev/shm ] && { rm -f "$OUT"; OUT=$(mktemp -p /dev/shm); }
  trap 'cleanup; rm -f "$OUT"' EXIT
  stream > "$OUT"
  # run in the directory of the temp file: sops would otherwise pick up a .sops.yaml of the current directory
  cd "$(dirname "$OUT")" || exit 1
  SOPS_AGE_RECIPIENTS=$(IFS=,; echo "${RECIPIENTS[*]}") sops --encrypt --input-type binary --output-type json "$OUT"
fi
say "done: encrypted stream written to stdout; temp dir removed."
