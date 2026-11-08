#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
# Tests for the backup replica of issue #3 (scripts/lab-replica.py), without a network and without a replica:
# rsync, ssh, ssh-keyscan and ssh-keygen are small stubs on the PATH; the "replica" is a directory.
#   1. config errors (missing key, bad host, bad user, bad path) end with exit 2 and a clear message
#   2. authline: restrict, from=, rrsync with -no-del (default) and without it, bad public key refused
#   3. mirror: files and stamp arrive, exclude works, "vanished files" (24) is fine, a failing rsync is not and
#      leaves the old stamp alone
#   4. status/freshness: fresh, too old, no stamp, stamp in the future, JSON form
#   5. verify: green, corrupt file, missing file, a file newer than the stamp is not compared
#   6. preflight: green, no rsync here, key too open, host key not pinned, unreachable, no rsync/rrsync/space on the replica
#   7. the repo: rendered values come from ONE group_vars file, the role and playbook exist, syntax check
# Usage: bash tests/replica-tests.sh [repo root]
set -u
export PYTHONDONTWRITEBYTECODE=1
R=$(cd "${1:-$(dirname "${BASH_SOURCE[0]}")/..}" && pwd -P)
mkdir -p "$HOME/.cache/lab-sh-tests"
T=$(mktemp -d -p "$HOME/.cache/lab-sh-tests")
# shellcheck disable=SC2064
trap "rm -rf '$T'" EXIT
fail=0
n=0
ok() { n=$((n + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else echo "FAIL $1 (is '$2', want '$3')"; fail=$((fail + 1)); fi; }
has() { grep -Fq -- "$2" "$3"; local r=$?; ok "$1" "$r" 0; [ "$r" = 0 ] || sed -n "1,4p" "$3" 2>/dev/null | sed "s/^/       | /"; }
hasnot() { ! grep -Fq -- "$2" "$3"; ok "$1" "$?" 0; }
LR="$R/scripts/lab-replica.py"

# ---------- stubs
mkdir -p "$T/bin" "$T/remote" "$T/data/bucket-a/objx" "$T/data/bucket-b" "$T/data/.rustfs.sys/tmp"
cat > "$T/bin/rsync" << 'PY'
#!/usr/bin/env python3
import os, shutil, sys
args = sys.argv[1:]
rr = os.environ["FAKE_REMOTE"]
fail = int(os.environ.get("FAKE_RSYNC_RC", "0"))
if args == ["--version"]:
    print("rsync version stub"); sys.exit(0)
files_from, pos, dry, delete, listonly, i = None, [], False, False, False, 0
while i < len(args):
    a = args[i]
    if a == "-e":
        i += 2; continue
    if a.startswith("--files-from="):
        files_from = a.split("=", 1)[1]
    elif a == "--delete-delay":
        delete = True
    elif a == "--list-only":
        listonly = True
    elif a.startswith("-") and not a.startswith("--") and "n" in a:
        dry = True
    elif not a.startswith("-"):
        pos.append(a)
    i += 1
def rpath(p):
    return os.path.join(rr, p.split(":", 1)[1])
open(os.environ["FAKE_LOG"], "a").write(" ".join(args) + "\n")
if listonly:
    print("drwx------ .") if os.path.isdir(rr) and not fail else sys.exit(fail or 12)
    sys.exit(0)
if fail and fail not in (23, 24):
    sys.stderr.write("rsync: stub failure\n"); sys.exit(fail)
src, dst = pos
if ":" in src and os.path.isdir(rpath(src)):   # download the tree
    if dry:
        sys.exit(fail)
    shutil.copytree(rpath(src), dst, dirs_exist_ok=True); sys.exit(fail)
if ":" in src:                       # download one file
    shutil.copy(rpath(src), os.path.join(dst, os.path.basename(rpath(src)))); sys.exit(0)
if dry and files_from:               # checksum compare
    for rel in open(files_from).read().split("\n"):
        if not rel: continue
        d = os.path.join(rpath(dst), rel)
        if not os.path.exists(d):
            print(">f+++++++++ " + rel)
        elif open(d, "rb").read() != open(os.path.join(src, rel), "rb").read():
            print(">fc.T...... " + rel)
    sys.exit(fail)
if os.path.isdir(src):               # mirror
    d = rpath(dst); os.makedirs(d, exist_ok=True)
    for root, dirs, fs in os.walk(src):
        for f in fs:
            rel = os.path.relpath(os.path.join(root, f), src)
            if any(a == "--exclude=/" + rel.split("/")[0] + "/tmp" or a == "--exclude=/" + os.path.dirname(rel) for a in args if a.startswith("--exclude=")) or rel.startswith(".rustfs.sys/tmp"):
                continue
            os.makedirs(os.path.dirname(os.path.join(d, rel)), exist_ok=True)
            shutil.copy(os.path.join(root, f), os.path.join(d, rel))
    if delete:
        for root, dirs, fs in os.walk(d):
            for f in fs:
                if not os.path.exists(os.path.join(src, os.path.relpath(os.path.join(root, f), d))):
                    os.unlink(os.path.join(root, f))
    sys.exit(fail)
shutil.copy(src, rpath(dst))         # upload one file (stamp)
PY
cat > "$T/bin/ssh" << 'PY'
#!/usr/bin/env python3
import os, sys
a = sys.argv[1:]
if a == ["-V"]:
    sys.stderr.write("OpenSSH_stub\n"); sys.exit(0)
rc = int(os.environ.get("FAKE_SSH_RC", "0"))
if rc:
    sys.stderr.write("ssh: connect to host: No route to host\n"); sys.exit(rc)
if a[-1] != "true":
    print(os.environ.get("FAKE_SSH_KV", "").replace(";", "\n"))
PY
cat > "$T/bin/ssh-keyscan" << 'SH'
#!/usr/bin/env bash
echo "# stub"
echo "lab.example ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIStubStubStubStubStubStubStubStubStubStubStub"
SH
cat > "$T/bin/ssh-keygen" << 'SH'
#!/usr/bin/env bash
cat > /dev/null; echo "256 SHA256:stubfingerprint lab.example (ED25519)"
SH
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH" FAKE_LOG="$T/rsync.log" FAKE_REMOTE="$T/remote/home/user/k8s-lab-replica"
mkdir -p "$FAKE_REMOTE"
printf 'one\n' > "$T/data/bucket-a/objx/part.dat"
printf 'two\n' > "$T/data/bucket-b/xl.meta"
printf 'tmp\n' > "$T/data/.rustfs.sys/tmp/x"
printf 'host ssh-ed25519 AAAA\n' > "$T/known_hosts"
printf 'PRIVATE\n' > "$T/key"; chmod 600 "$T/key"
printf 'PRIVATE\n' > "$T/ikey"; chmod 600 "$T/ikey"
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIexample comment-ignored\n' > "$T/key.pub"

# mkcfg OUTFILE [key=json-value ...]
mkcfg() {
  local out=$1; shift
  python3 - "$out" "$@" << PY
import json, sys
c = {"host": "lab.example", "user": "replica", "port": 22, "key": "$T/key", "install_key": "$T/ikey",
     "known_hosts": "$T/known_hosts", "remote_dir": "/home/user/k8s-lab-replica", "data_dir": "$T/data",
     "max_age_min": 180, "from_cidr": "192.0.2.0/24", "allow_delete": False, "exclude": [".rustfs.sys/tmp"],
     "rsync_bin": "rsync", "ssh_bin": "ssh"}
for kv in sys.argv[2:]:
    k, v = kv.split("=", 1)
    c[k] = json.loads(v)
json.dump(c, open(sys.argv[1], "w"))
PY
}
rc() { "$@" > "$T/out" 2>&1; echo $?; }
C="$T/cfg.json"
mkcfg "$C"

echo "== config errors"
mkcfg "$T/c1.json" 'host=""'
ok "empty host: exit 2" "$(rc python3 "$LR" status --config "$T/c1.json")" 2
has "empty host: message" "config is missing: host" "$T/out"
mkcfg "$T/c2.json" 'host="a;rm -rf"'
ok "bad host: exit 2" "$(rc python3 "$LR" status --config "$T/c2.json")" 2
mkcfg "$T/c3.json" 'user="Root User"'
ok "bad user: exit 2" "$(rc python3 "$LR" status --config "$T/c3.json")" 2
mkcfg "$T/c4.json" 'remote_dir="/home/user/../../etc"'
ok "path with ..: exit 2" "$(rc python3 "$LR" status --config "$T/c4.json")" 2
ok "no config file: exit 2" "$(rc python3 "$LR" status --config "$T/none.json")" 2

echo "== authline"
ok "authline exit 0" "$(rc python3 "$LR" authline --config "$C")" 0
has "restrict" "restrict," "$T/out"
has "from=" 'from="192.0.2.0/24"' "$T/out"
has "rrsync with -no-del and the absolute dir" 'command="/usr/bin/rrsync -no-del /home/user/k8s-lab-replica"' "$T/out"
has "key type and tag, comment replaced" "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIexample k8s-lab-replica" "$T/out"
hasnot "the old comment is gone" "comment-ignored" "$T/out"
mkcfg "$T/c5.json" 'allow_delete=true' 'from_cidr=""'
python3 "$LR" authline --config "$T/c5.json" > "$T/out" 2>&1
hasnot "allow_delete: no -no-del" "-no-del" "$T/out"
hasnot "no from_cidr: no from=" "from=" "$T/out"
printf 'ssh-rsa AAAA x\n' > "$T/key.pub"
ok "an rsa key is refused: exit 2" "$(rc python3 "$LR" authline --config "$C")" 2
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIexample\ncommand="evil" ssh-ed25519 BBBB\n' > "$T/key.pub"
ok "two lines are refused: exit 2" "$(rc python3 "$LR" authline --config "$C")" 2
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIexample comment-ignored\n' > "$T/key.pub"

echo "== mirror"
ok "mirror exit 0" "$(rc python3 "$LR" mirror --config "$C")" 0
has "mirror says OK with the count" "OK: mirrored 2 files" "$T/out"
ok "object arrived" "$(cat "$FAKE_REMOTE/data/bucket-a/objx/part.dat")" one
ok "excluded file did not arrive" "$([ -e "$FAKE_REMOTE/data/.rustfs.sys/tmp/x" ] && echo yes || echo no)" no
has "stamp is there" '"files": 2' "$FAKE_REMOTE/mirror-stamp.json"
has "rsync uses BatchMode and the pinned host key" "StrictHostKeyChecking=yes" "$T/rsync.log"
hasnot "no --delete without allow_delete" "--delete" "$T/rsync.log"
FAKE_RSYNC_RC=24 python3 "$LR" mirror --config "$C" > "$T/out" 2>&1; ok "vanished files (24): exit 0" "$?" 0
cp "$FAKE_REMOTE/mirror-stamp.json" "$T/stamp.before"
sleep 1
FAKE_RSYNC_RC=5 python3 "$LR" mirror --config "$C" > "$T/out" 2>&1; ok "rsync failure: exit 1" "$?" 1
has "rsync failure: message" "FAIL: rsync exit 5" "$T/out"
ok "failed mirror leaves the old stamp" "$(cmp -s "$T/stamp.before" "$FAKE_REMOTE/mirror-stamp.json" && echo same || echo changed)" same
mkcfg "$T/c6.json" 'allow_delete=true'
printf 'stale\n' > "$FAKE_REMOTE/data/bucket-b/stale"
python3 "$LR" mirror --config "$T/c6.json" > "$T/out" 2>&1
ok "allow_delete: stale file removed" "$([ -e "$FAKE_REMOTE/data/bucket-b/stale" ] && echo yes || echo no)" no
has "allow_delete passes --delete-delay" "--delete-delay" "$T/rsync.log"
ok "no data dir: exit 1" "$(rc python3 "$LR" mirror --config <(mkcfg /dev/stdout 'data_dir="/nonexistent"'))" 1

echo "== status and freshness"
ok "fresh: exit 0" "$(rc python3 "$LR" status --config "$C")" 0
has "fresh: message" "OK: last mirror" "$T/out"
python3 "$LR" status --config "$C" --json > "$T/out"; has "json form" '"ok": true' "$T/out"
mkcfg "$T/c7.json" "now=$(( $(date +%s) + 200 * 60 ))"
ok "too old: exit 1" "$(rc python3 "$LR" status --config "$T/c7.json")" 1
has "too old: message" "limit 180 min" "$T/out"
mkcfg "$T/c8.json" "now=$(( $(date +%s) - 3600 ))"
ok "stamp in the future: exit 1" "$(rc python3 "$LR" status --config "$T/c8.json")" 1
has "future: message" "future" "$T/out"
mv "$FAKE_REMOTE/mirror-stamp.json" "$T/stamp.keep"
ok "no stamp: exit 1" "$(rc python3 "$LR" status --config "$C")" 1
has "no stamp: message" "no stamp yet" "$T/out"
mv "$T/stamp.keep" "$FAKE_REMOTE/mirror-stamp.json"

echo "== verify"
touch -d '2 hours ago' "$T/data/bucket-a/objx/part.dat" "$T/data/bucket-b/xl.meta"
python3 "$LR" mirror --config "$C" > "$T/out" 2>&1
ok "verify green: exit 0" "$(rc python3 "$LR" verify --config "$C")" 0
has "verify green: checksum line" "checksums equal for 2 files" "$T/out"
printf 'BROKEN\n' > "$FAKE_REMOTE/data/bucket-a/objx/part.dat"
ok "corrupt replica file: exit 1" "$(rc python3 "$LR" verify --config "$C")" 1
has "corrupt: message names the count" "1 of 2 files differ" "$T/out"
printf 'one\n' > "$FAKE_REMOTE/data/bucket-a/objx/part.dat"
rm "$FAKE_REMOTE/data/bucket-b/xl.meta"
ok "missing replica file: exit 1" "$(rc python3 "$LR" verify --config "$C")" 1
printf 'two\n' > "$FAKE_REMOTE/data/bucket-b/xl.meta"
printf 'live write\n' > "$T/data/bucket-b/new-object"
ok "a file newer than the last mirror is not compared" "$(rc python3 "$LR" verify --config "$C")" 0
FAKE_RSYNC_RC=23 python3 "$LR" verify --config "$C" > "$T/out" 2>&1; ok "rsync 23 in the compare is tolerated" "$?" 0
FAKE_RSYNC_RC=5 python3 "$LR" verify --config "$C" > "$T/out" 2>&1; ok "unreachable replica in verify: exit 1" "$?" 1

echo "== restore (pull back into a new directory)"
ok "restore without --target: exit 2" "$(rc python3 "$LR" restore --config "$C")" 2
ok "target inside the live data dir: exit 2" "$(rc python3 "$LR" restore --config "$C" --target "$T/data/x")" 2
ok "target containing the live data dir: exit 2" "$(rc python3 "$LR" restore --config "$C" --target "$T")" 2
ok "non-empty target: exit 2" "$(rc python3 "$LR" restore --config "$C" --target "$T/data/bucket-a")" 2
ok "restore into a new dir: exit 0" "$(rc python3 "$LR" restore --config "$C" --target "$T/restored")" 0
has "restore says OK and names the target" "restored to" "$T/out"
ok "object is back" "$(cat "$T/restored/bucket-a/objx/part.dat")" one
FAKE_RSYNC_RC=5 python3 "$LR" restore --config "$C" --target "$T/restored2" > "$T/out" 2>&1; ok "rsync failure: exit 1" "$?" 1

echo "== preflight"
export FAKE_SSH_KV="RSYNC=yes;RRSYNC=/usr/bin/rrsync;FREEKB=99999999;WRITABLE=yes"
ok "preflight install green: exit 0" "$(rc python3 "$LR" preflight --install --config "$C")" 0
has "preflight prints PREFLIGHT OK" "PREFLIGHT OK" "$T/out"
has "preflight reports the rrsync path" "rrsync on the replica: /usr/bin/rrsync" "$T/out"
ok "preflight runtime green: exit 0" "$(rc python3 "$LR" preflight --config "$C")" 0
mkcfg "$T/p1.json" 'rsync_bin="rsync-not-installed"'
ok "no rsync here: exit 1" "$(rc python3 "$LR" preflight --install --config "$T/p1.json")" 1
has "no rsync here: message" "rsync-not-installed is not installed on this machine" "$T/out"
chmod 644 "$T/ikey"
ok "key too open: exit 1" "$(rc python3 "$LR" preflight --install --config "$C")" 1
has "key too open: message" "readable by others" "$T/out"
chmod 600 "$T/ikey"
: > "$T/known_hosts"
ok "host key not pinned: exit 1" "$(rc python3 "$LR" preflight --install --config "$C")" 1
has "not pinned: message tells how" "backup_replica_host_key" "$T/out"
printf 'host ssh-ed25519 AAAA\n' > "$T/known_hosts"
FAKE_SSH_RC=255 python3 "$LR" preflight --install --config "$C" > "$T/out" 2>&1; ok "unreachable: exit 1" "$?" 1
has "unreachable: message" "ssh BatchMode to replica@lab.example failed" "$T/out"
FAKE_SSH_KV="RSYNC=no;FREEKB=99999999;WRITABLE=yes" python3 "$LR" preflight --install --config "$C" > "$T/out" 2>&1; ok "no rsync/rrsync on the replica: exit 1" "$?" 1
has "no rsync on the replica: message" "rsync is missing on the replica" "$T/out"
has "no rrsync on the replica: message" "rrsync (/usr/bin/rrsync) is missing on the replica" "$T/out"
FAKE_SSH_KV="RSYNC=yes;RRSYNC=/usr/bin/rrsync;FREEKB=1;WRITABLE=yes" python3 "$LR" preflight --install --config "$C" > "$T/out" 2>&1; ok "no space: exit 1" "$?" 1
has "no space: message" "not enough free space on the replica" "$T/out"
FAKE_SSH_KV="RSYNC=yes;RRSYNC=/usr/bin/rrsync;FREEKB=99999999;WRITABLE=no" python3 "$LR" preflight --install --config "$C" > "$T/out" 2>&1; ok "not writable: exit 1" "$?" 1
FAKE_RSYNC_RC=12 python3 "$LR" preflight --config "$C" > "$T/out" 2>&1; ok "restricted key does not work: exit 1" "$?" 1
has "runtime preflight names the fix" "lab.sh replica install" "$T/out"
ok "hostkey prints the line" "$(rc python3 "$LR" hostkey --config "$C")" 0
has "hostkey: ed25519 line" "ssh-ed25519" "$T/out"
has "hostkey: fingerprint" "stubfingerprint" "$T/out"

echo "== the repo"
GV="$R/ansible/inventory/group_vars/all/backup_replica.yml"
has "group_vars: host in one place" "backup_replica_host:" "$GV"
has "group_vars: user in one place" "backup_replica_user:" "$GV"
has "group_vars: restricted key path" "backup_replica_key:" "$GV"
has "group_vars: delete off by default" "backup_replica_allow_delete: false" "$GV"
n_host=$(grep -rIl --exclude-dir='.*' --exclude-dir=docs --exclude-dir=tests --exclude-dir=public --exclude-dir=site -e 'replica-pc' "$R" | wc -l)
ok "the replica host name appears in ONE file outside docs and tests" "$n_host" 1
has "the role renders the config from the variables" "backup_replica_host" "$R/ansible/roles/backup_replica/templates/replica.json.j2"
has "the role pins the host key" "backup_replica_host_key" "$R/ansible/roles/backup_replica/templates/known_hosts.j2"
has "the playbook keeps the install key out of the repo" "backup_replica_install_key" "$R/ansible/backup-replica.yml"
if command -v ansible-playbook > /dev/null; then
  (cd "$R/ansible" && ansible-playbook --syntax-check backup-replica.yml > "$T/out" 2>&1); ok "backup-replica.yml syntax check" "$?" 0
else
  echo "SKIP: ansible-playbook is missing"
fi

echo
echo "$n checks, $fail failures"
[ "$fail" = 0 ]
