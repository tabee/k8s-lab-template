#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
# Tests for scripts/emergency-kit.sh (emergency kit, ADR 0025) with the real age and tar in a sandbox:
# a temporary HOME, a temporary repo root and a temporary "USB stick". Nothing outside the sandbox is read or written.
# age -p only reads the passphrase from the terminal, so the script runs under a pty (python3) that types it.
# Without age, python3, GNU tar or a tmpfs the suite prints SKIP and exits 0.
# Usage: bash tests/kit-tests.sh [repo root]
set -u
R=$(cd "${1:-$(dirname "${BASH_SOURCE[0]}")/..}" && pwd -P)
for w in age python3 tar sha256sum shred; do
  command -v "$w" > /dev/null 2>&1 || { echo "SKIP: $w is missing"; exit 0; }
done
tar --version 2> /dev/null | grep -q 'GNU tar' || { echo "SKIP: GNU tar is missing"; exit 0; }
[ "$(stat -f -c %T /dev/shm 2> /dev/null)" = tmpfs ] || { echo "SKIP: /dev/shm is not a tmpfs"; exit 0; }
mkdir -p "$HOME/.cache/lab-sh-tests"
T=$(mktemp -d -p "$HOME/.cache/lab-sh-tests")
SHM=$(mktemp -d -p /dev/shm kit-test.XXXXXX)
trap 'rm -rf "$T" "$SHM"' EXIT
KIT=$R/scripts/emergency-kit.sh
fail=0
n=0
rc=0
ok() { n=$((n + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else echo "FAIL $1 (is '$2', want '$3')"; fail=$((fail + 1)); fi; }
has() { grep -Fq -- "$2" "$3"; ok "$1" "$?" 0; }
hasnt() { grep -Fq -- "$2" "$3"; ok "$1" "$?" 1; }

# The pty driver: runs a command on a terminal and types $KIT_PASS at every passphrase prompt.
cat > "$T/ptyrun.py" << 'PY'
import os, pty, re, select, sys
pw = os.environ["KIT_PASS"]
pid, fd = pty.fork()
if pid == 0:
    os.execvp(sys.argv[1], sys.argv[1:])
buf = b""
seen = 0
out = b""
while True:
    r, _, _ = select.select([fd], [], [], 30)
    if not r:
        break
    try:
        d = os.read(fd, 4096)
    except OSError:
        break
    if not d:
        break
    out += d
    buf += d
    if re.search(rb"(?i)passphrase[^\n]*: ?$", buf[seen:]):
        os.write(fd, (pw + "\n").encode())
        seen = len(buf)
_, st = os.waitpid(pid, 0)
sys.stdout.write(out.decode(errors="replace").replace("\r\n", "\n"))
sys.exit(os.waitstatus_to_exitcode(st))
PY

H=$T/home
REPO=$T/repo
USB=$T/usb
PASS=correct-horse-test
SECRET_TAG=DUMMYSECRET

# Fixture: every required file with a recognisable dummy content, plus a few optional ones.
required_paths() {
  awk -F'|' '$3 == "yes" && $4 == "home" { print $5 }' <<< "$(sed -n "/^kit_table() {/,/^}/p" "$KIT" | sed -n "/<< 'EOF'/,/^EOF/p" | sed '1d;$d')"
}
mkfix() { # mkfix HOME REPO
  local home=$1 repo=$2 p
  rm -rf "$home" "$repo"
  mkdir -p "$home" "$repo/infra/envs/local" "$home/.ssh" "$home/.config/k8s-lab" "$home/.config/sops/age" "$home/.config/rustfs"
  while IFS= read -r p; do
    mkdir -p "$home/$(dirname "$p")"
    printf '%s-%s\n' "$SECRET_TAG" "$p" > "$home/$p"
  done < <(required_paths)
  printf '%s 2026-01-01T00:00:00Z test\n' "0123456789abcdef0123456789abcdef01234567" > "$home/.config/k8s-lab/trusted-head"
  printf 'github_repo_url: ssh://git@github.com/example/lab.git\nssh_key: ~/.ssh/vmkey\nsource: github\n' > "$repo/infra/envs/local/lab.local.yaml"
  printf '%s-vmkey\n' "$SECRET_TAG" > "$home/.ssh/vmkey"
  printf 'ssh-ed25519 AAAApub vm\n' > "$home/.ssh/vmkey.pub"
  printf '%s-notes\n' "$SECRET_TAG" > "$home/.config/k8s-lab/notes-one.passwort"
  printf '%s-deploy\n' "$SECRET_TAG" > "$home/.ssh/argocd-k8s-lab"
  printf '%s-break\n' "$SECRET_TAG" > "$home/.config/k8s-lab/break-glass-age.txt"
  printf '%s-server-wg\n' "$SECRET_TAG" > "$home/.config/k8s-lab/wireguard-server.key"
  printf '%s-client-wg\n' "$SECRET_TAG" > "$home/.config/k8s-lab/wireguard-client.key"
  printf '%s-heartbeat\n' "$SECRET_TAG" > "$home/.config/k8s-lab/alert-heartbeat.sops.yaml"
  chmod 600 "$home/.ssh/"* "$home/.config/k8s-lab/"* 2> /dev/null
  chmod 700 "$home/.ssh" "$home/.config/k8s-lab"
}
# kit HOME REPO PASS ARGS...: the kit script under a pty; the output lands in $T/out
kit() {
  local home=$1 repo=$2 pass=$3
  shift 3
  HOME=$home LAB_KIT_REPO=$repo XDG_RUNTIME_DIR=$SHM KIT_PASS=$pass python3 "$T/ptyrun.py" bash "$KIT" "$@" > "$T/out" 2>&1
}
nosecret() { grep -Fq -- "$SECRET_TAG" "$T/out"; ok "$1: no secret content in the output" "$?" 1; }

echo "== the table agrees with the secrets map (one place per value)"
while IFS= read -r name; do
  case $name in argocd-admin | kubeconfig) continue ;; esac # derived from the cluster, not part of the kit
  rc=0; sed -n "/<< 'EOF'/,/^EOF/p" "$KIT" | grep -q "^$name|" || rc=$?
  ok "secrets.yml entry '$name' is in the kit table" "$rc" 0
done < <(sed -n 's/^  - name: \(.*\)$/\1/p' "$R/ansible/inventory/group_vars/all/secrets.yml")
for tail in .config/sops/age/keys.txt .config/k8s-lab/break-glass-age.txt .ssh/argocd-k8s-lab .ssh/argocd-k8s-lab-secrets .ssh/k8s-lab-replica \
  .config/k8s-lab/replica_known_hosts .config/k8s-lab/replica.json .config/k8s-lab/alert.json .config/k8s-lab/alert-matrix.sops.yaml \
  .config/k8s-lab/acme-dns01.token .config/k8s-lab/lab-ca.crt .ssh/id_ed25519 .config/rustfs/rustfs.env; do
  grep -rqF -- "$tail" "$R/ansible/inventory/group_vars/all" "$R/scripts/lab.sh"; ok "path $tail is the one the lab itself uses" "$?" 0
done

echo "== help and arguments"
bash "$KIT" --help > "$T/out" 2>&1; ok "--help: exit 0" "$?" 0
has "--help: names the three actions" "kit import DIR" "$T/out"
bash "$KIT" > "$T/out" 2>&1; ok "no action: usage error, exit 2" "$?" 2
bash "$KIT" bogus "$USB" > "$T/out" 2>&1; ok "unknown action: usage error, exit 2" "$?" 2
bash "$R/scripts/lab.sh" kit --help > "$T/out" 2>&1; ok "lab.sh kit --help: exit 0" "$?" 0
has "lab.sh kit --help: the kit usage" "Emergency kit" "$T/out"

echo "== export refuses what would be wrong"
mkfix "$H" "$REPO"; mkdir -p "$USB"
kit "$H" "$REPO" "$PASS" export "$T/not-there"; ok "DIR does not exist: exit 1" "$?" 1
has "DIR does not exist: named" "is not a directory" "$T/out"
mkdir -p "$REPO/stick"
kit "$H" "$REPO" "$PASS" export "$REPO/stick"; ok "DIR inside the repo: exit 1" "$?" 1
has "DIR inside the repo: named" "inside the repo" "$T/out"
mkdir -p "$T/worktree/stick"; git init -q "$T/worktree" 2> /dev/null
kit "$H" "$REPO" "$PASS" export "$T/worktree/stick"; ok "DIR inside any Git work tree: exit 1" "$?" 1
has "DIR inside any Git work tree: named" "inside a Git work tree" "$T/out"
mkdir -p "$T/ro"; chmod 500 "$T/ro"
if [ "$(id -u)" != 0 ]; then
  kit "$H" "$REPO" "$PASS" export "$T/ro"; ok "DIR not writable: exit 1" "$?" 1
  has "DIR not writable: named" "is not writable" "$T/out"
fi
chmod 700 "$T/ro"
ok "nothing was written in any refused target" "$(find "$REPO/stick" "$T/worktree/stick" "$T/ro" -type f | wc -l)" 0

echo "== a missing required file is an error"
rm -f "$H/.config/k8s-lab/gitea-k3s-lab-admin.pw" "$H/.config/rustfs/rustfs.env"
kit "$H" "$REPO" "$PASS" export "$USB"; ok "missing required files: exit 1" "$?" 1
has "missing required: the first is listed" ".config/k8s-lab/gitea-k3s-lab-admin.pw" "$T/out"
has "missing required: the second is listed" ".config/rustfs/rustfs.env" "$T/out"
ok "missing required: nothing was written" "$(find "$USB" -type f | wc -l)" 0
nosecret "missing required"
kit "$H" "$REPO" "$PASS" export "$USB" --allow-missing; ok "--allow-missing: exit 0" "$?" 0
has "--allow-missing: the warning" "INCOMPLETE" "$T/out"
has "--allow-missing: the manifest says so" "M	must	yes" "$USB/k8s-lab-kit.manifest"
kit "$H" "$REPO" "$PASS" verify "$USB"; ok "verify of an incomplete kit: exit 0" "$?" 0
has "verify of an incomplete kit: warns" "INCOMPLETE KIT" "$T/out"
rm -rf "$USB"; mkdir -p "$USB"

echo "== export, complete"
mkfix "$H" "$REPO"
kit "$H" "$REPO" "$PASS" export "$USB"; ok "export: exit 0" "$?" 0
nosecret "export"
has "export: names the archive" "k8s-lab-kit.tar.age" "$T/out"
has "export: warns about the same filesystem as HOME" "same filesystem as your home" "$T/out"
for f in k8s-lab-kit.tar.age k8s-lab-kit.manifest README-NOTFALL.txt; do
  if [ -f "$USB/$f" ]; then rc=0; else rc=1; fi
  ok "export: $f exists" "$rc" 0
done
ok "export: no leftovers next to the kit" "$(find "$USB" -type f | wc -l)" 3
ok "export: no partial file" "$(find "$USB" -name '*.part' | wc -l)" 0
head -c 20 "$USB/k8s-lab-kit.tar.age" > "$T/hdr"
has "export: the archive is an age file" "age-encryption.org" "$T/hdr"
grep -aq 'scrypt' "$USB/k8s-lab-kit.tar.age"; ok "export: the archive is passphrase encrypted (scrypt)" "$?" 0
for f in "$USB"/*; do
  rc=0; grep -aFq -- "$SECRET_TAG" "$f" || rc=$?
  ok "export: no secret content in ${f##*/}" "$rc" 1
done
has "manifest: the trust anchor" "trust-anchor: 0123456789abcdef0123456789abcdef01234567" "$USB/k8s-lab-kit.manifest"
has "manifest: the GitHub repo" "github-repo: https://github.com/example/lab" "$USB/k8s-lab-kit.manifest"
has "manifest: lists the age key" ".config/sops/age/keys.txt" "$USB/k8s-lab-kit.manifest"
has "manifest: lists the VM key from lab.yaml" ".ssh/vmkey" "$USB/k8s-lab-kit.manifest"
has "manifest: lists the repo file" "infra/envs/local/lab.local.yaml" "$USB/k8s-lab-kit.manifest"
has "manifest: the hash of a plaintext file" "$(sha256sum "$H/.config/sops/age/keys.txt" | awk '{ print $1 }')" "$USB/k8s-lab-kit.manifest"
has "manifest: the archive hash" "archive-sha256: $(sha256sum "$USB/k8s-lab-kit.tar.age" | awk '{ print $1 }')" "$USB/k8s-lab-kit.manifest"
has "README: the repo address" "https://github.com/example/lab" "$USB/README-NOTFALL.txt"
has "README: the trust anchor" "0123456789abcdef0123456789abcdef01234567" "$USB/README-NOTFALL.txt"
has "README: the runbook" "notfall-neuaufbau.md" "$USB/README-NOTFALL.txt"
hasnt "README: no unreplaced placeholder" "@ANCHOR@" "$USB/README-NOTFALL.txt"
hasnt "README: no unreplaced repo placeholder" "@REPO_URL@" "$USB/README-NOTFALL.txt"
ok "export: the tmpfs is empty again" "$(find "$SHM" -mindepth 1 | wc -l)" 0

echo "== verify"
kit "$H" "$REPO" "$PASS" verify "$USB"; ok "verify: exit 0" "$?" 0
has "verify: OK line" "VERIFY OK" "$T/out"
nosecret "verify"
ok "verify: the tmpfs is empty again" "$(find "$SHM" -mindepth 1 | wc -l)" 0
kit "$H" "$REPO" "wrong-passphrase" verify "$USB"; ok "verify with a wrong passphrase: exit 1" "$?" 1
has "verify with a wrong passphrase: named" "decryption failed" "$T/out"
nosecret "verify, wrong passphrase"
cp "$USB/k8s-lab-kit.manifest" "$T/manifest.orig"
sed -i 's/^trust-anchor: .*/trust-anchor: ffffffffffffffffffffffffffffffffffffffff/' "$USB/k8s-lab-kit.manifest"
kit "$H" "$REPO" "$PASS" verify "$USB"; ok "verify with a changed manifest: exit 1" "$?" 1
cp "$T/manifest.orig" "$USB/k8s-lab-kit.manifest"
cp "$USB/k8s-lab-kit.tar.age" "$T/archive.orig"
printf 'x' >> "$USB/k8s-lab-kit.tar.age"
kit "$H" "$REPO" "$PASS" verify "$USB"; ok "verify with a damaged archive: exit 1" "$?" 1
cp "$T/archive.orig" "$USB/k8s-lab-kit.tar.age"
kit "$H" "$REPO" "$PASS" verify "$T/not-there"; ok "verify without a kit: exit 1" "$?" 1

echo "== import into a bare PC"
H2=$T/home2
REPO2=$T/repo2
rm -rf "$H2" "$REPO2"; mkdir -p "$H2" "$REPO2/infra/envs/local"
kit "$H2" "$REPO2" "$PASS" import "$USB" --dry-run; ok "import --dry-run: exit 0" "$?" 0
ok "import --dry-run: nothing was written" "$(find "$H2" "$REPO2" -type f | wc -l)" 0
kit "$H2" "$REPO2" "$PASS" import "$USB"; ok "import: exit 0" "$?" 0
nosecret "import"
has "import: next step trust" "trust init 0123456789abcdef0123456789abcdef01234567" "$T/out"
has "import: next step preflight" "lab.sh preflight" "$T/out"
has "import: next step runbook" "notfall-neuaufbau.md" "$T/out"
while IFS= read -r p; do
  cmp -s "$H/$p" "$H2/$p"; ok "import: $p is identical" "$?" 0
done < <(required_paths)
cmp -s "$REPO/infra/envs/local/lab.local.yaml" "$REPO2/infra/envs/local/lab.local.yaml"; ok "import: the repo file is identical" "$?" 0
cmp -s "$H/.ssh/vmkey" "$H2/.ssh/vmkey"; ok "import: the VM key is identical" "$?" 0
cmp -s "$H/.config/k8s-lab/notes-one.passwort" "$H2/.config/k8s-lab/notes-one.passwort"; ok "import: a globbed file is identical" "$?" 0
ok "import: age key mode 0600" "$(stat -c %a "$H2/.config/sops/age/keys.txt")" 600
ok "import: signing-style key mode 0600" "$(stat -c %a "$H2/.ssh/argocd-k8s-lab")" 600
ok "import: break-glass key mode 0600" "$(stat -c %a "$H2/.config/k8s-lab/break-glass-age.txt")" 600
for name in wireguard-server.key wireguard-client.key alert-heartbeat.sops.yaml; do
  cmp -s "$H/.config/k8s-lab/$name" "$H2/.config/k8s-lab/$name"; ok "import: $name is identical" "$?" 0
  ok "import: $name mode 0600" "$(stat -c %a "$H2/.config/k8s-lab/$name")" 600
done
ok "import: .ssh mode 0700" "$(stat -c %a "$H2/.ssh")" 700
ok "import: .config/k8s-lab mode 0700" "$(stat -c %a "$H2/.config/k8s-lab")" 700
ok "import: .config/sops/age mode 0700" "$(stat -c %a "$H2/.config/sops/age")" 700
ok "import: .config/rustfs mode 0700" "$(stat -c %a "$H2/.config/rustfs")" 700
ok "import: the tmpfs is empty again" "$(find "$SHM" -mindepth 1 | wc -l)" 0
kit "$H2" "$REPO2" "$PASS" import "$USB"; ok "import again: exit 0" "$?" 0
has "import again: everything already identical" "0 new, 0 replaced" "$T/out"
ok "import again: no .before-kit copies" "$(find "$H2" "$REPO2" -name '*.before-kit-*' | wc -l)" 0

echo "== import never overwrites silently"
printf 'a different age key\n' > "$H2/.config/sops/age/keys.txt"
kit "$H2" "$REPO2" "$PASS" import "$USB"; ok "import with a differing file: exit 1" "$?" 1
has "import with a differing file: named" "DIFFERS" "$T/out"
has "import with a differing file: --force is named" "--force" "$T/out"
has "import with a differing file: the file is kept" "a different age key" "$H2/.config/sops/age/keys.txt"
kit "$H2" "$REPO2" "$PASS" import "$USB" --force; ok "import --force: exit 0" "$?" 0
cmp -s "$H/.config/sops/age/keys.txt" "$H2/.config/sops/age/keys.txt"; ok "import --force: the kit file is back" "$?" 0
ok "import --force: one old copy kept" "$(find "$H2/.config/sops/age" -name 'keys.txt.before-kit-*' | wc -l)" 1
has "import --force: the old content is in the copy" "a different age key" "$(find "$H2/.config/sops/age" -name 'keys.txt.before-kit-*' | head -n 1)"
ok "import --force: the copy is 0600" "$(stat -c %a "$(find "$H2/.config/sops/age" -name 'keys.txt.before-kit-*' | head -n 1)")" 600

echo "== --must-only"
rm -rf "$USB"; mkdir -p "$USB"
kit "$H" "$REPO" "$PASS" export "$USB" --must-only; ok "export --must-only: exit 0" "$?" 0
hasnt "export --must-only: no nice-to-have file in the manifest" ".ssh/argocd-k8s-lab" "$USB/k8s-lab-kit.manifest"
has "export --must-only: the break-glass key (must, optional) is in" "break-glass-age.txt" "$USB/k8s-lab-kit.manifest"
has "export --must-only: server WireGuard identity is in" "wireguard-server.key" "$USB/k8s-lab-kit.manifest"
has "export --must-only: client WireGuard identity is in" "wireguard-client.key" "$USB/k8s-lab-kit.manifest"
hasnt "export --must-only: optional heartbeat URL is out" "alert-heartbeat.sops.yaml" "$USB/k8s-lab-kit.manifest"

echo "== kit-extra.list (own additions)"
rm -rf "$USB"; mkdir -p "$USB"
mkdir -p "$H/.ssh"
printf '%s-oldserver\n' "$SECRET_TAG" > "$H/.ssh/id_oldserver"
printf '%s-oldwg\n' "$SECRET_TAG" > "$H/.config/oldwg.conf"
printf '# old server\n.ssh/id_oldserver\n.config/oldwg.*  # glob\n.ssh/not-there\n../etc/passwd\n/abs/path\n.config/sops/age/keys.txt\n' > "$H/.config/k8s-lab/kit-extra.list"
kit "$H" "$REPO" "$PASS" export "$USB"; ok "export with extras: exit 0 (a missing extra is no error)" "$?" 0
has "export with extras: the extra key is in the manifest" ".ssh/id_oldserver" "$USB/k8s-lab-kit.manifest"
has "export with extras: the globbed extra is in the manifest" ".config/oldwg.conf" "$USB/k8s-lab-kit.manifest"
has "export with extras: the list itself is in the manifest" "kit-extra.list" "$USB/k8s-lab-kit.manifest"
has "export with extras: an unsafe line is reported" "kit-extra.list: ignored" "$T/out"
hasnt "export with extras: no parent path" "etc/passwd" "$USB/k8s-lab-kit.manifest"
ok "export with extras: no duplicate entry" "$(grep -c '^F.*[[:space:]]\.config/sops/age/keys\.txt$' "$USB/k8s-lab-kit.manifest")" 1
hasnt "export with extras: no secret content in the output" "$SECRET_TAG" "$T/out"
H3=$T/home3
mkdir -p "$H3" "$T/repo3"
kit "$H3" "$T/repo3" "$PASS" import "$USB" --repo "$T/repo3"; ok "import with extras: exit 0" "$?" 0
cmp -s "$H/.ssh/id_oldserver" "$H3/.ssh/id_oldserver"; ok "import with extras: the extra key is back" "$?" 0
ok "import with extras: mode 0600" "$(stat -c %a "$H3/.ssh/id_oldserver")" 600
rm -f "$H/.config/k8s-lab/kit-extra.list" "$H/.ssh/id_oldserver" "$H/.config/oldwg.conf"

echo "== import pins the GitHub host keys"
H4=$T/home4
rm -rf "$H4" "$T/repo4"; mkdir -p "$H4" "$T/repo4/infra/envs/local"
grep '^github_known_hosts:' "$R/infra/envs/local/lab.yaml" > "$T/repo4/infra/envs/local/lab.yaml"
kit "$H4" "$T/repo4" "$PASS" import "$USB" --repo "$T/repo4"; ok "import with github_known_hosts: exit 0" "$?" 0
ok "import: three GitHub host keys in known_hosts" "$(grep -c '^github.com ' "$H4/.ssh/known_hosts")" 3
ok "import: known_hosts mode 0600" "$(stat -c %a "$H4/.ssh/known_hosts")" 600
while read -r fp; do
  has "import: GitHub fingerprint $fp" "$fp" <(ssh-keygen -lf "$H4/.ssh/known_hosts")
done <<'FP'
SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU
SHA256:p2QAMXNIC1TJYWeIOttrVc98/R1BUFWu3/LiyKgUfQM
SHA256:uNiVztksCsDhcc0u9e8BujQXVUpKZIDTMczCvj3tD2s
FP
kit "$H4" "$T/repo4" "$PASS" import "$USB" --repo "$T/repo4"; ok "import again: exit 0" "$?" 0
ok "import again: no duplicate GitHub host keys" "$(grep -c '^github.com ' "$H4/.ssh/known_hosts")" 3

echo
echo "$n checks, $fail failures"
[ "$fail" = 0 ]
