#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
"""Off-host replica of the rustfs backup data (issue #3): mirror, verify, freshness, preflight, key line.

The primary stays rustfs on the host (data dir of the Quadlet). The replica is a plain directory on another
machine of the home LAN, reached over ssh with a dedicated key that is restricted (restrict, from=, rrsync).
Nothing runs as root on the replica. Everything is configured by one JSON file that Ansible renders from
ansible/inventory/group_vars/all/backup_replica.yml (host, user, paths and limits live only there).

Subcommands (all take --config FILE)
  preflight [--install]   Checks tools, key files, reachability (ssh BatchMode), free space and packages.
                          --install uses the personal install key (shell access, used once); without it the
                          restricted replica key is tested (rsync listing only). Prints OK/MISSING lines.
  authline                Prints the authorized_keys line for the replica key (restrict, from=, rrsync).
  mirror                  rsync of the data dir to the replica, then writes the freshness stamp there.
  verify                  Freshness plus a checksum comparison of every file older than the last mirror start.
  status [--json]         Freshness only (age of the last successful mirror). Exit 1 when too old.
  restore --target DIR    Pulls the replica copy back into a NEW empty directory (never into the live data dir),
                          then compares by checksum. Serve that directory with a throwaway rustfs and run
                          the restore drill against it (docs/how-to/backup-replica.md).
  hostkey                 Prints the ssh host key line and its fingerprint (public data) for pinning.

Exit codes: 0 = ok, 1 = a check failed or something is missing, 2 = usage or config error.
The stamp is a small JSON file on the replica: {"started": epoch, "finished": epoch, "files": n, "bytes": n}.
"""
import argparse
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
import time

STAMP = "mirror-stamp.json"
REQUIRED = ("host", "user", "key", "known_hosts", "remote_dir", "data_dir", "max_age_min")
PUB_RE = re.compile(r"^ssh-ed25519 [A-Za-z0-9+/=]+( [^\n]*)?$")
HOST_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9.-]*$")
USER_RE = re.compile(r"^[a-z_][a-z0-9_-]*$")
PATH_RE = re.compile(r"^[A-Za-z0-9._/-]+$")


class ConfigError(Exception):
    pass


def load_config(path):
    try:
        cfg = json.load(open(path, encoding="utf-8"))
    except (OSError, ValueError) as e:
        raise ConfigError("cannot read config %s: %s" % (path, e))
    missing = [k for k in REQUIRED if cfg.get(k) in (None, "")]
    if missing:
        raise ConfigError("config is missing: %s" % ", ".join(missing))
    if not HOST_RE.match(str(cfg["host"])):
        raise ConfigError("host '%s' is not a plain host name or IP" % cfg["host"])
    if not USER_RE.match(str(cfg["user"])):
        raise ConfigError("user '%s' is not a plain user name" % cfg["user"])
    for k in ("remote_dir",):
        if not PATH_RE.match(str(cfg[k])) or ".." in str(cfg[k]):
            raise ConfigError("%s '%s' has characters that are not allowed" % (k, cfg[k]))
    cfg.setdefault("port", 22)
    cfg.setdefault("install_key", "")
    cfg.setdefault("from_cidr", "")
    cfg.setdefault("allow_delete", False)
    cfg.setdefault("connect_timeout", 10)
    cfg.setdefault("io_timeout", 120)
    cfg.setdefault("exclude", [])
    cfg.setdefault("min_free_factor", 1.2)
    cfg.setdefault("min_free_mib", 512)
    cfg.setdefault("ssh_bin", "ssh")
    cfg.setdefault("rsync_bin", "rsync")
    cfg.setdefault("rrsync", "/usr/bin/rrsync")
    cfg.setdefault("now", None)
    return cfg


def now(cfg):
    return float(cfg["now"]) if cfg.get("now") else time.time()


def run(argv, input_text=None, timeout=None):
    try:
        p = subprocess.run(argv, input=input_text, capture_output=True, text=True, timeout=timeout)
    except FileNotFoundError:
        return 127, "", "%s: command not found" % argv[0]
    except subprocess.TimeoutExpired:
        return 124, "", "%s: timeout after %ss" % (argv[0], timeout)
    return p.returncode, p.stdout, p.stderr


def ssh_opts(cfg, key):
    return [
        "-i", key, "-p", str(cfg["port"]),
        "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes",
        "-o", "StrictHostKeyChecking=yes", "-o", "UserKnownHostsFile=%s" % cfg["known_hosts"],
        "-o", "ConnectTimeout=%s" % cfg["connect_timeout"],
    ]


def rsync_shell(cfg):
    return " ".join(shlex.quote(x) for x in [cfg["ssh_bin"]] + ssh_opts(cfg, cfg["key"]))


def remote(cfg, path=""):
    return "%s@%s:%s" % (cfg["user"], cfg["host"], path)


def tail(text, n=3):
    return " | ".join([x for x in text.strip().splitlines() if x][-n:])


# ---------------------------------------------------------------- authline
def authline(cfg):
    pub_file = cfg["key"] + ".pub"
    try:
        pub = open(pub_file, encoding="utf-8").read().strip()
    except OSError:
        raise ConfigError("public key %s not found. Generate the key first (lab.sh replica install does it)." % pub_file)
    if "\n" in pub or not PUB_RE.match(pub):
        raise ConfigError("%s is not a single ssh-ed25519 public key line" % pub_file)
    key = " ".join(pub.split()[:2]) + " k8s-lab-replica"
    cmd = "%s%s" % (cfg["rrsync"], "" if cfg["allow_delete"] else " -no-del")
    cmd += " " + cfg["remote_dir_abs"]
    opts = ["restrict"]
    if cfg["from_cidr"]:
        opts.append('from="%s"' % cfg["from_cidr"])
    opts.append('command="%s"' % cmd)
    return ",".join(opts) + " " + key


# ---------------------------------------------------------------- stamp / freshness
def read_stamp(cfg):
    tmp = tempfile.mkdtemp(prefix="lab-replica-")
    try:
        argv = [cfg["rsync_bin"], "-e", rsync_shell(cfg), "--timeout=%s" % cfg["io_timeout"], remote(cfg, STAMP), tmp + "/"]
        rc, out, err = run(argv, timeout=cfg["io_timeout"] + 30)
        if rc != 0:
            return None, "replica not reachable or no stamp yet (rsync exit %d: %s)" % (rc, tail(err))
        try:
            return json.load(open(os.path.join(tmp, STAMP), encoding="utf-8")), ""
        except (OSError, ValueError) as e:
            return None, "stamp unreadable: %s" % e
    finally:
        for f in os.listdir(tmp):
            os.unlink(os.path.join(tmp, f))
        os.rmdir(tmp)


def freshness(cfg, stamp):
    """Returns (ok, age_minutes, message)."""
    if not stamp or not isinstance(stamp.get("finished"), (int, float)):
        return False, None, "no valid stamp"
    age = (now(cfg) - float(stamp["finished"])) / 60.0
    limit = float(cfg["max_age_min"])
    if age < -5:
        return False, age, "stamp lies %.0f min in the future (clock?)" % -age
    if age > limit:
        return False, age, "last mirror %.0f min ago, limit %.0f min" % (age, limit)
    return True, age, "last mirror %.0f min ago (limit %.0f min)" % (age, limit)


# ---------------------------------------------------------------- file lists
def is_excluded(rel, cfg):
    return any(rel == e or rel.startswith(e.rstrip("/") + "/") for e in cfg["exclude"])


def list_files(cfg, older_than=None):
    """Relative file paths below data_dir. With older_than only files whose mtime is older (stable files)."""
    root = cfg["data_dir"]
    out, size = [], 0
    for d, dirs, files in os.walk(root):
        rel_d = os.path.relpath(d, root)
        rel_d = "" if rel_d == "." else rel_d
        dirs[:] = [x for x in dirs if not is_excluded(os.path.join(rel_d, x), cfg)]
        for f in files:
            rel = os.path.join(rel_d, f)
            if is_excluded(rel, cfg):
                continue
            try:
                st = os.lstat(os.path.join(d, f))
            except OSError:
                continue
            if older_than is not None and st.st_mtime >= older_than:
                continue
            out.append(rel)
            size += st.st_size
    return sorted(out), size


# ---------------------------------------------------------------- commands
def cmd_mirror(cfg):
    if not os.path.isdir(cfg["data_dir"]):
        print("FAIL: data dir %s does not exist" % cfg["data_dir"], file=sys.stderr)
        return 1
    started = now(cfg)
    argv = [cfg["rsync_bin"], "-a", "--partial", "--timeout=%s" % cfg["io_timeout"], "-e", rsync_shell(cfg)]
    if cfg["allow_delete"]:
        argv.append("--delete-delay")
    for e in cfg["exclude"]:
        argv.append("--exclude=/%s" % e.strip("/"))
    argv += [cfg["data_dir"].rstrip("/") + "/", remote(cfg, "data/")]
    rc, out, err = run(argv)
    # 24 = source files vanished during the transfer (rustfs is live): fine, the next run picks the rest up.
    if rc not in (0, 24):
        print("FAIL: rsync exit %d: %s" % (rc, tail(err)), file=sys.stderr)
        return 1
    files, size = list_files(cfg)
    finished = now(cfg)
    stamp = {"started": started, "finished": finished, "files": len(files), "bytes": size}
    tmp = tempfile.mkdtemp(prefix="lab-replica-")
    try:
        p = os.path.join(tmp, STAMP)
        json.dump(stamp, open(p, "w", encoding="utf-8"))
        rc, out, err = run([cfg["rsync_bin"], "-e", rsync_shell(cfg), "--timeout=%s" % cfg["io_timeout"], p, remote(cfg, STAMP)])
        if rc != 0:
            print("FAIL: stamp upload exit %d: %s" % (rc, tail(err)), file=sys.stderr)
            return 1
    finally:
        for f in os.listdir(tmp):
            os.unlink(os.path.join(tmp, f))
        os.rmdir(tmp)
    print("OK: mirrored %d files, %d bytes (rsync exit %d)" % (len(files), size, rc))
    return 0


def checksum_diff(cfg, stamp):
    """Dry-run rsync with checksums over all files older than the last mirror start. Returns (diffs, checked)."""
    files, _ = list_files(cfg, older_than=float(stamp["started"]))
    tmp = tempfile.mkdtemp(prefix="lab-replica-")
    try:
        lst = os.path.join(tmp, "files")
        with open(lst, "w", encoding="utf-8") as fh:
            fh.write("".join(f + "\n" for f in files))
        argv = [cfg["rsync_bin"], "-rnc", "--itemize-changes", "--timeout=%s" % cfg["io_timeout"], "-e", rsync_shell(cfg),
                "--files-from=" + lst, cfg["data_dir"].rstrip("/") + "/", remote(cfg, "data/")]
        rc, out, err = run(argv)
        if rc not in (0, 23, 24):
            return None, len(files), "rsync exit %d: %s" % (rc, tail(err))
        diffs = [l for l in out.splitlines() if len(l) > 1 and l[0] in "<>" and l[1] == "f"]
        return diffs, len(files), ""
    finally:
        for f in os.listdir(tmp):
            os.unlink(os.path.join(tmp, f))
        os.rmdir(tmp)


def cmd_status(cfg, as_json=False):
    stamp, why = read_stamp(cfg)
    if stamp is None:
        res = {"ok": False, "age_min": None, "detail": why}
    else:
        ok, age, msg = freshness(cfg, stamp)
        res = {"ok": ok, "age_min": None if age is None else round(age, 1), "detail": msg}
    if as_json:
        print(json.dumps(res))
    else:
        print(("OK: " if res["ok"] else "FAIL: ") + res["detail"])
    return 0 if res["ok"] else 1


def cmd_verify(cfg):
    stamp, why = read_stamp(cfg)
    if stamp is None:
        print("FAIL: %s" % why)
        return 1
    ok, age, msg = freshness(cfg, stamp)
    print(("OK: " if ok else "FAIL: ") + "freshness: " + msg)
    diffs, checked, why = checksum_diff(cfg, stamp)
    if diffs is None:
        print("FAIL: checksum run failed: %s" % why)
        return 1
    if diffs:
        print("FAIL: %d of %d files differ or are missing on the replica (first: %s)" % (len(diffs), checked, diffs[0].strip()))
        return 1
    print("OK: checksums equal for %d files older than the last mirror start" % checked)
    return 0 if ok else 1


def cmd_preflight(cfg, install):
    bad = 0

    def ok(m):
        print("OK:      " + m)

    def miss(m):
        nonlocal bad
        bad += 1
        print("MISSING: " + m)

    for tool in (cfg["ssh_bin"], cfg["rsync_bin"]):
        rc, _, _ = run([tool, "--version"] if "ssh" not in tool else [tool, "-V"])
        (ok if rc != 127 else miss)("%s on this machine" % tool if rc != 127 else
                                    "%s is not installed on this machine (sudo apt install openssh-client rsync)" % tool)
    key = cfg["install_key"] if install else cfg["key"]
    if not key or not os.path.isfile(key):
        miss("%s key %s not found%s" % ("install" if install else "replica", key or "(not configured)",
                                         "" if install else " (lab.sh replica install generates it)"))
        return 1
    mode = os.stat(key).st_mode & 0o077
    (miss if mode else ok)("key %s is private (mode 0600)" % key if not mode else "key %s is readable by others (chmod 600 it)" % key)
    if not os.path.isfile(cfg["known_hosts"]) or not open(cfg["known_hosts"], encoding="utf-8").read().strip():
        miss("host key not pinned: %s is empty. Run: python3 scripts/lab-replica.py hostkey --config <cfg>, compare the "
             "fingerprint on the replica (ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub) and put the line into "
             "backup_replica_host_key" % cfg["known_hosts"])
        return 1
    ok("host key pinned")
    if install:
        base = [cfg["ssh_bin"]] + ssh_opts(cfg, key) + ["%s@%s" % (cfg["user"], cfg["host"])]
        rc, out, err = run(base + ["true"], timeout=cfg["connect_timeout"] + 20)
        if rc != 0:
            miss("ssh BatchMode to %s@%s failed (%s). Is the machine on, is the install key authorized, does the "
                 "pinned host key match?" % (cfg["user"], cfg["host"], tail(err) or "exit %d" % rc))
            return 1
        ok("ssh BatchMode to %s@%s" % (cfg["user"], cfg["host"]))
        files, size = list_files(cfg)
        need = max(int(size * float(cfg["min_free_factor"])), int(cfg["min_free_mib"]) * 2**20)
        script = "command -v rsync >/dev/null && echo RSYNC=yes || echo RSYNC=no; " \
                 "[ -x %(rr)s ] && echo RRSYNC=%(rr)s; " \
                 "d=%s; mkdir -p \"$d\" 2>/dev/null; df -Pk \"$d\" | awk 'NR==2{print \"FREEKB=\" $4}'; " \
                 "[ -w \"$d\" ] && echo WRITABLE=yes || echo WRITABLE=no"
        script = script.replace("%(rr)s", shlex.quote(cfg["rrsync"])) % shlex.quote(cfg["remote_dir_abs"])
        rc, out, err = run(base + [script], timeout=60)
        kv = dict(l.split("=", 1) for l in out.splitlines() if "=" in l)
        (ok if kv.get("RSYNC") == "yes" else miss)("rsync on the replica" if kv.get("RSYNC") == "yes" else
                                                  "rsync is missing on the replica (sudo apt install rsync, once, as an admin)")
        if kv.get("RRSYNC"):
            ok("rrsync on the replica: %s" % kv["RRSYNC"])
        else:
            miss("rrsync (%s) is missing on the replica (comes with the rsync package of Ubuntu 24.04: sudo apt install rsync)" % cfg["rrsync"])
        (ok if kv.get("WRITABLE") == "yes" else miss)("replica dir %s writable" % cfg["remote_dir_abs"] if kv.get("WRITABLE") == "yes"
                                                    else "replica dir %s is not writable for %s" % (cfg["remote_dir_abs"], cfg["user"]))
        try:
            free = int(kv.get("FREEKB", "0")) * 1024
        except ValueError:
            free = 0
        if free < need:
            miss("not enough free space on the replica: %d MiB free, %d MiB needed (data %d MiB x %s)" % (
                free // 2**20, need // 2**20, size // 2**20, cfg["min_free_factor"]))
        else:
            ok("free space on the replica: %d MiB (need %d MiB)" % (free // 2**20, need // 2**20))
    else:
        rc, out, err = run([cfg["rsync_bin"], "-e", rsync_shell(cfg), "--timeout=%s" % cfg["io_timeout"], "--list-only",
                            remote(cfg, "")], timeout=cfg["io_timeout"] + 30)
        if rc != 0:
            miss("replica key does not work (rsync exit %d: %s). Run: lab.sh replica install" % (rc, tail(err)))
        else:
            ok("restricted replica key works (rsync listing)")
    if bad:
        print("PREFLIGHT FAILED: %d item(s) missing." % bad)
        return 1
    print("PREFLIGHT OK")
    return 0


def cmd_restore(cfg, target):
    if not target:
        raise ConfigError("restore needs --target DIR (a new or empty directory)")
    t = os.path.realpath(os.path.expanduser(target))
    d = os.path.realpath(cfg["data_dir"])
    if t == d or t.startswith(d + os.sep) or d.startswith(t + os.sep):
        raise ConfigError("--target %s overlaps the live data dir %s. Restore into a separate directory." % (t, d))
    if os.path.exists(t) and (not os.path.isdir(t) or os.listdir(t)):
        raise ConfigError("--target %s exists and is not an empty directory" % t)
    stamp, why = read_stamp(cfg)
    if stamp is None:
        print("FAIL: no usable freshness stamp on the replica (%s), nothing trustworthy to restore" % why, file=sys.stderr)
        return 1
    os.makedirs(t, exist_ok=True)
    argv = [cfg["rsync_bin"], "-a", "--timeout=%s" % cfg["io_timeout"], "-e", rsync_shell(cfg), remote(cfg, "data/"), t + "/"]
    rc, out, err = run(argv)
    if rc != 0:
        print("FAIL: rsync exit %d: %s" % (rc, tail(err)), file=sys.stderr)
        return 1
    argv = [cfg["rsync_bin"], "-rnc", "--itemize-changes", "--timeout=%s" % cfg["io_timeout"], "-e", rsync_shell(cfg),
            remote(cfg, "data/"), t + "/"]
    rc, out, err = run(argv)
    diffs = [l for l in out.splitlines() if len(l) > 1 and l[0] in "<>" and l[1] == "f"]
    if rc != 0 or diffs:
        print("FAIL: checksum compare of the restored copy: rc %d, %d differences" % (rc, len(diffs)), file=sys.stderr)
        return 1
    print("OK: replica copy (mirror finished %s) restored to %s and checksummed" % (stamp.get("finished"), t))
    return 0


def cmd_hostkey(cfg):
    rc, out, err = run(["ssh-keyscan", "-t", "ed25519", "-p", str(cfg["port"]), "-T", str(cfg["connect_timeout"]), cfg["host"]],
                       timeout=cfg["connect_timeout"] + 10)
    line = next((l for l in out.splitlines() if l and not l.startswith("#")), "")
    if rc != 0 or not line:
        print("FAIL: no host key from %s:%s (%s)" % (cfg["host"], cfg["port"], tail(err) or "empty answer"), file=sys.stderr)
        return 1
    rc2, fp, err2 = run(["ssh-keygen", "-lf", "-"], input_text=line + "\n")
    print(line)
    print("# fingerprint: " + fp.strip(), file=sys.stderr)
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("cmd", choices=["preflight", "authline", "mirror", "verify", "status", "hostkey", "restore"])
    ap.add_argument("--config", required=True)
    ap.add_argument("--install", action="store_true")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--target", default="")
    a = ap.parse_args(argv)
    try:
        cfg = load_config(a.config)
        cfg["remote_dir_abs"] = cfg["remote_dir"] if cfg["remote_dir"].startswith("/") else "/home/%s/%s" % (cfg["user"], cfg["remote_dir"])
        if a.cmd == "authline":
            print(authline(cfg))
            return 0
        return {"mirror": lambda: cmd_mirror(cfg), "verify": lambda: cmd_verify(cfg),
                "status": lambda: cmd_status(cfg, a.json), "hostkey": lambda: cmd_hostkey(cfg),
                "preflight": lambda: cmd_preflight(cfg, a.install), "restore": lambda: cmd_restore(cfg, a.target)}[a.cmd]()
    except ConfigError as e:
        print("CONFIG ERROR: %s" % e, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
