#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
# Tests for scripts/lab-secrets-repo.py (lab.sh secrets-repo, ADR 0022). No cluster, no network, no real secret:
#   1. export into a fresh secrets repo clone: only the managed files, ciphertext only, idempotent (second run SKIP)
#   2. a file with a cleartext value, a symlink, a code repo or the source itself as target: ABORT, nothing written
#   3. STALE and --prune, --dry-run writes nothing
#   4. import into a code repo, idempotent
#   5. sops is never called (a fake sops on PATH would leave a marker), no content is printed
# Usage: bash tests/secrets-repo-tests.sh [repo root]
set -u
export PYTHONDONTWRITEBYTECODE=1
R=$(cd "${1:-$(dirname "${BASH_SOURCE[0]}")/..}" && pwd -P)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail=0
n=0
ok() { n=$((n + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else echo "FAIL $1 (is '$2', want '$3')"; fail=$((fail + 1)); fi; }
has() { n=$((n + 1)); if grep -qF -- "$2" "$3"; then echo "OK   $1"; else echo "FAIL $1 (missing: $2)"; fail=$((fail + 1)); fi; }
hasnot() { n=$((n + 1)); if grep -qF -- "$2" "$3"; then echo "FAIL $1 (present: $2)"; fail=$((fail + 1)); else echo "OK   $1"; fi; }
gitn() { git -c user.name=t -c user.email=t@example.org -c commit.gpgsign=false "$@"; }
S=$R/scripts/lab-secrets-repo.py
# Fake sops: must never run
mkdir -p "$T/bin"
printf '#!/bin/sh\ntouch "%s/sops-called"\nexit 0\n' "$T" > "$T/bin/sops"
chmod +x "$T/bin/sops"
run() { PATH=$T/bin:$PATH python3 "$S" "$@" > "$T/out" 2>&1; }
files() { (cd "$1" && find . -path ./.git -prune -o -type f -print | LC_ALL=C sort | tr '\n' ' '); }

# Code repo with a synthetic SOPS tree (values look like ciphertext, are random test strings)
C=$T/code
mkdir -p "$C/gitops" "$C/scripts" "$C/secrets/demo" "$C/secrets/other"
printf 'creation_rules:\n  - path_regex: secrets/.*\\.sops\\.yaml$\n    age: age1test\n' > "$C/.sops.yaml"
printf '# demo\n' > "$C/secrets/README.md"
enc() { printf '%s[%s,data:%s,iv:x,tag:y,type:str]' ENC AES256_GCM "$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"; }
mk() { printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: %s\nstringData:\n  password: %s\n  empty: ""\nsops:\n  age:\n    - recipient: age1test\n  mac: %s\n' "$2" "$(enc)" "$(enc)" > "$1"; }
mk "$C/secrets/demo/demo-admin.sops.yaml" demo-admin
mk "$C/secrets/other/other-db.sops.yaml" other-db
printf 'apiVersion: v1\nkind: Secret\nstringData:\n  password: ""\n' > "$C/secrets/demo/demo-admin.sops.yaml.example"
printf 'resources: []\n' > "$C/secrets/demo/kustomization.yaml"
printf 'files: []\n' > "$C/secrets/demo/ksops.yaml"
printf 'not managed\n' > "$C/secrets/demo/notes.txt"
(cd "$C" && git init -q -b main && git add -A && gitn commit -q -m code)
X=$T/secrets-clone
mkdir -p "$X" && git -C "$X" init -q -b main

echo "== 1. export"
run export --repo "$C" --target "$X" --dry-run; ok "dry-run: exit 0" "$?" 0
has "dry-run: WOULD COPY" "WOULD COPY: secrets/demo/demo-admin.sops.yaml" "$T/out"
ok "dry-run writes nothing" "$(files "$X")" ""
run export --repo "$C" --target "$X"; ok "export: exit 0" "$?" 0
ok "export: exactly the managed files" "$(files "$X")" "./.sops.yaml ./secrets/README.md ./secrets/demo/demo-admin.sops.yaml ./secrets/demo/demo-admin.sops.yaml.example ./secrets/demo/ksops.yaml ./secrets/demo/kustomization.yaml ./secrets/other/other-db.sops.yaml "
ok "export: copies are byte-identical" "$(cmp -s "$C/secrets/other/other-db.sops.yaml" "$X/secrets/other/other-db.sops.yaml" && echo yes || echo no)" yes
has "export: names the next git step" "Next: git -C" "$T/out"
hasnot "export: no value printed" "ENC[" "$T/out"
(cd "$X" && git add -A && gitn commit -q -m one)
run export --repo "$C" --target "$X"; ok "second export: exit 0" "$?" 0
has "second export: SKIP" "SKIP: the secrets repo already has this state." "$T/out"
ok "second export: work tree clean" "$(git -C "$X" status --porcelain | wc -l)" 0

echo "== 2. ABORT cases write nothing"
cp "$C/secrets/demo/demo-admin.sops.yaml" "$T/keep"
sed -i 's/^  password: .*/  password: plain-test-value/' "$C/secrets/demo/demo-admin.sops.yaml"
mk "$C/secrets/demo/new-one.sops.yaml" new-one
run export --repo "$C" --target "$X"; ok "cleartext value: exit 1" "$?" 1
has "cleartext value: ABORT" "ABORT" "$T/out"
hasnot "cleartext value: the value is not printed" "plain-test-value" "$T/out"
ok "cleartext value: the new ciphertext file was not written either" "$([ -e "$X/secrets/demo/new-one.sops.yaml" ] && echo yes || echo no)" no
cp "$T/keep" "$C/secrets/demo/demo-admin.sops.yaml"
sed -i '/^sops:/,$d' "$C/secrets/demo/new-one.sops.yaml"
run export --repo "$C" --target "$X"; ok "no sops metadata: exit 1" "$?" 1
rm "$C/secrets/demo/new-one.sops.yaml"
ln -s ../other/other-db.sops.yaml "$C/secrets/demo/link.sops.yaml"
run export --repo "$C" --target "$X"; ok "symlink: exit 1" "$?" 1
has "symlink: named" "symlink" "$T/out"
rm "$C/secrets/demo/link.sops.yaml"
CR=$T/code-target && mkdir -p "$CR/gitops" && git -C "$CR" init -q
run export --repo "$C" --target "$CR"; ok "code repo as target: exit 1" "$?" 1
has "code repo as target: named" "looks like a code repo" "$T/out"
ok "code repo as target: nothing written" "$([ -e "$CR/secrets" ] && echo yes || echo no)" no
run export --repo "$C" --target "$C"; ok "source as target: exit 1" "$?" 1
mkdir -p "$T/nogit"
run export --repo "$C" --target "$T/nogit"; ok "target without git: exit 1" "$?" 1
run export --repo "$C" --target "$T/missing"; ok "missing target: exit 1" "$?" 1
ok "secrets repo unchanged after all ABORTs" "$(git -C "$X" status --porcelain | wc -l)" 0

echo "== 3. STALE and --prune"
git -C "$C" rm -q secrets/other/other-db.sops.yaml
run export --repo "$C" --target "$X"; ok "removed file: exit 0" "$?" 0
has "removed file: STALE" "STALE: secrets/other/other-db.sops.yaml" "$T/out"
ok "without --prune the file stays" "$([ -e "$X/secrets/other/other-db.sops.yaml" ] && echo yes || echo no)" yes
run export --repo "$C" --target "$X" --prune --dry-run; ok "--prune --dry-run: exit 0" "$?" 0
has "--prune --dry-run: WOULD DELETE" "WOULD DELETE: secrets/other/other-db.sops.yaml" "$T/out"
ok "--prune --dry-run keeps the file" "$([ -e "$X/secrets/other/other-db.sops.yaml" ] && echo yes || echo no)" yes
run export --repo "$C" --target "$X" --prune; ok "--prune: exit 0" "$?" 0
ok "--prune deletes the file" "$([ -e "$X/secrets/other/other-db.sops.yaml" ] && echo yes || echo no)" no
(cd "$X" && git add -A && gitn commit -q -m two)

echo "== 4. import"
P=$T/public
mkdir -p "$P/gitops" "$P/scripts"
run import --repo "$P" --source "$X" --dry-run; ok "import --dry-run: exit 0" "$?" 0
ok "import --dry-run writes nothing" "$([ -e "$P/secrets" ] && echo yes || echo no)" no
run import --repo "$P" --source "$X"; ok "import: exit 0" "$?" 0
ok "import: the files of the secrets repo" "$(cd "$P" && find secrets .sops.yaml -type f | LC_ALL=C sort | tr '\n' ' ')" ".sops.yaml secrets/README.md secrets/demo/demo-admin.sops.yaml secrets/demo/demo-admin.sops.yaml.example secrets/demo/ksops.yaml secrets/demo/kustomization.yaml "
run import --repo "$P" --source "$X"; ok "second import: exit 0" "$?" 0
has "second import: SKIP" "SKIP: secrets/ already has this state." "$T/out"
run import --repo "$T/nogit" --source "$X"; ok "import into a folder without gitops/: exit 1" "$?" 1

echo "== 5. never sops, usage errors"
ok "sops was never called" "$([ -e "$T/sops-called" ] && echo yes || echo no)" no
ok "the script has no sops call" "$(grep -cE "\[\"sops\"|'sops'," "$S")" 0
run export --repo "$C"; ok "export without --target: exit 3" "$?" 3
run import --repo "$P" --source "$X" --prune; ok "import with --prune: exit 3" "$?" 3

echo
echo "$n checks, $fail failures"
[ "$fail" = 0 ]
