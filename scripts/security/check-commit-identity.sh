#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
# Fails when a commit carries a personal e-mail address (author or committer) in the public history.
# The address of a commit is public the moment the repository is, and it cannot be removed afterwards without
# rewriting history. Allowed: GitHub noreply addresses, noreply@example.* and the reserved domains.
#
#   bash scripts/security/check-commit-identity.sh [RANGE]      RANGE as for git log, default: everything reachable from HEAD
#   ALLOWED_COMMIT_EMAILS='regex'   extra addresses that are fine (maintainers who decided to be public), ERE, whole address
#
# Names are not checked (a name is not an address). Findings print the commit id and the role, never the address.
# Exit code: 0 clean, 1 at least one commit with a personal address, 2 usage or not a git repository.
set -u
cd "$(dirname "$0")/../.." || exit 2
git rev-parse --git-dir > /dev/null 2>&1 || { echo "check-commit-identity: not a git repository" >&2; exit 2; }
range=${1:-HEAD}
# A new branch has no previous tip (pre-push hook: FROM_REF is all zeros): then everything reachable counts.
case "$range" in 0000000*..*) range=${range#*..} ;; esac
extra=${ALLOWED_COMMIT_EMAILS:-}
base='^([0-9]+\+)?[A-Za-z0-9._-]+(\[bot\])?@users\.noreply\.github\.com$|^noreply@github\.com$|^noreply@example\.(org|com|net)$|^[^@]+@([A-Za-z0-9-]+\.)*(example\.(org|com|net)|test|invalid|localhost)$'
bad=0
total=0
while IFS=' ' read -r sha ae ce; do
  [ -n "$sha" ] || continue
  total=$((total + 1))
  for role in author committer; do
    if [ "$role" = author ]; then mail=$ae; else mail=$ce; fi
    if printf '%s' "$mail" | grep -Eq "$base"; then continue; fi
    if [ -n "$extra" ] && printf '%s' "$mail" | grep -Eq "^($extra)$"; then continue; fi
    echo "  ${sha:0:10}  $role address is not a noreply address"
    bad=$((bad + 1))
  done
done < <(git log --format='%H %ae %ce' "$range" 2> /dev/null)
if [ "$total" -eq 0 ]; then
  echo "check-commit-identity: no commits in '$range'" >&2
  exit 2
fi
echo "check-commit-identity: $total commit(s), $bad personal address(es)"
[ "$bad" -eq 0 ]
