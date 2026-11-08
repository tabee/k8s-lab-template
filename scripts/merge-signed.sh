#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
# Brings a pull-request branch into main with YOUR signature on every commit.
# For branches whose commits are unsigned (for example from an assistant).
#
# Usage (in your clone, signing already set up with scripts/setup-signing.sh):
#   bash scripts/merge-signed.sh BRANCH [--push] [--remote NAME] [--base NAME] [--dry-run]
#
#   BRANCH     branch name on the remote (feature/foo), not a commit
#   --push     push main when everything checked out (default: stop before the push
#              and print the command)
#   --remote   default origin
#   --base     default main
#   --dry-run  only check the preconditions and say what would happen
#
# Why re-signing and not a merge commit: the protection of main and the CI check require a
# valid signature on EVERY commit a push brings in. A merge commit made with -S signs only
# itself, the unsigned commits of the branch would come along and be refused. So the
# branch is replayed on top of the base (git rebase --force-rebase -S): the authors stay,
# the committer and the signature are yours, the history stays linear (fast-forward only).
#
# The steps, nothing is pushed before the check passed:
#   1. fetch, the working tree must be clean, signing must be configured
#   2. local branch merge-signed/<branch> = remote branch, rebased on the base, every commit signed
#   3. scripts/check-commit-signatures.sh over base..result (the same check as CI)
#   4. base fast-forwarded to the result (never a merge commit, never a force)
#   5. with --push: git push remote base
# Afterwards close the pull request by hand (its commits have other hashes, so Gitea
# does not close it by itself) and delete the remote branch.
#
# Exit codes: 0 done, 1 a check failed, 2 misuse or precondition missing.
set -u

remote=origin
base=main
branch=
push=0
dry_run=0

usage() { sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'; }
die() { echo "ABORT $*" >&2; exit 2; }
step() { echo "STEP $*"; }

while [ $# -gt 0 ]; do
  case $1 in
    --push) push=1; shift ;;
    --remote) remote=${2:-}; shift 2 ;;
    --base) base=${2:-}; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    -h | --help) usage; exit 0 ;;
    -*) die "unknown argument: $1" ;;
    *) [ -z "$branch" ] || die "one branch only: $1"; branch=$1; shift ;;
  esac
done
[ -n "$branch" ] || die "BRANCH is missing (see --help)"
[ -n "$remote" ] && [ -n "$base" ] || die "--remote and --base need a value"
top=$(git rev-parse --show-toplevel 2> /dev/null) || die "not inside a git clone"
cd "$top" || exit 2
here=$(dirname "$(readlink -f "$0")")

[ "$branch" != "$base" ] || die "BRANCH is the base branch"
[ -z "$(git status --porcelain)" ] || die "the working tree is not clean (commit or stash first)"
[ "$(git config --get gpg.format || true)" = ssh ] || die "SSH signing is not set up here (bash scripts/setup-signing.sh)"
[ -n "$(git config --get user.signingkey || true)" ] || die "user.signingkey is not set (bash scripts/setup-signing.sh)"

step "fetch $remote"
git fetch --quiet "$remote" || die "fetch failed"
git rev-parse --verify --quiet "refs/remotes/$remote/$branch^{commit}" > /dev/null || die "no branch $branch on $remote"
git rev-parse --verify --quiet "refs/remotes/$remote/$base^{commit}" > /dev/null || die "no branch $base on $remote"
tmp=merge-signed/$branch
git rev-parse --verify --quiet "refs/heads/$tmp" > /dev/null && die "local branch $tmp exists (left over from an earlier run: git branch -D $tmp)"
n=$(git rev-list --count "$remote/$base..$remote/$branch")
[ "$n" -gt 0 ] || die "nothing to merge: $branch has no commit that $base lacks"
echo "INFO $n commit(s) from $remote/$branch on top of $remote/$base:"
git log --format='     %h %an: %s' "$remote/$base..$remote/$branch"
if [ "$dry_run" = 1 ]; then
  echo "SKIP --dry-run: nothing changed. Would re-sign $n commit(s), check them, fast-forward $base$([ "$push" = 1 ] && echo ", push")."
  exit 0
fi

orig=$(git rev-parse --abbrev-ref HEAD)
cleanup_fail() {
  git rebase --abort > /dev/null 2>&1
  git switch --quiet "$orig" > /dev/null 2>&1
  git branch -D "$tmp" > /dev/null 2>&1
}

step "re-sign $n commit(s) on top of $remote/$base"
git switch --quiet -c "$tmp" "$remote/$branch" || die "cannot create $tmp"
if ! git rebase --quiet --force-rebase -S "$remote/$base" > /dev/null; then
  cleanup_fail
  echo "FAIL the rebase onto $remote/$base stopped (conflict). Nothing was changed. Update the branch first." >&2
  exit 1
fi

if [ "$(git rev-list --count "$remote/$base..HEAD")" -eq 0 ]; then
  cleanup_fail
  echo "ABORT nothing left to merge: the changes of $branch are already in $base (merged before?). Nothing was changed." >&2
  exit 2
fi

step "verify every new commit like the CI does"
if ! bash "$here/check-commit-signatures.sh" --before "$(git rev-parse "$remote/$base")" --after "$(git rev-parse HEAD)"; then
  cleanup_fail
  echo "FAIL a signature does not verify (is the key in .gitea/allowed_signers on $base, is it loaded: ssh-add?). Nothing was changed." >&2
  exit 1
fi

step "fast-forward $base"
git switch --quiet "$base" || { cleanup_fail; die "cannot switch to $base"; }
if ! git merge --quiet --ff-only "$remote/$base" || ! git merge --quiet --ff-only "$tmp"; then
  git switch --quiet "$orig" > /dev/null 2>&1
  git branch -D "$tmp" > /dev/null 2>&1
  echo "FAIL $base cannot be fast-forwarded (local $base has commits of its own?). Nothing was pushed." >&2
  exit 1
fi
git branch --quiet -D "$tmp"
echo "OK   local $base is now $(git rev-parse --short HEAD), $n commit(s) signed by you"

if [ "$push" = 1 ]; then
  step "push $base to $remote"
  git push "$remote" "$base" || { echo "FAIL the push was refused. Local $base stays as it is." >&2; exit 1; }
  echo "OK   pushed. Close the pull request and delete the branch: git push $remote --delete $branch"
else
  echo "NEXT git push $remote $base      (then close the pull request, delete the branch: git push $remote --delete $branch)"
fi
