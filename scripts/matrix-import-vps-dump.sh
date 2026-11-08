#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
# matrix-import-vps-dump.sh: dump a Docker-based Synapse (database, media store, signing key) and stream it out ENCRYPTED.
#
# Runs ON the VPS, as a user that may call `docker`. STRICTLY READ-ONLY with respect to the VPS:
#   - it only runs `docker ps`, `docker inspect` and `docker exec` (pg_dump and psql SELECT in the Postgres container,
#     a Python reader in the Synapse container that opens files for reading only);
#   - the dump goes to stdout, through a pipe into age. No plaintext file, no temp file, no write into any container;
#   - nothing is stopped, restarted, locked for writing, changed or installed. Synapse keeps running (pg_dump reads
#     one consistent snapshot; the media store is read after the database, so every media row in the dump has its file).
#
# Output (stdout): ONE age-encrypted stream. Its plaintext is a tar archive with, in this order:
#   matrix-import-meta.json     server_name, Synapse and Postgres version, creation time (UTC), source host, public
#                               signing verify key, allow-listed non-secret settings (no secret value)
#   secrets/signing.key         the Synapse signing key (server identity)
#   secrets/macaroon.secret     macaroon_secret_key (keeps old-style access tokens valid), when set
#   secrets/form.secret         form_secret, when set
#   db/dump.sql.NNNNNN          pg_dump --no-owner --no-privileges (plain SQL) in 8 MiB members
#   media/...                   the media store (local and remote media; not the URL preview cache)
#   matrix-import-trailer.json  sizes, SHA-256 of the SQL, "complete": true (only written after a clean read)
# The stream contains secrets. It is only ever useful while encrypted: the recipients are PUBLIC age keys.
#
# Usage (recipients are the age keys of the .sops.yaml of the k8s-lab repo, `lab.sh matrix-import recipients` prints
# the exact command). Write to a .partial name first, so a broken run never looks like a dump:
#   ssh $MATRIX_IMPORT_SSH 'bash -s -- --recipient age1... [--recipient age1...]' < scripts/matrix-import-vps-dump.sh > matrix-dump.age.partial \
#     && mv matrix-dump.age.partial matrix-dump.age
#   ssh $MATRIX_IMPORT_SSH 'bash -s -- --check' < scripts/matrix-import-vps-dump.sh       read-only inspection, no dump, no recipient
# Options:
#   --recipient KEY            age public key (repeatable, at least one for a dump)
#   --check                    print what would be dumped and verify every precondition, then stop (exit 1 on a problem)
#   --container NAME           Synapse container (default: the one running a synapse image)
#   --postgres-container NAME  Postgres container (default: the one that has the Synapse database)
#   --config PATH              homeserver.yaml INSIDE the Synapse container (default $SYNAPSE_CONFIG_PATH or /data/homeserver.yaml)
#   --pg-user USER             Postgres superuser for pg_dump (default postgres; needs local trust inside the container)
#   --no-remote-media          leave remote_content/remote_thumbnails out (media cached from other servers)
#
# Messages go to stderr, stdout carries only the encrypted stream. Exit codes: 0 ok, 1 error, 2 usage.
set -euo pipefail

RECIPIENTS=()
CONTAINER=""
PGCONTAINER=""
CONFIG=""
PGUSER_DUMP="postgres"
REMOTE_MEDIA=1
CHECK=0

die() { echo "ERROR: $*" >&2; exit 1; }
say() { echo "matrix-import-vps-dump: $*" >&2; }
usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --recipient) [ $# -ge 2 ] || usage; RECIPIENTS+=("$2"); shift 2 ;;
    --container) [ $# -ge 2 ] || usage; CONTAINER=$2; shift 2 ;;
    --postgres-container) [ $# -ge 2 ] || usage; PGCONTAINER=$2; shift 2 ;;
    --config) [ $# -ge 2 ] || usage; CONFIG=$2; shift 2 ;;
    --pg-user) [ $# -ge 2 ] || usage; PGUSER_DUMP=$2; shift 2 ;;
    --no-remote-media) REMOTE_MEDIA=0; shift ;;
    --check) CHECK=1; shift ;;
    -h | --help) usage ;;
    *) echo "unknown option: $1" >&2; usage ;;
  esac
done

command -v docker > /dev/null || die "docker is not available for this user."

# BEGIN-PACK-PY (the Python program that runs inside the Synapse container; scripts/matrix-import/ tests extract it)
read -r -d '' PACK_PY << 'PYEOF' || true
import hashlib
import json
import os
import sys
import tarfile
import time

CHUNK = 8 * 1024 * 1024
MARK = b"-- PostgreSQL database dump complete"
SETTING_KEYS = (
    "public_baseurl", "enable_registration", "allow_guest_access", "federation_domain_whitelist",
    "trusted_key_servers", "serve_server_wellknown", "url_preview_enabled", "max_upload_size",
    "user_directory", "presence", "extra_well_known_client_content", "experimental_features",
    "max_event_delay_duration", "rc_message", "rc_delayed_event_mgmt", "rc_login", "rc_registration",
    "retention", "media_retention", "limit_remote_rooms", "default_room_version",
    "allow_public_rooms_over_federation", "enable_3pid_lookup", "dynamic_thumbnails",
)
# Only the NAME of these is recorded: their values hold secrets (client secrets, SMTP password, shared secrets).
PRESENT_KEYS = (
    "oidc_providers", "saml2_config", "cas_config", "sso", "modules", "app_service_config_files", "email",
    "push", "turn_uris", "turn_shared_secret", "worker_app", "redis", "enable_metrics", "opentracing",
)


def load(path):
    import yaml
    with open(path, encoding="utf-8") as handle:
        return yaml.safe_load(handle) or {}


def verify_key_of(path):
    from signedjson.key import encode_verify_key_base64, get_verify_key, read_signing_keys
    with open(path, encoding="utf-8") as handle:
        keys = read_signing_keys(handle)
    key = keys[0]
    return {"id": "%s:%s" % (key.alg, key.version), "key": encode_verify_key_base64(get_verify_key(key))}


def locate(cfg, config_path):
    base = os.path.dirname(config_path)
    server = str(cfg.get("server_name") or "")
    key = cfg.get("signing_key_path") or os.path.join(base, server + ".signing.key")
    media = cfg.get("media_store_path") or os.path.join(base, "media_store")
    return server, key, media


def walk_media(media, remote):
    for top in sorted(os.listdir(media)):
        if top.startswith("url_cache"):
            continue
        if not remote and top.startswith("remote_"):
            continue
        for root, dirs, files in os.walk(os.path.join(media, top)):
            dirs.sort()
            for name in sorted(files):
                path = os.path.join(root, name)
                if os.path.islink(path) or not os.path.isfile(path):
                    continue
                yield path, os.path.relpath(path, media)


def info(config_path, remote):
    cfg = load(config_path)
    server, keypath, media = locate(cfg, config_path)
    db = cfg.get("database") or {}
    args = db.get("args") or {}
    import synapse
    files = size = 0
    if os.path.isdir(media):
        for path, _rel in walk_media(media, remote):
            try:
                size += os.path.getsize(path)
                files += 1
            except OSError:
                pass
    out = {
        "server_name": server,
        "synapse_version": synapse.__version__,
        "db_engine": db.get("name", ""),
        "db_name": args.get("database") or args.get("dbname") or "",
        "db_user": args.get("user", ""),
        "signing_key_path": keypath,
        "signing_key_present": os.path.isfile(keypath),
        "media_store_path": media,
        "media_store_present": os.path.isdir(media),
        "media_files": files,
        "media_bytes": size,
        "media_storage_providers": bool(cfg.get("media_storage_providers")),
        "password_pepper": bool((cfg.get("password_config") or {}).get("pepper")),
        "macaroon_secret_set": bool(cfg.get("macaroon_secret_key")),
        "form_secret_set": bool(cfg.get("form_secret")),
        "old_signing_keys": bool(cfg.get("old_signing_keys")),
        "settings": {k: cfg[k] for k in SETTING_KEYS if k in cfg},
        "features_present": [k for k in PRESENT_KEYS if cfg.get(k)],
    }
    if out["signing_key_present"]:
        try:
            out["verify_key"] = verify_key_of(keypath)
        except Exception as exc:  # noqa: BLE001 - reported, never fatal here
            out["verify_key_error"] = type(exc).__name__
    json.dump(out, sys.stdout)
    return 0


def add_bytes(tar, name, data, mode=0o600):
    member = tarfile.TarInfo(name)
    member.size = len(data)
    member.mode = mode
    member.mtime = int(time.time())
    import io
    tar.addfile(member, io.BytesIO(data))


def read_one_line(path):
    with open(path, encoding="utf-8") as handle:
        return handle.read().strip() + "\n"


def pack(config_path, meta_json, remote):
    cfg = load(config_path)
    server, keypath, media = locate(cfg, config_path)
    meta = json.loads(meta_json)
    meta.update({"format": 1, "kind": "matrix-import", "server_name": server})
    out = sys.stdout.buffer
    tar = tarfile.open(fileobj=out, mode="w|", format=tarfile.PAX_FORMAT)
    add_bytes(tar, "matrix-import-meta.json", (json.dumps(meta, sort_keys=True) + "\n").encode("utf-8"))
    add_bytes(tar, "secrets/signing.key", read_one_line(keypath).encode("utf-8"))
    for name, key in (("macaroon.secret", "macaroon_secret_key"), ("form.secret", "form_secret")):
        value = cfg.get(key)
        if value:
            add_bytes(tar, "secrets/" + name, (str(value).strip() + "\n").encode("utf-8"))
    sha = hashlib.sha256()
    total = chunks = 0
    tail = b""
    stdin = sys.stdin.buffer
    while True:
        buf = b""
        while len(buf) < CHUNK:
            part = stdin.read(CHUNK - len(buf))
            if not part:
                break
            buf += part
        if not buf:
            break
        chunks += 1
        total += len(buf)
        sha.update(buf)
        tail = (tail + buf)[-4096:]
        add_bytes(tar, "db/dump.sql.%06d" % chunks, buf)
    if MARK not in tail:
        sys.stderr.write("the SQL stream ends without the pg_dump completion marker: pg_dump failed or was cut off\n")
        return 1
    files = size = 0
    if os.path.isdir(media):
        for path, rel in walk_media(media, remote):
            try:
                with open(path, "rb") as handle:
                    st = os.fstat(handle.fileno())
                    member = tarfile.TarInfo("media/" + rel)
                    member.size = st.st_size
                    member.mode = 0o640
                    member.mtime = int(st.st_mtime)
                    tar.addfile(member, handle)
                files += 1
                size += st.st_size
            except OSError:
                continue
    trailer = {"complete": True, "db_bytes": total, "db_chunks": chunks, "db_sha256": sha.hexdigest(),
               "media_files": files, "media_bytes": size}
    add_bytes(tar, "matrix-import-trailer.json", (json.dumps(trailer, sort_keys=True) + "\n").encode("utf-8"))
    tar.close()
    out.flush()
    return 0


def main(argv):
    cmd, config_path = argv[1], argv[2]
    remote = argv[-1] == "1"
    if cmd == "info":
        return info(config_path, remote)
    if cmd == "pack":
        return pack(config_path, argv[3], remote)
    return 2


sys.exit(main(sys.argv))
PYEOF
# END-PACK-PY

jget() { python3 -c 'import json,sys
d=json.load(sys.stdin)
v=d
for p in sys.argv[1].split("."):
    v=v.get(p, "") if isinstance(v, dict) else ""
print(json.dumps(v) if isinstance(v, (dict, list)) else ("true" if v is True else ("false" if v is False else v)))' "$1"; }

# --- 1. the Synapse container (the swarm task name looks like matrix_synapse.1.<id>)
if [ -z "$CONTAINER" ]; then
  mapfile -t CANDIDATES < <(docker ps --format '{{.Names}} {{.Image}}' | awk '$2 ~ /(^|\/)synapse(:|@|$)/ {print $1}')
  case ${#CANDIDATES[@]} in
    0) die "no running container with a synapse image found (docker ps). Name it with --container." ;;
    1) CONTAINER=${CANDIDATES[0]} ;;
    *) die "several synapse containers found: ${CANDIDATES[*]}. Name one with --container." ;;
  esac
fi
docker inspect --format '{{.State.Running}}' "$CONTAINER" 2> /dev/null | grep -qx true || die "container $CONTAINER is not running."
if [ -z "$CONFIG" ]; then
  CONFIG=$(docker exec "$CONTAINER" sh -c 'printf %s "${SYNAPSE_CONFIG_PATH:-/data/homeserver.yaml}"' 2> /dev/null || true)
  [ -n "$CONFIG" ] || CONFIG=/data/homeserver.yaml
fi
case $CONFIG in /?*) ;; *) die "--config must be an absolute path inside the container." ;; esac

# --- 2. what the Synapse container says about itself (reads the config and the key file, prints no secret value)
INFO=$(docker exec "$CONTAINER" python -c "$PACK_PY" info "$CONFIG" "$REMOTE_MEDIA") \
  || die "cannot read $CONFIG in $CONTAINER with python (docker exec $CONTAINER python ...)."
SERVER_NAME=$(printf '%s' "$INFO" | jget server_name)
SYN_VERSION=$(printf '%s' "$INFO" | jget synapse_version)
DB_NAME=$(printf '%s' "$INFO" | jget db_name)
DB_ENGINE=$(printf '%s' "$INFO" | jget db_engine)

PROBLEMS=0
problem() { echo "  FAIL  $*" >&2; PROBLEMS=$((PROBLEMS + 1)); }
good() { echo "  OK    $*" >&2; }

# --- 3. the Postgres container: the one that has this database
psq() { docker exec "$PGCONTAINER" psql -X -q -At -U "$PGUSER_DUMP" -d "$DB_NAME" "$@"; }
if [ -n "$DB_NAME" ] && [ "$DB_ENGINE" = psycopg2 ]; then
  if [ -z "$PGCONTAINER" ]; then
    mapfile -t PGC < <(docker ps --format '{{.Names}} {{.Image}}' | awk '$2 ~ /(^|\/)postgres(:|@|$)/ {print $1}')
    FOUND=()
    for c in "${PGC[@]}"; do
      if docker exec "$c" psql -X -q -At -U "$PGUSER_DUMP" -d "$DB_NAME" -c 'SELECT 1' > /dev/null 2>&1; then FOUND+=("$c"); fi
    done
    case ${#FOUND[@]} in
      0) PGCONTAINER="" ;;
      1) PGCONTAINER=${FOUND[0]} ;;
      *) die "several Postgres containers have a database '$DB_NAME': ${FOUND[*]}. Name one with --postgres-container." ;;
    esac
  fi
fi
PG_VERSION=""; PG_COLLATE=""; PG_CTYPE=""; SCHEMA_VERSION=""; USERS=""; DB_BYTES=""; ROOMS=""; EVENTS=""
if [ -n "${PGCONTAINER:-}" ]; then
  PG_VERSION=$(psq -c 'SHOW server_version' 2> /dev/null | awk '{print $1}' || true)
  PG_COLLATE=$(psq -c "SELECT datcollate FROM pg_database WHERE datname = current_database()" 2> /dev/null || true)
  PG_CTYPE=$(psq -c "SELECT datctype FROM pg_database WHERE datname = current_database()" 2> /dev/null || true)
  SCHEMA_VERSION=$(psq -c 'SELECT max(version) FROM schema_version' 2> /dev/null || true)
  USERS=$(psq -c 'SELECT count(*) FROM users' 2> /dev/null || true)
  ROOMS=$(psq -c 'SELECT count(*) FROM rooms' 2> /dev/null || true)
  EVENTS=$(psq -c 'SELECT count(*) FROM events' 2> /dev/null || true)
  DB_BYTES=$(psq -c 'SELECT pg_database_size(current_database())' 2> /dev/null || true)
fi
HOSTNAME_SRC=$(hostname -f 2> /dev/null || hostname 2> /dev/null || echo unknown)
MEDIA_FILES=$(printf '%s' "$INFO" | jget media_files)
MEDIA_BYTES=$(printf '%s' "$INFO" | jget media_bytes)

say "host=$HOSTNAME_SRC container=$CONTAINER postgres=${PGCONTAINER:-none} server_name=$SERVER_NAME synapse=$SYN_VERSION"
say "preconditions:"
[ -n "$SERVER_NAME" ] && good "server_name $SERVER_NAME" || problem "no server_name in $CONFIG"
[ -n "$SYN_VERSION" ] && good "Synapse $SYN_VERSION" || problem "cannot read the Synapse version"
[ "$DB_ENGINE" = psycopg2 ] && good "database engine psycopg2 (PostgreSQL)" || problem "database engine is '${DB_ENGINE:-none}': only PostgreSQL (psycopg2) sources are supported"
[ -n "${PGCONTAINER:-}" ] && good "Postgres container $PGCONTAINER, database $DB_NAME, server $PG_VERSION, $USERS users, $ROOMS rooms, $EVENTS events, $DB_BYTES bytes" \
  || problem "no Postgres container answers for database '$DB_NAME' as user $PGUSER_DUMP (name it with --postgres-container, or --pg-user)"
case ${PG_COLLATE:-}/${PG_CTYPE:-} in C/C | POSIX/POSIX) good "database collation C (Synapse requirement)" ;; /) ;; *) problem "database collation is '$PG_COLLATE/$PG_CTYPE', Synapse needs C/C" ;; esac
[ "$(printf '%s' "$INFO" | jget signing_key_present)" = true ] && good "signing key $(printf '%s' "$INFO" | jget signing_key_path) readable" || problem "signing key file not found in the container"
[ -n "$(printf '%s' "$INFO" | jget verify_key.key)" ] && good "verify key $(printf '%s' "$INFO" | jget verify_key.id) $(printf '%s' "$INFO" | jget verify_key.key)" || problem "cannot compute the verify key of the signing key"
[ "$(printf '%s' "$INFO" | jget media_store_present)" = true ] && good "media store $(printf '%s' "$INFO" | jget media_store_path): $MEDIA_FILES files, $MEDIA_BYTES bytes" || problem "media store directory not found"
[ "$(printf '%s' "$INFO" | jget media_storage_providers)" = false ] && good "no media storage providers (all media is on disk)" || problem "media_storage_providers is set: media outside the media store is not dumped"
[ "$(printf '%s' "$INFO" | jget password_pepper)" = false ] && good "no password pepper" || problem "password_config.pepper is set: the lab cannot verify the old passwords without it"
[ "$(printf '%s' "$INFO" | jget macaroon_secret_set)" = true ] || say "  note  no macaroon_secret_key in the config: old-style access tokens cannot be carried over"
[ "$(printf '%s' "$INFO" | jget old_signing_keys)" = false ] || say "  note  old_signing_keys is set: retired keys are not carried over"
FEATURES=$(printf '%s' "$INFO" | jget features_present)
[ "$FEATURES" = "[]" ] || say "  note  the source config uses: $FEATURES (not carried over; the lab sets these in Git, ADR for Matrix import)"
command -v age > /dev/null && good "age is installed" || problem "age is not installed here (apt install age)"
if [ "$CHECK" = 1 ]; then
  [ "$PROBLEMS" = 0 ] || die "$PROBLEMS precondition(s) failed. Nothing was dumped."
  say "check only: all preconditions hold, nothing dumped (read-only)."
  exit 0
fi
[ "$PROBLEMS" = 0 ] || die "$PROBLEMS precondition(s) failed (run with --check for details). Nothing was dumped."

[ ${#RECIPIENTS[@]} -gt 0 ] || die "give at least one --recipient age1... (public key from .sops.yaml)."
for r in "${RECIPIENTS[@]}"; do
  case "$r" in age1[0-9a-z]*) ;; *) die "recipient is not an age public key (age1...)." ;; esac
done
[ ! -t 1 ] || die "stdout is a terminal: redirect it into a file or pipe (> matrix-dump.age.partial)."

META=$(printf '%s' "$INFO" | python3 -c 'import json,sys
i=json.load(sys.stdin)
a=sys.argv
m={"created_utc":a[1],"source_host":a[2],"source_container":a[3],"postgres_container":a[4],"synapse_version":i["synapse_version"],
   "db_name":i["db_name"],"db_user":i["db_user"],"pg_version":a[5],"datcollate":a[6],"schema_version":a[7],
   "users":a[8],"rooms":a[9],"events":a[10],"verify_key":i.get("verify_key",{}),"settings":i["settings"],"features_present":i["features_present"],
   "media_files_expected":i["media_files"],"media_bytes_expected":i["media_bytes"],"remote_media":a[11]=="1",
   "has_macaroon_secret":i["macaroon_secret_set"],"has_form_secret":i["form_secret_set"],
   "password_pepper":i["password_pepper"],"media_storage_providers":i["media_storage_providers"]}
print(json.dumps(m))' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$HOSTNAME_SRC" "$CONTAINER" "$PGCONTAINER" "$PG_VERSION" "$PG_COLLATE" \
  "$SCHEMA_VERSION" "$USERS" "$ROOMS" "$EVENTS" "$REMOTE_MEDIA")

# --- 4. stream: pg_dump -> Python packer in the Synapse container (tar) -> age
say "dumping (the database snapshot comes first, the media store after it; nothing touches a disk here) ..."
AGE_ARGS=()
for r in "${RECIPIENTS[@]}"; do AGE_ARGS+=(-r "$r"); done
docker exec "$PGCONTAINER" pg_dump -U "$PGUSER_DUMP" --no-owner --no-privileges --no-tablespaces --format=plain --encoding=UTF8 \
  --lock-wait-timeout=60000 "$DB_NAME" \
  | docker exec -i "$CONTAINER" python -c "$PACK_PY" pack "$CONFIG" "$META" "$REMOTE_MEDIA" \
  | age "${AGE_ARGS[@]}"
say "done: encrypted stream written to stdout. If this line is missing, the dump is incomplete: delete it."
