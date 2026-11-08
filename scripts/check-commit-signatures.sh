#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
# Verifies the SSH signature of every commit that a push brings in.
# Used by .gitea/workflows/signature-check.yml, also runnable by hand.
#
# Usage:
#   bash scripts/check-commit-signatures.sh --before SHA --after SHA [--signers-file FILE]
#
#   --before  tip of the branch before the push (all zeros: new branch)
#   --after   tip of the branch after the push
#   --signers-file  use this allowed-signers file instead of the one in the
#                   BEFORE revision (for tests)
#
# The allowed signers come from the revision BEFORE the push (.gitea/allowed_signers
# there), never from the pushed commits. A commit that adds its own key to the
# file therefore cannot approve itself. Without a usable file (not there yet, or
# no key in it) the check is in bootstrap mode: it warns and passes.
#
# Exit codes: 0 all good (or bootstrap), 1 at least one commit failed, 2 misuse.
set -u

ZERO=0000000000000000000000000000000000000000
SIGNERS_PATH=.gitea/allowed_signers

before=
after=
signers_file=

usage() { sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; }
die() { echo "ABORT $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case $1 in
    --before) before=${2:-}; shift 2 ;;
    --after) after=${2:-}; shift 2 ;;
    --signers-file) signers_file=${2:-}; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -n "$before" ] || die "--before is missing"
[ -n "$after" ] || die "--after is missing"
git cat-file -e "$after^{commit}" 2> /dev/null || die "commit $after is not in this clone"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# ---------- Which commits are new?
have_before=0
if [ "$before" != "$ZERO" ] && git cat-file -e "$before^{commit}" 2> /dev/null; then
  have_before=1
fi
if [ "$have_before" = 1 ]; then
  git rev-list "$before..$after" > "$tmp/commits"
else
  # New branch (or the old tip is gone after a force-push): everything that no
  # other remote branch or tag already contains.
  git for-each-ref --format='%(objectname)' refs/remotes/origin refs/tags | grep -v "^$after\$" | sort -u > "$tmp/others"
  if [ -s "$tmp/others" ]; then
    # shellcheck disable=SC2046
    git rev-list "$after" --not $(cat "$tmp/others") > "$tmp/commits"
  else
    git rev-list "$after" > "$tmp/commits"
  fi
fi

# ---------- Allowed signers from the base revision
base=
if [ "$have_before" = 1 ]; then
  base=$before
elif git cat-file -e "refs/remotes/origin/main^{commit}" 2> /dev/null; then
  base=refs/remotes/origin/main
fi
if [ -n "$signers_file" ]; then
  [ -f "$signers_file" ] || die "signers file not found: $signers_file"
  cp "$signers_file" "$tmp/signers"
elif [ -n "$base" ] && git cat-file -e "$base:$SIGNERS_PATH" 2> /dev/null; then
  git show "$base:$SIGNERS_PATH" > "$tmp/signers"
else
  : > "$tmp/signers"
fi
keys=$(grep -cvE '^[[:space:]]*(#|$)' "$tmp/signers" || true)
if [ "${keys:-0}" -eq 0 ]; then
  echo "BOOTSTRAP no allowed signer in the base revision ($SIGNERS_PATH): signature check skipped"
  echo "BOOTSTRAP Add a key with scripts/setup-signing.sh and push it to main to switch the check on."
  exit 0
fi

# ---------- Verify
total=0
failed=0
while read -r c; do
  [ -n "$c" ] || continue
  total=$((total + 1))
  short=$(git rev-parse --short "$c")
  subject=$(git log -1 --format=%s "$c")
  if git -c gpg.format=ssh -c "gpg.ssh.allowedSignersFile=$tmp/signers" verify-commit "$c" > /dev/null 2>&1; then
    echo "OK   $short $subject"
  else
    echo "FAIL $short $subject (unsigned, or not signed by an allowed signer)"
    failed=$((failed + 1))
  fi
done < "$tmp/commits"

echo "Checked $total commit(s), $failed failed."
[ "$failed" -eq 0 ]
