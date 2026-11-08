#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
# Static checks for the whole repository, no cluster needed (issue #10).
# The ONE place for the lint rules: the CI workflow (.github/workflows/lint.yml) and the local
# runner scripts call this file, so the rules never drift apart.
#
#   bash scripts/ci-lint.sh            run all three checks
#   bash scripts/ci-lint.sh yaml       only yamllint
#   bash scripts/ci-lint.sh shell      only shellcheck
#   bash scripts/ci-lint.sh ansible    only ansible-lint (profile and excludes: ansible/.ansible-lint)
#
# A tool that is not installed is a SKIP with an install hint, never a red check:
#   - one single check (yaml, shell, ansible): exit 2 when its tool is missing
#   - all: runs every check whose tool is there, prints SKIP for the others
# Exit code: 0 = all selected checks green, 1 = at least one red (wins over everything),
#            2 = no check was red, but at least one tool is missing (so not everything ran).
set -u
cd "$(dirname "$0")/.." || exit 2

YAMLLINT_CONFIG='{extends: relaxed, rules: {line-length: {max: 200}}}'
SHELLCHECK_SEVERITY=warning
SKIP_HELM_TEMPLATES='^gitops/charts/[^/]+/templates/'

want=${1:-all}
case "$want" in
  all | yaml | shell | ansible) ;;
  *)
    echo "usage: bash scripts/ci-lint.sh [all|yaml|shell|ansible]" >&2
    exit 2
    ;;
esac

red=0
skipped=()
hint() {
  case "$1" in
    yamllint) echo "pipx install yamllint   (or: sudo apt install yamllint)" ;;
    shellcheck) echo "sudo apt install shellcheck   (or: pipx install shellcheck-py)" ;;
    ansible-lint) echo "pipx install ansible-lint   (or: pip install --user ansible-lint)" ;;
  esac
}
# have TOOL: true when the tool is installed; otherwise prints a SKIP line with the hint and remembers it.
have() {
  command -v "$1" > /dev/null 2>&1 && return 0
  echo "SKIP $1: not installed. Install: $(hint "$1") (CI installs the pinned versions from ci/requirements-lint.txt)" >&2
  skipped+=("$1")
  return 1
}

run_yaml() {
  have yamllint || return 0
  local files
  mapfile -t files < <(git ls-files '*.yml' '*.yaml' | grep -Ev "$SKIP_HELM_TEMPLATES")
  echo "yamllint: ${#files[@]} files (Helm templates are checked by helm template, not here)"
  yamllint -d "$YAMLLINT_CONFIG" "${files[@]}" || red=1
}

run_shell() {
  have shellcheck || return 0
  local files
  mapfile -t files < <(git ls-files 'scripts/*.sh' 'ansible/scripts/*.sh' 'tests/*.sh')
  echo "shellcheck: ${#files[@]} files, severity ${SHELLCHECK_SEVERITY}"
  # CI job pods have 512 MiB. Lint sequentially; split large test files instead of skipping checks.
  local file
  for file in "${files[@]}"; do
    shellcheck -S "$SHELLCHECK_SEVERITY" "$file" || red=1
  done
}

run_ansible() {
  have ansible-lint || return 0
  echo "ansible-lint: ansible/ (config ansible/.ansible-lint)"
  (cd ansible && ansible-lint) || red=1
}

case "$want" in
  all)
    run_yaml
    run_shell
    run_ansible
    ;;
  yaml) run_yaml ;;
  shell) run_shell ;;
  ansible) run_ansible ;;
esac

if [ "$red" != 0 ]; then
  echo "ci-lint: RED ($want)"
  exit 1
fi
if [ "${#skipped[@]}" != 0 ]; then
  echo "ci-lint: no check was red, but NOT everything ran (SKIP: ${skipped[*]}). Install the tools above for the full result."
  exit 2
fi
echo "ci-lint: OK ($want)"
exit 0
