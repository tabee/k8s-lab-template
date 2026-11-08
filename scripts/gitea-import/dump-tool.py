#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
"""dump-tool.py: read a (plaintext, tmpfs) gitea dump tar as a stream, without unpacking it to disk.

Used by scripts/gitea-import.sh. Subcommands (DUMP is the tar file):
  meta DUMP        print gitea-import-meta.json of the VPS script (first member)
  inspect DUMP     print key=value lines: dump_db_type (from app.ini, ONLY the DB_TYPE line), sql_dialect,
                   members, repos, has_lfs, has_attachments (no secret value is ever printed)
  sql DUMP         write gitea-db.sql to stdout
  select DUMP      write a tar stream with the parts the import needs to stdout, under the names
                   repos/, lfs/, attachments/, avatars/, repo-avatars/ (everything else is left out)
Member names that are absolute or contain '..' are refused (exit 3).
"""
import json
import re
import sys
import tarfile

# dump member prefix -> name in the stream for the importer
MAP = (
    ("repos/", "repos/"),
    ("data/lfs/", "lfs/"),
    ("data/attachments/", "attachments/"),
    ("data/avatars/", "avatars/"),
    ("data/repo-avatars/", "repo-avatars/"),
)


def safe(name):
    n = name.lstrip("./") if name.startswith("./") else name
    if n.startswith("/") or ".." in n.split("/"):
        sys.stderr.write("ERROR: unsafe member name in the dump (refused)\n")
        sys.exit(3)
    return n


def members(path):
    with tarfile.open(path, mode="r|") as tf:
        for m in tf:
            yield tf, m


def cmd_meta(path):
    for tf, m in members(path):
        if safe(m.name) == "gitea-import-meta.json":
            sys.stdout.write(tf.extractfile(m).read().decode("utf-8"))
            return 0
        break
    sys.stderr.write("ERROR: the dump has no gitea-import-meta.json as first member "
                     "(create it with scripts/gitea-import-vps-dump.sh)\n")
    return 1


def cmd_inspect(path):
    n = repos = 0
    top = set()
    dbtype = ""
    sql_head = ""
    has_lfs = has_att = False
    for tf, m in members(path):
        name = safe(m.name)
        n += 1
        has_lfs = has_lfs or name.startswith("data/lfs/")
        has_att = has_att or name.startswith("data/attachments/")
        parts = name.split("/")
        top.add(parts[0] if len(parts) > 1 or m.isdir() else name)
        if name == "app.ini":
            for line in tf.extractfile(m).read().decode("utf-8", "replace").splitlines():
                mm = re.match(r"\s*DB_TYPE\s*=\s*(\S+)", line)
                if mm:
                    dbtype = mm.group(1)
                    break
        elif name == "gitea-db.sql":
            sql_head = tf.extractfile(m).read(300).decode("utf-8", "replace")
        elif re.fullmatch(r"repos/[^/]+/[^/]+\.git", name.rstrip("/")) and m.isdir():
            repos += 1
    d = re.search(r"from (\w+) to (\w+)\*/", sql_head)
    print("members=%d" % n)
    print("repos_dirs=%d" % repos)
    print("dump_db_type=%s" % (dbtype or "unknown"))
    print("sql_dialect=%s" % (d.group(2) if d else "unknown"))
    print("sql_from=%s" % (d.group(1) if d else "unknown"))
    print("has_sql=%d" % int("gitea-db.sql" in top))
    print("has_lfs=%d" % int(has_lfs))
    print("has_attachments=%d" % int(has_att))
    return 0


def cmd_sql(path):
    for tf, m in members(path):
        if safe(m.name) == "gitea-db.sql":
            f = tf.extractfile(m)
            while True:
                b = f.read(1 << 20)
                if not b:
                    return 0
                sys.stdout.buffer.write(b)
    sys.stderr.write("ERROR: gitea-db.sql is not in the dump\n")
    return 1


def cmd_select(path):
    out = tarfile.open(fileobj=sys.stdout.buffer, mode="w|", format=tarfile.GNU_FORMAT)
    for tf, m in members(path):
        name = safe(m.name)
        for src, dst in MAP:
            if name.startswith(src) or name + "/" == src.rstrip("/") + "/":
                m.name = dst + name[len(src):]
                if m.name.rstrip("/") == dst.rstrip("/") and not m.isdir():
                    break
                m.uid = m.gid = 0
                m.uname = m.gname = ""
                if m.isreg():
                    out.addfile(m, tf.extractfile(m))
                else:
                    out.addfile(m)
                break
    out.close()
    return 0


def main(argv):
    if len(argv) != 3 or argv[1] not in ("meta", "inspect", "sql", "select"):
        sys.stderr.write(__doc__)
        return 2
    return {"meta": cmd_meta, "inspect": cmd_inspect, "sql": cmd_sql, "select": cmd_select}[argv[1]](argv[2])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
