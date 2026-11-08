#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
# Tests for scripts/setup-signing.sh and scripts/check-commit-signatures.sh with real
# ssh-keygen and git in a sandbox (temporary repos and keys, nothing outside the sandbox).
# Without ssh-keygen (OpenSSH 8.0 or newer) or git the suite prints SKIP and exits 0.
# Usage: bash tests/signing-tests.sh [repo root]
set -u
R=$(cd "${1:-$(dirname "${BASH_SOURCE[0]}")/..}" && pwd -P)
for w in git ssh-keygen; do
  command -v "$w" > /dev/null 2>&1 || { echo "SKIP: $w is missing"; exit 0; }
done
mkdir -p "$HOME/.cache/lab-sh-tests"
T=$(mktemp -d -p "$HOME/.cache/lab-sh-tests")
trap 'rm -rf "$T"' EXIT
SETUP=$R/scripts/setup-signing.sh
CHECK=$R/scripts/check-commit-signatures.sh
ZERO=0000000000000000000000000000000000000000
fail=0
n=0
ok() { n=$((n + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else echo "FAIL $1 (is '$2', want '$3')"; fail=$((fail + 1)); fi; }
has() { grep -Fq -- "$2" "$3"; ok "$1" "$?" 0; }
hasnt() { grep -Fq -- "$2" "$3"; ok "$1" "$?" 1; }
rc() { "$@" > /dev/null 2>&1; echo $?; }

# Isolated git: no user config, fixed identity.
export HOME=$T/home
export GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=Tester GIT_AUTHOR_EMAIL=tester@example.org
export GIT_COMMITTER_NAME=Tester GIT_COMMITTER_EMAIL=tester@example.org
mkdir -p "$HOME/.ssh"
ssh-keygen -q -t ed25519 -N '' -C key-a -f "$T/key-a"
ssh-keygen -q -t ed25519 -N '' -C key-b -f "$T/key-b"
cp "$T/key-a.pub" "$HOME/.ssh/k8s-lab-signing.pub"

# commit FILE-CONTENT MESSAGE [KEYFILE]: signed with KEYFILE, unsigned without it
commit() {
  echo "$1" >> data.txt
  git add -A
  if [ -n "${3:-}" ]; then
    git -c gpg.format=ssh -c "user.signingkey=$3" -c commit.gpgsign=true commit -q -m "$2"
  else
    git -c commit.gpgsign=false commit -q -m "$2"
  fi
}

# ---------- setup-signing.sh
git init -q -b main "$T/clone"
cd "$T/clone" || exit 1
mkdir -p .gitea
# Always start from a comment line: the real file holds the maintainer key, the export has none.
printf '# signers\n' > .gitea/allowed_signers

ok "setup: --help works" "$(rc bash "$SETUP" --help)" 0
ok "setup: unknown flag is an error" "$(rc bash "$SETUP" --nope)" 2
ok "setup: missing key is an error" "$(rc bash "$SETUP" --key "$T/missing.pub")" 2
cp "$T/key-a" "$T/lonely"
ok "setup: a private key without a .pub next to it is refused" "$(rc bash "$SETUP" --dry-run "$T/lonely")" 2
ok "setup: a .pub that is no SSH key is refused" "$(printf 'not a key\n' > "$T/bad.pub"; rc bash "$SETUP" --dry-run "$T/bad.pub")" 2

bash "$SETUP" --dry-run > "$T/dry.log" 2>&1
ok "setup: dry run exits 0" "$?" 0
has "setup: dry run announces the settings" "WILL SET   gpg.format = ssh" "$T/dry.log"
ok "setup: dry run changes nothing" "$(git config --local --get gpg.format | wc -l | tr -d ' ')" 0
ok "setup: dry run leaves the signers file alone" "$(grep -cv '^#' .gitea/allowed_signers)" 0

bash "$SETUP" < /dev/null > "$T/run1.log" 2>&1
ok "setup: first run exits 0" "$?" 0
ok "setup: gpg.format is ssh" "$(git config --local --get gpg.format)" ssh
ok "setup: signing key is the chosen .pub" "$(git config --local --get user.signingkey)" "$HOME/.ssh/k8s-lab-signing.pub"
ok "setup: commit.gpgsign is true" "$(git config --local --get commit.gpgsign)" true
ok "setup: allowed signers file is the repo-relative path" "$(git config --local --get gpg.ssh.allowedSignersFile)" ".gitea/allowed_signers"
ok "setup: the key is in the signers file once" "$(grep -c "$(awk '{ print $2 }' "$T/key-a.pub")" .gitea/allowed_signers)" 1
has "setup: the signers line is namespaced to git" 'namespaces="git" ssh-ed25519' .gitea/allowed_signers
hasnt "setup: no private key material in the output" "PRIVATE" "$T/run1.log"
has "setup: tells you to ssh-add the private key" "TODO git signs through ssh-agent: ssh-add $HOME/.ssh/k8s-lab-signing" "$T/run1.log"
has "setup: tells you to register the key in Gitea" "add $HOME/.ssh/k8s-lab-signing.pub under Settings" "$T/run1.log"
hasnt "setup: the dedicated key gets no login-key warning" "general login key" "$T/run1.log"

cp .git/config "$T/config-before"
cp .gitea/allowed_signers "$T/signers-before"
bash "$SETUP" > "$T/run2.log" 2>&1
ok "setup: second run exits 0" "$?" 0
has "setup: second run skips the git config" "SKIP git config: signing is already set up" "$T/run2.log"
has "setup: second run skips the signers file" "SKIP allowed signers: the key is already" "$T/run2.log"
ok "setup: second run leaves git config identical" "$(cmp -s .git/config "$T/config-before"; echo $?)" 0
ok "setup: second run leaves the signers file identical" "$(cmp -s .gitea/allowed_signers "$T/signers-before"; echo $?)" 0

bash "$SETUP" --dry-run --skip-allowed-signers "$T/key-b" > "$T/run3a.log" 2>&1
has "setup: the private key path selects its .pub (positional)" "user.signingkey = $T/key-b.pub" "$T/run3a.log"
cp "$T/key-b.pub" "$HOME/.ssh/id_ed25519.pub"
bash "$SETUP" --dry-run --skip-allowed-signers "$HOME/.ssh/id_ed25519" > "$T/run3b.log" 2>&1
has "setup: a general login key gets a warning" "general login key" "$T/run3b.log"
bash "$SETUP" --skip-allowed-signers --key "$T/key-b.pub" > "$T/run3.log" 2>&1
has "setup: --skip-allowed-signers is honoured" "SKIP allowed signers: --skip-allowed-signers" "$T/run3.log"
ok "setup: a second key switches user.signingkey" "$(git config --local --get user.signingkey)" "$T/key-b.pub"
mkdir -p "$T/home2"
HOME=$T/home2 bash "$SETUP" --global --skip-allowed-signers --key "$T/key-a.pub" > /dev/null 2>&1
ok "setup: --global writes the user config" "$(git config --file "$T/home2/.gitconfig" --get gpg.format)" ssh
ok "setup: --global sets no allowed-signers path" "$(git config --file "$T/home2/.gitconfig" --get gpg.ssh.allowedSignersFile | wc -l | tr -d ' ')" 0

# ---------- check-commit-signatures.sh
git init -q -b main "$T/repo"
cd "$T/repo" || exit 1
mkdir -p .gitea
printf '# empty\n' > .gitea/allowed_signers
commit one "c1 unsigned base"
C1=$(git rev-parse HEAD)
printf '* namespaces="git" %s\n' "$(cut -d' ' -f1,2 "$T/key-a.pub")" > .gitea/allowed_signers
commit two "c2 key a added" "$T/key-a"
C2=$(git rev-parse HEAD)

ok "check: --help works" "$(rc bash "$CHECK" --help)" 0
ok "check: missing --after is an error" "$(rc bash "$CHECK" --before "$C1")" 2
ok "check: unknown commit is an error" "$(rc bash "$CHECK" --before "$C1" --after 1111111111111111111111111111111111111111)" 2

bash "$CHECK" --before "$C1" --after "$C2" > "$T/boot.log" 2>&1
ok "check: no key in the base revision passes (bootstrap)" "$?" 0
has "check: bootstrap is announced" "BOOTSTRAP" "$T/boot.log"

commit three "c3 signed by a" "$T/key-a"
C3=$(git rev-parse HEAD)
bash "$CHECK" --before "$C2" --after "$C3" > "$T/good.log" 2>&1
ok "check: a commit signed by an allowed key passes" "$?" 0
has "check: the good commit is listed" "OK  " "$T/good.log"

commit four "c4 unsigned"
C4=$(git rev-parse HEAD)
bash "$CHECK" --before "$C3" --after "$C4" > "$T/unsigned.log" 2>&1
ok "check: an unsigned commit fails" "$?" 1
has "check: the unsigned commit is named" "FAIL" "$T/unsigned.log"

commit five "c5 signed by b" "$T/key-b"
C5=$(git rev-parse HEAD)
bash "$CHECK" --before "$C4" --after "$C5" > /dev/null 2>&1
ok "check: a commit signed by an unknown key fails" "$?" 1

# A push may not approve its own key: c6 adds key b and is signed by b.
printf '* namespaces="git" %s\n' "$(cut -d' ' -f1,2 "$T/key-b.pub")" >> .gitea/allowed_signers
commit six "c6 adds key b, signed by b" "$T/key-b"
C6=$(git rev-parse HEAD)
bash "$CHECK" --before "$C3" --after "$C6" > /dev/null 2>&1
ok "check: a push cannot approve its own key (file read from BEFORE)" "$?" 1

# Several commits, the middle one unsigned
git checkout -q -b multi "$C3"
commit m1 "m1 signed" "$T/key-a"
commit m2 "m2 unsigned"
commit m3 "m3 signed" "$T/key-a"
M3=$(git rev-parse HEAD)
bash "$CHECK" --before "$C3" --after "$M3" > "$T/multi.log" 2>&1
ok "check: one unsigned commit in the middle fails the push" "$?" 1
ok "check: exactly one commit is reported" "$(grep -c '^FAIL' "$T/multi.log")" 1

# All good over several commits
git checkout -q -b multi-ok "$C3"
commit g1 "g1 signed" "$T/key-a"
commit g2 "g2 signed" "$T/key-a"
G2=$(git rev-parse HEAD)
bash "$CHECK" --before "$C3" --after "$G2" > /dev/null 2>&1
ok "check: several signed commits pass" "$?" 0

# New branch (before = zero): only commits no other remote ref has
git checkout -q main
git update-ref refs/remotes/origin/main "$C3"
bash "$CHECK" --before "$ZERO" --after "$G2" > "$T/newbranch.log" 2>&1
ok "check: a new branch with signed commits passes" "$?" 0
has "check: a new branch reports the two new commits" "Checked 2 commit(s)" "$T/newbranch.log"
bash "$CHECK" --before "$ZERO" --after "$M3" > /dev/null 2>&1
ok "check: a new branch with an unsigned commit fails" "$?" 1

# Explicit signers file, and a signers file without keys
bash "$CHECK" --before "$C4" --after "$C5" --signers-file "$T/key-b.pub" > /dev/null 2>&1
ok "check: a signers file that is not an allowed-signers list fails the commit" "$?" 1
: > "$T/empty-signers"
bash "$CHECK" --before "$C4" --after "$C5" --signers-file "$T/empty-signers" > "$T/e.log" 2>&1
ok "check: an empty explicit signers file means bootstrap" "$?" 0

# ---------- merge-signed.sh: the branch of an unsigned author goes into main signed
MS=$R/scripts/merge-signed.sh
if [ -f "$MS" ]; then
  git init -q --bare -b main "$T/origin.git"
  git clone -q "$T/origin.git" "$T/maint" 2> /dev/null
  cd "$T/maint" || exit 1
  git config user.name Maintainer; git config user.email maint@example.org
  mkdir -p .gitea scripts
  printf '* namespaces="git" %s\n' "$(cut -d' ' -f1,2 "$T/key-a.pub")" > .gitea/allowed_signers
  cp "$CHECK" scripts/check-commit-signatures.sh
  commit base "c1 base"
  git push -q origin main 2> /dev/null
  # an assistant with unsigned commits pushes a feature branch
  git clone -q "$T/origin.git" "$T/grok" 2> /dev/null
  ( cd "$T/grok" && export GIT_AUTHOR_NAME=Grok GIT_COMMITTER_NAME=Grok && git config user.name Grok && git config user.email grok@example.org && git config commit.gpgsign false \
    && git switch -q -c feature/x && echo one > f1.txt && git add -A && git commit -q -m "feat: one" \
    && echo two > f2.txt && git add -A && git commit -q -m "feat: two" && git push -q origin feature/x 2> /dev/null )
  export GIT_AUTHOR_NAME=Maintainer GIT_COMMITTER_NAME=Maintainer
  git config gpg.format ssh; git config commit.gpgsign true
  git config user.signingkey "$T/key-a"
  git config gpg.ssh.allowedSignersFile .gitea/allowed_signers

  # the alternative that does NOT work: a signed merge commit drags the unsigned commits along
  git fetch -q origin
  git switch -q -c try-merge main
  git merge -q --no-ff -S origin/feature/x -m "merge" > /dev/null 2>&1
  bash "$CHECK" --before "$(git rev-parse main)" --after "$(git rev-parse HEAD)" > "$T/nff.log" 2>&1
  ok "merge-signed: a signed --no-ff merge fails the check (unsigned commits come along)" "$?" 1
  git switch -q main; git branch -q -D try-merge

  ok "merge-signed: --help works" "$(rc bash "$MS" --help)" 0
  ok "merge-signed: no branch is an error" "$(rc bash "$MS")" 2
  ok "merge-signed: an unknown branch is an error" "$(rc bash "$MS" feature/nope)" 2
  bash "$MS" feature/x --dry-run > "$T/ms-dry.log" 2>&1
  ok "merge-signed: dry run exits 0" "$?" 0
  has "merge-signed: dry run lists the commits" "Grok: feat: two" "$T/ms-dry.log"
  ok "merge-signed: dry run changes nothing" "$(git rev-parse main)" "$(git rev-parse origin/main)"
  echo dirty > dirty.txt
  ok "merge-signed: a dirty working tree is refused" "$(rc bash "$MS" feature/x)" 2
  rm dirty.txt
  ( git config --unset gpg.format; ok "merge-signed: without SSH signing it is refused" "$(rc bash "$MS" feature/x)" 2; git config gpg.format ssh )

  # a key that main does not trust: refused, nothing changed, no leftover branch
  git config user.signingkey "$T/key-b"
  bash "$MS" feature/x > "$T/ms-bad.log" 2>&1
  ok "merge-signed: a signer that main does not trust fails" "$?" 1
  ok "merge-signed: ... and main is untouched" "$(git rev-parse main)" "$(git rev-parse origin/main)"
  ok "merge-signed: ... and no temporary branch is left" "$(git branch --list 'merge-signed/*' | wc -l | tr -d ' ')" 0
  ok "merge-signed: ... and we are back on main" "$(git rev-parse --abbrev-ref HEAD)" main

  git config user.signingkey "$T/key-a"
  base_sha=$(git rev-parse origin/main)
  bash "$MS" feature/x > "$T/ms.log" 2>&1
  ok "merge-signed: re-sign and fast-forward exits 0" "$?" 0
  has "merge-signed: it announces the next step" "NEXT git push origin main" "$T/ms.log"
  ok "merge-signed: both commits are on local main" "$(git rev-list --count "$base_sha..main")" 2
  ok "merge-signed: history is linear (no merge commit)" "$(git rev-list --merges "$base_sha..main" | wc -l | tr -d ' ')" 0
  ok "merge-signed: every commit verifies" "$(git rev-list "$base_sha..main" | while read -r c; do git verify-commit "$c" > /dev/null 2>&1 || echo bad; done | wc -l | tr -d ' ')" 0
  ok "merge-signed: the author stays the assistant" "$(git log -1 --format=%an main)" Grok
  ok "merge-signed: the committer is the maintainer" "$(git log -1 --format=%cn main)" Maintainer
  ok "merge-signed: nothing is pushed without --push" "$(git rev-parse origin/main)" "$base_sha"
  ok "merge-signed: no temporary branch is left" "$(git branch --list 'merge-signed/*' | wc -l | tr -d ' ')" 0
  git push -q origin main 2> /dev/null
  ok "merge-signed: the check passes for the push" "$(rc bash "$CHECK" --before "$base_sha" --after "$(git rev-parse main)")" 0

  # --push does the push itself; a branch that is already on the tip is still re-signed (--force-rebase)
  ( cd "$T/grok" && export GIT_AUTHOR_NAME=Grok GIT_COMMITTER_NAME=Grok && git switch -q main && git pull -q --ff-only origin main 2> /dev/null && git switch -q -c feature/y \
    && echo three > f3.txt && git add -A && git commit -q -m "feat: three" && git push -q origin feature/y 2> /dev/null )
  bash "$MS" feature/y --push > "$T/ms2.log" 2>&1
  ok "merge-signed: --push exits 0" "$?" 0
  ok "merge-signed: --push moved origin/main" "$(git --git-dir="$T/origin.git" rev-parse main)" "$(git rev-parse main)"
  ok "merge-signed: the pushed commit is signed" "$(git verify-commit main > /dev/null 2>&1; echo $?)" 0
  has "merge-signed: it names the branch to delete" "git push origin --delete feature/y" "$T/ms2.log"
  ok "merge-signed: a branch whose changes are already in main is refused" "$(rc bash "$MS" feature/y)" 2
  ok "merge-signed: ... and leaves no temporary branch" "$(git branch --list 'merge-signed/*' | wc -l | tr -d ' ')" 0

  # local main with a commit of its own: no fast-forward, nothing pushed
  ( cd "$T/grok" && export GIT_AUTHOR_NAME=Grok GIT_COMMITTER_NAME=Grok && git switch -q main && git pull -q --ff-only origin main 2> /dev/null && git switch -q -c feature/z \
    && echo four > f4.txt && git add -A && git commit -q -m "feat: four" && git push -q origin feature/z 2> /dev/null )
  echo local > local.txt; git add -A; git commit -q -m "local only"
  bash "$MS" feature/z --push > "$T/ms3.log" 2>&1
  ok "merge-signed: a diverged local main is refused" "$?" 1
  ok "merge-signed: ... and nothing was pushed" "$(git --git-dir="$T/origin.git" rev-parse main)" "$(git rev-parse origin/main)"
  cd "$T" || exit 1
else
  echo "SKIP merge-signed tests: the script is not part of this tree"
fi

# ---------- Workflow
if [ -f "$R/.gitea/workflows/signature-check.yml" ] && [ -f "$R/.github/workflows/gitleaks.yml" ]; then
  W=$R/.gitea/workflows
  a=$(grep -E '^[[:space:]]+image:' "$W/signature-check.yml" | head -n 1 | sed 's/^[[:space:]]*//')
  b=$(grep -E '^[[:space:]]+image:' "$W/gitleaks.yml" | head -n 1 | sed 's/^[[:space:]]*//')
  ok "workflow: signature-check uses the same pinned image as gitleaks" "$a" "$b"
  case $a in *@sha256:????????????????????????????????????????????????????????????????) r=pinned ;; *) r=loose ;; esac
  ok "workflow: the image is pinned by digest" "$r" pinned
  has "workflow: runs the script from the repo" "scripts/check-commit-signatures.sh" "$W/signature-check.yml"
  hasnt "workflow: no unpinned third-party action" "uses:" "$W/signature-check.yml"
else
  echo "SKIP workflow tests: workflow files are not part of this tree"
fi

echo
echo "$n checks, $fail failures"
[ "$fail" -eq 0 ]
