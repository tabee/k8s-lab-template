#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
# Tests for scripts/lab-trust.sh (source trust, ADR 0023) with real ssh-keygen and git in a
# sandbox (temporary repos, keys and state directory, nothing outside the sandbox).
# Without ssh-keygen (OpenSSH 8.0 or newer) or git the suite prints SKIP and exits 0.
# Usage: bash tests/trust-tests.sh [repo root]
set -u
R=$(cd "${1:-$(dirname "${BASH_SOURCE[0]}")/..}" && pwd -P)
for w in git ssh-keygen; do
  command -v "$w" > /dev/null 2>&1 || { echo "SKIP: $w is missing"; exit 0; }
done
mkdir -p "$HOME/.cache/lab-sh-tests"
T=$(mktemp -d -p "$HOME/.cache/lab-sh-tests")
trap 'rm -rf "$T"' EXIT
TRUST=$R/scripts/lab-trust.sh
fail=0
n=0
ok() { n=$((n + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else echo "FAIL $1 (is '$2', want '$3')"; fail=$((fail + 1)); fi; }
has() { grep -Fq -- "$2" "$3"; ok "$1" "$?" 0; }
hasnt() { grep -Fq -- "$2" "$3"; ok "$1" "$?" 1; }

export HOME=$T/home
export GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=Tester GIT_AUTHOR_EMAIL=tester@example.org
export GIT_COMMITTER_NAME=Tester GIT_COMMITTER_EMAIL=tester@example.org
export LAB_TRUST_DIR=$T/state LAB_REQUIRE_TTY=0
mkdir -p "$HOME"
ssh-keygen -q -t ed25519 -N '' -C key-a -f "$T/key-a"
ssh-keygen -q -t ed25519 -N '' -C key-b -f "$T/key-b"
signer_line() { printf '* namespaces="git" %s\n' "$(awk '{ print $1, $2 }' "$1.pub")"; }

# commit MESSAGE [KEYFILE]: signed with KEYFILE, unsigned without it
commit() {
  echo "$1" >> data.txt
  git add -A
  if [ -n "${2:-}" ]; then
    git -c gpg.format=ssh -c "user.signingkey=$2" -c commit.gpgsign=true commit -q -m "$1"
  else
    git -c commit.gpgsign=false commit -q -m "$1"
  fi
}
verify() { bash "$TRUST" verify "$1" --repo "$T/clone" > "$T/out" 2>&1; }
vrc() { verify "$1"; echo $?; }

# History: c0 (unsigned, adds key A), c1 signed by A, c2 signed by A
git init -q -b main "$T/clone"
cd "$T/clone" || exit 1
mkdir -p .gitea
signer_line "$T/key-a" > .gitea/allowed_signers
commit c0-anchor
C0=$(git rev-parse HEAD)
commit c1-signed-a "$T/key-a"
C1=$(git rev-parse HEAD)
commit c2-signed-a "$T/key-a"
C2=$(git rev-parse HEAD)

echo "== usage"
ok "no command is an error" "$(bash "$TRUST" > /dev/null 2>&1; echo $?)" 2
ok "unknown option is an error" "$(bash "$TRUST" status --nope > /dev/null 2>&1; echo $?)" 2
ok "help works" "$(bash "$TRUST" --help > /dev/null 2>&1; echo $?)" 0
ok "verify needs a commit" "$(bash "$TRUST" verify --repo "$T/clone" > /dev/null 2>&1; echo $?)" 2
ok "unknown commit is an error" "$(vrc deadbeefdeadbeefdeadbeef)" 2

echo "== no anchor yet"
bash "$TRUST" status > "$T/out" 2>&1
has "status: nothing recorded" "No trusted commit recorded" "$T/out"
ok "verify without an anchor: exit 3" "$(vrc "$C2")" 3
has "verify without an anchor: tells how to start" "trust init COMMIT" "$T/out"

echo "== init (typed confirmation)"
ok "init with a wrong answer: exit 1" "$(echo nope | bash "$TRUST" init "$C0" --repo "$T/clone" > /dev/null 2>&1; echo $?)" 1
ok "init with a wrong answer: nothing recorded" "$([ -e "$T/state/trusted-head" ] && echo yes || echo no)" no
ok "init needs a terminal without LAB_REQUIRE_TTY=0" "$(LAB_REQUIRE_TTY=1 bash "$TRUST" init "$C0" --repo "$T/clone" < /dev/null > /dev/null 2>&1; echo $?)" 2
ok "init with the short id: exit 0" "$(echo "${C0:0:7}" | bash "$TRUST" init "$C0" --repo "$T/clone" > /dev/null 2>&1; echo $?)" 0
ok "state file holds the commit" "$(awk '{ print $1 }' "$T/state/trusted-head")" "$C0"
ok "state file is private (0600)" "$(stat -c %a "$T/state/trusted-head")" 600
ok "state directory is private (0700)" "$(stat -c %a "$T/state")" 700
ok "state is outside the repo" "$(git -C "$T/clone" status --porcelain | grep -c trusted-head)" 0
bash "$TRUST" status > "$T/out" 2>&1
has "status shows the commit" "$C0" "$T/out"

echo "== verify"
ok "the trusted commit itself: exit 0" "$(vrc "$C0")" 0
ok "signed descendants: exit 0" "$(vrc "$C2")" 0
has "both commits are OK" "Checked 2 commit(s) after the trusted ${C0:0:7}, 0 failed." "$T/out"
verify "$C2"
ok "verify alone does not move the anchor" "$(awk '{ print $1 }' "$T/state/trusted-head")" "$C0"
bash "$TRUST" verify "$C2" --record --repo "$T/clone" > /dev/null 2>&1
ok "--record advances the anchor" "$(awk '{ print $1 }' "$T/state/trusted-head")" "$C2"
ok "rollback to an older commit: exit 1" "$(vrc "$C1")" 1
has "rollback is named" "OLDER than the trusted commit" "$T/out"
echo "$C0 2026-01-01T00:00:00Z reset" > "$T/state/trusted-head"

echo "== failures"
commit c3-unsigned
C3=$(git rev-parse HEAD)
ok "an unsigned commit: exit 1" "$(vrc "$C3")" 1
has "the unsigned commit is named" "FAIL ${C3:0:7} c3-unsigned" "$T/out"
commit c4-signed-b "$T/key-b"
C4=$(git rev-parse HEAD)
ok "a commit of a key that is not allowed: exit 1" "$(vrc "$C4")" 1
ok "one bad commit in the middle fails the whole range" "$(vrc "$C4")" 1
has "the good ones are still reported" "OK   ${C1:0:7} c1-signed-a" "$T/out"

echo "== a commit cannot approve its own key"
git checkout -q -b selfapprove "$C2"
{ cat .gitea/allowed_signers; signer_line "$T/key-b"; } > "$T/new-signers"
cp "$T/new-signers" .gitea/allowed_signers
commit c5-adds-key-b "$T/key-b"
S5=$(git rev-parse HEAD)
ok "adding the own key in the same commit: exit 1" "$(vrc "$S5")" 1
git checkout -q -b legit "$C2"
cp "$T/new-signers" .gitea/allowed_signers
commit c5-adds-key-b-signed-by-a "$T/key-a"
L5=$(git rev-parse HEAD)
commit c6-signed-b "$T/key-b"
L6=$(git rev-parse HEAD)
ok "key added by an allowed signer: exit 0" "$(vrc "$L5")" 0
ok "key added by an allowed signer, used in the next commit: exit 0" "$(vrc "$L6")" 0

echo "== history rewritten / other repository"
git checkout -q --orphan other
git rm -rfq . 2> /dev/null
mkdir -p .gitea
signer_line "$T/key-a" > .gitea/allowed_signers
commit o1 "$T/key-a"
O1=$(git rev-parse HEAD)
ok "unrelated history: exit 1" "$(vrc "$O1")" 1
has "unrelated history is named" "not a descendant of the trusted commit" "$T/out"
echo "1111111111111111111111111111111111111111 2026-01-01T00:00:00Z gone" > "$T/state/trusted-head"
ok "anchor commit missing in the clone: exit 1" "$(vrc "$C2")" 1
has "missing anchor is named" "is not in this clone" "$T/out"

echo "== no signers in the parent"
git checkout -q --orphan empty
git rm -rfq . 2> /dev/null
mkdir -p .gitea
printf '# nothing\n' > .gitea/allowed_signers
commit e0
E0=$(git rev-parse HEAD)
commit e1 "$T/key-a"
E1=$(git rev-parse HEAD)
echo "$E0 2026-01-01T00:00:00Z test" > "$T/state/trusted-head"
ok "parent without an allowed signer: exit 1" "$(vrc "$E1")" 1
has "reason is named" "no allowed signer in its parent" "$T/out"

echo "== GitHub host keys (ADR 0024)"
# The three fingerprints GitHub publishes (docs.github.com, "GitHub's SSH key fingerprints"); written here a second
# time on purpose, so that a changed constant in lab-customize.py or a changed key in lab.yaml shows up as a failure.
PUB_ED=SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU
PUB_ECDSA=SHA256:p2QAMXNIC1TJYWeIOttrVc98/R1BUFWu3/LiyKgUfQM
PUB_RSA=SHA256:uNiVztksCsDhcc0u9e8BujQXVUpKZIDTMczCvj3tD2s
python3 - "$R" > "$T/ghkeys.txt" <<'PY'
import re, sys
t = open(sys.argv[1] + "/infra/envs/local/lab.yaml", encoding="utf-8").read()
m = re.search(r"^github_known_hosts:\s*\[(.*)\]\s*$", t, re.M)
for z in re.findall(r'"([^"]+)"', m.group(1)) if m else []:
    print(z)
PY
ok "lab.yaml has three github_known_hosts keys" "$(wc -l < "$T/ghkeys.txt")" 3
GOT=$(while read -r z; do printf '%s\n' "$z" | ssh-keygen -lf - -E sha256 | awk '{ print $2 }'; done < "$T/ghkeys.txt" | sort | tr '\n' ' ')
WANT=$(printf '%s\n' "$PUB_ED" "$PUB_ECDSA" "$PUB_RSA" | sort | tr '\n' ' ')
ok "lab.yaml: the keys carry the published fingerprints" "$GOT" "$WANT"
ok "lab.yaml: every key belongs to github.com" "$(awk '{ print $1 }' "$T/ghkeys.txt" | sort -u)" github.com
ok "lab-customize.py: GITHUB_FINGERPRINTS equals the published list" "$(python3 - "$R/scripts" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import importlib.util
spec = importlib.util.spec_from_file_location("lc", sys.argv[1] + "/lab-customize.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
print(" ".join(sorted(m.GITHUB_FINGERPRINTS.values())))
PY
)" "$(printf '%s\n' "$PUB_ED" "$PUB_ECDSA" "$PUB_RSA" | sort | tr '\n' ' ' | sed 's/ $//')"

# lab-customize.py --fetch-host-keys --github with a stub ssh-keyscan: real keys pass, a forged one aborts
mkdir -p "$T/gbin" "$T/g/infra/envs/local" "$T/g/gitops"
cp "$R/infra/envs/local/lab.yaml" "$T/g/infra/envs/local/lab.yaml"
printf '#!/usr/bin/env bash\ncat "%s"\n' "$T/scan.txt" > "$T/gbin/ssh-keyscan"
chmod +x "$T/gbin/ssh-keyscan"
GL=$T/g/infra/envs/local/lab.local.yaml
GC() { PATH=$T/gbin:$PATH python3 "$R/scripts/lab-customize.py" --repo "$T/g" --fetch-host-keys --github --repo-url "$1" --local-file "$GL" --yes > "$T/out" 2>&1; }
URL=ssh://git@github.com/test-owner/k8s-lab.git
{ echo "# github.com:22 SSH-2.0-stub"; cat "$T/ghkeys.txt"; } > "$T/scan.txt"
GC "$URL"; ok "fetch-host-keys --github with the real keys: exit 0" "$?" 0
has "fetch-host-keys --github: all keys match" "match the fingerprints GitHub publishes" "$T/out"
has "fetch-host-keys --github: github_known_hosts written" 'github_known_hosts: ["github.com ssh-ed25519' "$GL"
hasnt "fetch-host-keys --github: repo_known_hosts untouched" "repo_known_hosts" "$GL"
ok "fetch-host-keys --github: file mode 600" "$(stat -c %a "$GL")" 600
GC "$URL"; has "fetch-host-keys --github again: SKIP" "SKIP: github_known_hosts" "$T/out"
rm -f "$GL"
ssh-keygen -q -t ed25519 -N '' -C forged -f "$T/forged"
{ echo "# stub"; echo "github.com $(awk '{ print $1, $2 }' "$T/forged.pub")"; sed -n 2,3p "$T/ghkeys.txt"; } > "$T/scan.txt"
GC "$URL"; ok "fetch-host-keys --github with a forged key: exit 1" "$?" 1
has "forged key: the type is named" "do not match the fingerprints GitHub publishes (ssh-ed25519)" "$T/out"
ok "forged key: nothing written" "$([ -e "$GL" ] && echo yes || echo no)" no
GC ssh://git@git.lab-test.invalid/me/k8s-lab.git; ok "fetch-host-keys --github for another host: exit 1" "$?" 1
has "another host: message" "must point at github.com on port 22" "$T/out"
GC ssh://git@github.com:2200/test-owner/k8s-lab.git; ok "fetch-host-keys --github on another port: exit 1" "$?" 1

echo
echo "$n checks, $fail failures"
[ "$fail" = 0 ]
