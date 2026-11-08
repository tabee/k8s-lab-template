#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
"""dump-tool.py: read the plaintext tar stream of a matrix-import dump from STDIN. Nothing is written to disk.

Used by scripts/matrix-import.sh behind `age -d` (several passes over the encrypted file, one per job). Layout of
the stream (made by scripts/matrix-import-vps-dump.sh): matrix-import-meta.json, secrets/*, db/dump.sql.NNNNNN,
media/..., matrix-import-trailer.json. Subcommands:
  inspect          read EVERYTHING, verify the order, the chunk numbers, the SHA-256 and the counts against the
                   trailer; print one JSON object {meta, trailer, secrets, observed}. Exit 3 = unsafe or broken,
                   4 = incomplete (no trailer: the dump was cut off or pg_dump failed)
  meta             print matrix-import-meta.json (first member) and stop
  db               write the SQL (db/ members) to stdout and stop. Refuses psql meta-commands (backslash lines
                   outside COPY data, except \\restrict and \\unrestrict): the dump is data, never a script
  media            write a tar stream with the media/ members (names without the media/ prefix) to stdout
  secret NAME      write secrets/NAME (one line) to stdout; exit 5 when it is absent
  secret-sha NAME  print the SHA-256 of that line, never the line
  diff LABYAML     (meta JSON from stdin) print the non-secret settings of the source that differ from the lab config
Member names that are absolute, contain '..' or are not regular files are refused (exit 3).
"""
import hashlib
import json
import re
import sys
import tarfile

CHUNK_RE = re.compile(r"^db/dump\.sql\.(\d{6})$")
SECRET_NAMES = ("signing.key", "macaroon.secret", "form.secret")
COPY_RE = re.compile(r"^COPY .* FROM stdin;$")


def fail(code, text):
    sys.stderr.write("ERROR: %s\n" % text)
    sys.exit(code)


def safe(name):
    if name.startswith("/") or ".." in name.split("/") or "\x00" in name:
        fail(3, "unsafe member name in the dump (refused)")
    return name


def members():
    tar = tarfile.open(fileobj=sys.stdin.buffer, mode="r|*")
    for member in tar:
        safe(member.name)
        if not member.isreg():
            fail(3, "the dump has a member that is not a regular file (refused)")
        yield tar, member


def read_json(tar, member):
    try:
        return json.loads(tar.extractfile(member).read().decode("utf-8"))
    except ValueError:
        fail(3, "%s is not valid JSON" % member.name)


def first_meta():
    for tar, member in members():
        if member.name == "matrix-import-meta.json":
            return read_json(tar, member)
        break
    fail(3, "the dump has no matrix-import-meta.json as first member (make it with scripts/matrix-import-vps-dump.sh)")


def cmd_inspect():
    meta = trailer = None
    secrets = []
    db_bytes = db_chunks = media_files = media_bytes = n = 0
    sha = hashlib.sha256()
    phase = 0
    for tar, member in members():
        name = member.name
        n += 1
        if n == 1:
            if name != "matrix-import-meta.json":
                fail(3, "first member is %s, not matrix-import-meta.json" % name)
            meta = read_json(tar, member)
            continue
        if trailer is not None:
            fail(3, "members after the trailer")
        if name.startswith("secrets/"):
            if phase > 0 or name[8:] not in SECRET_NAMES:
                fail(3, "unexpected secrets member")
            secrets.append(name[8:])
        elif CHUNK_RE.match(name):
            phase = max(phase, 1)
            if phase > 1:
                fail(3, "db member after media")
            db_chunks += 1
            if int(CHUNK_RE.match(name).group(1)) != db_chunks:
                fail(3, "db chunks are not numbered 1..n without gaps")
            handle = tar.extractfile(member)
            while True:
                block = handle.read(1 << 20)
                if not block:
                    break
                sha.update(block)
                db_bytes += len(block)
        elif name.startswith("media/"):
            phase = 2
            media_files += 1
            media_bytes += member.size
        elif name == "matrix-import-trailer.json":
            trailer = read_json(tar, member)
        else:
            fail(3, "unexpected member in the dump")
    if trailer is None or not trailer.get("complete"):
        fail(4, "the dump has no complete trailer: it was cut off, or pg_dump failed on the VPS. Make a new dump.")
    observed = {"db_bytes": db_bytes, "db_chunks": db_chunks, "db_sha256": sha.hexdigest(),
                "media_files": media_files, "media_bytes": media_bytes}
    for key, value in observed.items():
        if trailer.get(key) != value:
            fail(3, "trailer and content disagree on %s" % key)
    if "signing.key" not in secrets:
        fail(3, "the dump has no signing key")
    json.dump({"meta": meta, "trailer": trailer, "secrets": secrets, "observed": observed}, sys.stdout)
    sys.stdout.write("\n")
    return 0


def cmd_meta():
    json.dump(first_meta(), sys.stdout)
    sys.stdout.write("\n")
    return 0


def sql_lines(tar, member, state):
    """Yield bytes lines of one chunk, joined across chunk borders."""
    handle = tar.extractfile(member)
    carry = state["carry"]
    while True:
        block = handle.read(1 << 20)
        if not block:
            break
        data = carry + block
        parts = data.split(b"\n")
        carry = parts.pop()
        for line in parts:
            yield line + b"\n"
    state["carry"] = carry


def check_line(line, state):
    if state["in_copy"]:
        if line == b"\\.\n":
            state["in_copy"] = False
        return
    if line.startswith(b"\\"):
        if not (line.startswith(b"\\restrict ") or line.startswith(b"\\unrestrict ")):
            fail(3, "the SQL contains a psql meta-command (refused): the dump is not a plain pg_dump")
        return
    text = line.rstrip(b"\n").decode("utf-8", "replace")
    if COPY_RE.match(text):
        state["in_copy"] = True


def cmd_db():
    state = {"carry": b"", "in_copy": False}
    out = sys.stdout.buffer
    seen = False
    first = True
    for tar, member in members():
        if first:
            first = False
            continue
        if member.name.startswith("secrets/"):
            continue
        if not CHUNK_RE.match(member.name):
            if seen:
                break
            fail(3, "the dump has no database part")
        seen = True
        for line in sql_lines(tar, member, state):
            check_line(line, state)
            out.write(line)
    if state["carry"]:
        check_line(state["carry"], state)
        out.write(state["carry"])
    if state["in_copy"]:
        fail(3, "the SQL ends inside COPY data")
    out.flush()
    return 0 if seen else 3


def cmd_media():
    out = tarfile.open(fileobj=sys.stdout.buffer, mode="w|", format=tarfile.PAX_FORMAT)
    first = True
    for tar, member in members():
        if first:
            first = False
            continue
        if not member.name.startswith("media/"):
            continue
        rel = member.name[len("media/"):]
        if not rel:
            continue
        info = tarfile.TarInfo(rel)
        info.size = member.size
        info.mode = 0o640
        info.mtime = member.mtime
        out.addfile(info, tar.extractfile(member))
    out.close()
    return 0


def read_secret(name):
    if name not in SECRET_NAMES:
        fail(2, "unknown secret name")
    first = True
    for tar, member in members():
        if first:
            first = False
            continue
        if member.name == "secrets/" + name:
            return tar.extractfile(member).read().decode("utf-8").strip()
        if not member.name.startswith("secrets/"):
            break
    return None


def cmd_secret(name, sha_only):
    value = read_secret(name)
    if value is None:
        return 5
    if "\n" in value:
        fail(3, "the secret is not a single line")
    if sha_only:
        sys.stdout.write(hashlib.sha256(value.encode("utf-8")).hexdigest() + "\n")
    else:
        sys.stdout.write(value + "\n")
    return 0


# Only keys that are plain settings (no secrets) and that matter for clients. The lab keeps ITS values.
COMPARE = ("public_baseurl", "max_upload_size", "url_preview_enabled", "user_directory", "presence",
           "extra_well_known_client_content", "experimental_features", "max_event_delay_duration", "rc_message",
           "rc_delayed_event_mgmt", "rc_login", "rc_registration", "retention", "media_retention",
           "default_room_version", "dynamic_thumbnails", "enable_registration", "allow_guest_access")


def cmd_diff(lab_path):
    try:
        import yaml
    except ImportError:
        sys.stdout.write("SKIP settings comparison (python3 PyYAML is missing)\n")
        return 0
    meta = json.load(sys.stdin)
    with open(lab_path, encoding="utf-8") as handle:
        lab = yaml.safe_load(handle) or {}
    src = meta.get("settings") or {}
    for key in COMPARE:
        if key not in src:
            continue
        if key in ("public_baseurl",):
            continue
        if lab.get(key) != src[key]:
            sys.stdout.write("%s: source %s, lab %s\n" % (key, json.dumps(src[key], sort_keys=True)[:160],
                                                          json.dumps(lab.get(key, "(default)"), sort_keys=True)[:160]))
    for feat in meta.get("features_present") or []:
        sys.stdout.write("%s: set on the source (not carried over)\n" % feat)
    return 0


def main(argv):
    cmd = argv[1] if len(argv) > 1 else ""
    if cmd == "inspect":
        return cmd_inspect()
    if cmd == "meta":
        return cmd_meta()
    if cmd == "db":
        return cmd_db()
    if cmd == "media":
        return cmd_media()
    if cmd in ("secret", "secret-sha") and len(argv) == 3:
        return cmd_secret(argv[2], cmd == "secret-sha")
    if cmd == "diff" and len(argv) == 3:
        return cmd_diff(argv[2])
    sys.stderr.write(__doc__)
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except (tarfile.TarError, EOFError) as exc:
        fail(4, "the dump is cut off or damaged (%s)" % type(exc).__name__)
