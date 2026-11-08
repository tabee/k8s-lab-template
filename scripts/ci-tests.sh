#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
# All offline test suites of the repository, one after the other (they share ~/.cache/lab-sh-tests).
# Auto-discovers lab-sh, lab-sh-secrets and lab-sh-restore; tests/helpers contains sourced setup only.
# The ONE place for the list: every tests/*-tests.sh. The CI workflow (.github/workflows/lint.yml)
# and the release runner call this file, so a new suite is picked up without touching either.
# No cluster, no VM and no secrets are needed; a suite whose tool is missing prints SKIP and
# exits 0 (the summary shows how many).
#
#   bash scripts/ci-tests.sh              run all suites
#   bash scripts/ci-tests.sh egress pins  only these (name = file name without -tests.sh)
#
# Exit code: 0 = every suite green, 1 = at least one suite red, 2 = usage error or no suite found.
set -u
umask 0002
cd "$(dirname "$0")/.." || exit 2
root=$PWD

suites=()
for f in tests/*-tests.sh; do
  [ -f "$f" ] || continue
  name=${f#tests/}
  name=${name%-tests.sh}
  if [ $# -eq 0 ]; then
    suites+=("$name")
    continue
  fi
  for want in "$@"; do
    [ "$want" = "$name" ] && suites+=("$name")
  done
done
if [ ${#suites[@]} -eq 0 ]; then
  echo "usage: bash scripts/ci-tests.sh [SUITE...]   (no suite found for: ${*:-tests/*-tests.sh})" >&2
  exit 2
fi
for want in "$@"; do
  [ -f "tests/$want-tests.sh" ] || {
    echo "usage: bash scripts/ci-tests.sh [SUITE...]   (tests/$want-tests.sh does not exist)" >&2
    exit 2
  }
done

log=$(mktemp -d)
trap 'rm -rf "$log"' EXIT

# Public clone (ADR 0022): secrets/ lives in the private secrets repo, the export only ships
# secrets.example/. The suites read secrets/, so they run against a copy seeded from the
# templates. The checkout itself is never touched.
if [ ! -e secrets ] && [ -d secrets.example ]; then
  mkdir "$log/repo"
  cp -a . "$log/repo/"
  cp -a secrets.example "$log/repo/secrets"
  root=$log/repo
  cd "$root" || exit 2
  echo "NOTE secrets/ is missing: suites run against a copy seeded from secrets.example/ (ADR 0022)"
fi
red=0
summary=()
for name in "${suites[@]}"; do
  echo "::: tests/$name-tests.sh"
  start=$SECONDS
  bash "tests/$name-tests.sh" "$root" 2>&1 | tee "$log/$name.log"
  rc=${PIPESTATUS[0]}
  n_ok=$(grep -c '^OK ' "$log/$name.log")
  n_fail=$(grep -c '^FAIL ' "$log/$name.log")
  n_skip=$(grep -c 'SKIP' "$log/$name.log")
  state=ok
  if [ "$rc" -ne 0 ] || [ "$n_fail" -ne 0 ]; then
    state=RED
    red=$((red + 1))
  fi
  summary+=("$(printf '%-28s %-4s ok=%-4s fail=%-3s skip=%-3s %ss' "$name" "$state" "$n_ok" "$n_fail" "$n_skip" "$((SECONDS - start))")")
done

echo
echo "Summary (${#suites[@]} suites):"
printf '  %s\n' "${summary[@]}"
if [ "$red" -ne 0 ]; then
  echo "RED: $red suite(s) failed" >&2
  exit 1
fi
echo "All suites green."
if grep -l 'SKIP' "$log"/*.log > /dev/null 2>&1; then
  echo "A SKIP line above names the missing tool and how to install it (the security tools: bash scripts/install-security-tools.sh," >&2
  echo "the Python ones: pip install --require-hashes -r ci/requirements-security.txt). A skipped suite is not a green one." >&2
fi
