#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
# Security and privacy checks for the repository, the ONE place for the rules (docs/concepts/public-release-security.md).
# The CI workflows (GitHub Actions: .github/workflows/security.yml, Gitea Actions: .github/workflows/security.yml),
# the pre-commit hook and the local runner all call this file, so the rules never drift apart.
#
#   bash scripts/security-scan.sh [--strict] [CHECK...]      run the checks (default: all that apply)
#   bash scripts/security-scan.sh --list                      list the checks
#
#   secrets      gitleaks (working tree and history) and trufflehog (working tree and history), values never printed
#   pii          personal data: generic rules (AHV, IBAN, phone, e-mail, Matrix ID, date of birth) and, when the
#                CI secret PII_DENYLIST (or PII_DENYLIST_FILE) is set, the private deny list as anonymous rules
#   trivy        trivy fs: secrets, misconfiguration of Kubernetes/Helm/Terraform/Dockerfiles, vulnerable lockfiles
#                (gate: HIGH and CRITICAL, exceptions: .trivyignore.yaml)
#   kubeconform  helm template of every chart and all plain manifests against the Kubernetes schemas
#   actions      actionlint and zizmor on the workflow files (.github/workflows and .gitea/workflows)
#   lint         yamllint and shellcheck (scripts/ci-lint.sh)
#   tree         positive list for the public tree: no real host, e-mail or public IP outside allowed-hosts.txt,
#                no SOPS ciphertext, no key files (scripts/security/check-public-tree.py)
#   identity     no personal e-mail address in the commits (scripts/security/check-commit-identity.sh)
#   export       PRIVATE repo only: builds the public version in a temporary folder (scripts/public/lab-public.py,
#                with guard and gitleaks) and runs ALL checks above on the result, with the private deny list
#
# Default: in the private repo (scripts/public exists) secrets, trivy, kubeconform, actions, lint and export (the
# personal-data checks pii, tree and identity run inside export, on the public version: the private repo contains the
# real domain and address by design); in the public tree all except export. Tool versions: ci/security-tools.env, installer: scripts/install-security-tools.sh.
#
# A missing tool is a SKIP with an install hint, never a silent green. With --strict (CI) a SKIP is a failure.
# Exit code: 0 = all selected checks green, 1 = at least one red (wins), 2 = nothing red, but a tool is missing,
#            3 = usage error.
set -u
cd "$(dirname "$0")/.." || exit 3
root=$PWD
export LC_ALL=C

strict=0
selected=()
for arg in "$@"; do
  case "$arg" in
    --strict) strict=1 ;;
    --list)
      printf '%s\n' "secrets: gitleaks and trufflehog, working tree and history" "pii: personal data (generic rules, private deny list from PII_DENYLIST)" \
        "trivy: secrets, misconfiguration, vulnerable lockfiles" "kubeconform: helm template and plain manifests against the schemas" \
        "actions: actionlint and zizmor on the workflow files" "lint: yamllint and shellcheck" \
        "tree: public tree positive list (hosts, e-mails, IPs, key files)" "identity: no personal e-mail address in the commits" \
        "export: private repo only, builds the public version and runs everything on it"
      exit 0
      ;;
    -h | --help)
      sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    secrets | pii | trivy | kubeconform | actions | lint | tree | identity | export) selected+=("$arg") ;;
    *)
      echo "usage: bash scripts/security-scan.sh [--strict] [secrets|pii|trivy|kubeconform|actions|lint|tree|identity|export ...]" >&2
      exit 3
      ;;
  esac
done

private=0
[ -f scripts/public/lab-public.py ] && private=1
if [ ${#selected[@]} -eq 0 ]; then
  # Private: the personal-data checks (pii, tree, identity) make sense only on the export, which "export" runs.
  if [ "$private" = 1 ]; then selected=(secrets trivy kubeconform actions lint export); else selected=(secrets pii trivy kubeconform actions lint tree identity); fi
fi

red=()
skipped=()
passed=()
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

hint() {
  case "$1" in
    gitleaks | trivy | trufflehog | kubeconform | actionlint | helm) echo "bash scripts/install-security-tools.sh   (pinned versions, SHA-256 checked; then PATH=\$HOME/.local/bin:\$PATH)" ;;
    zizmor) echo "bash scripts/install-tools.sh   (pinned version, SHA-256 checked)" ;;
    yamllint | shellcheck) echo "pip install --require-hashes -r ci/requirements-lint.txt" ;;
    *) echo "see docs/how-to/security-scan.md" ;;
  esac
}
# need TOOL...: true when all tools are installed; otherwise prints SKIP with the hint and returns 1.
need() {
  local t
  for t in "$@"; do
    if ! command -v "$t" > /dev/null 2>&1; then
      echo "SKIP $CHECK: $t is not installed. Install: $(hint "$t")" >&2
      SKIP_REASON="$t missing"
      return 1
    fi
  done
  return 0
}
# gitleaks 8.19+ has the subcommand "dir" (the apt package of Ubuntu is older and answers every call with an error).
need_gitleaks() {
  need gitleaks || return 1
  if ! gitleaks dir --help > /dev/null 2>&1; then
    echo "SKIP $CHECK: gitleaks is too old (no subcommand 'dir', needs 8.19 or newer). Install: $(hint gitleaks)" >&2
    SKIP_REASON="gitleaks too old"
    return 1
  fi
}
# prepare_worktree: sets WT to the folder the working-tree scanners (gitleaks dir, trufflehog filesystem, trivy fs) read.
# That is exactly what git would commit: tracked files plus untracked files that are NOT ignored (git ls-files -co
# --exclude-standard, so .gitignore, nested .gitignore files, .git/info/exclude and the global excludes all apply),
# with the current content on disk. Ignored folders (.ansible/ with installed Galaxy collections, venvs, caches, build
# output) are third-party or generated and out of scope. One staged copy gives all scanners the same file set and the
# same path semantics; per-tool skip lists (--skip-dirs, --exclude-paths, config allowlists) would differ in syntax and
# in how they match paths, and would have to be kept in sync with .gitignore by hand. Outside a git checkout (archive,
# export folder) there is nothing to ask git, so WT is the folder itself, as before.
WT=""
prepare_worktree() {
  [ -n "$WT" ] && return 0
  WT=$root
  if [ "$(git rev-parse --show-toplevel 2> /dev/null)" != "$root" ]; then
    echo "working tree: not a git checkout here, scanning the whole folder" >&2
    return 0
  fi
  local copy="$tmp/worktree"
  mkdir -p "$copy"
  # --ignore-failed-read: a tracked file that was deleted on disk (not yet committed) is still in the index.
  if ! git ls-files -z -co --exclude-standard | tar --null --ignore-failed-read -T - -cf - 2> /dev/null | tar -xf - -C "$copy"; then
    echo "working tree: staging the file list failed, scanning the whole folder" >&2
    rm -rf "$copy"
    return 0
  fi
  WT=$copy
  echo "working tree: $(find "$copy" -type f | wc -l | tr -d ' ') files (tracked or untracked and not ignored; ignored folders are out of scope)"
}
have_history() { git rev-parse --git-dir > /dev/null 2>&1 && [ "$(git rev-list --count HEAD 2> /dev/null || echo 0)" -gt 0 ]; }

# Every check_* returns 0 green, 1 red, 3 skipped (SKIP_REASON set).
check_secrets() {
  need_gitleaks || return 3
  local rc=0
  # Same options as scripts/gitleaks-local.sh --direct: no inline allow comments, central exceptions in .gitleaks.toml.
  local common=(--redact --no-banner --no-color --verbose --exit-code 1 --ignore-gitleaks-allow)
  prepare_worktree
  echo "gitleaks dir (working tree, values redacted)"
  # Relative config path is resolved against the folder gitleaks runs in, so it is made absolute.
  (cd "$WT" && gitleaks dir "${common[@]}" --config "$root/.gitleaks.toml" .) || rc=1
  if have_history; then
    echo "gitleaks git (history of $(git rev-list --count HEAD) commits, values redacted)"
    # .gitleaksignore (history fingerprints, private repo only) is read from the repo root, the source folder "."
    gitleaks git "${common[@]}" --config .gitleaks.toml . || rc=1
  else
    echo "gitleaks git: no git history here (archive or export folder), skipped"
  fi
  if command -v trufflehog > /dev/null 2>&1; then
    local th_opts=(--no-verification --no-update --json --exclude-paths "$root/ci/trufflehog-exclude.txt")
    local what
    for what in filesystem git; do
      if [ "$what" = git ]; then have_history || continue; fi
      echo "trufflehog $what (unverified detectors, values not printed)"
      local target=. dir=$WT
      [ "$what" = git ] && { target="file://$PWD"; dir=$root; }
      if ! (cd "$dir" && trufflehog "$what" "$target" "${th_opts[@]}") > "$tmp/th.json" 2> "$tmp/th.err"; then
        echo "trufflehog failed: $(tail -n 2 "$tmp/th.err")" >&2
        rc=1
        continue
      fi
      python3 scripts/security/summarize.py trufflehog < "$tmp/th.json" || rc=1
    done
  else
    echo "SKIP secrets/trufflehog: not installed. Install: $(hint trufflehog)" >&2
    SKIP_REASON="trufflehog missing (gitleaks ran)"
    [ "$rc" -eq 0 ] && return 3
  fi
  return $rc
}

# pii_run CONFIG LABEL HIDE_PATH_FLAG: gitleaks dir (+ git) with a personal-data config, only redacted summaries are printed.
pii_run() {
  local cfg=$1 label=$2 hide=${3:-} rc=0 mode
  local modes=(dir)
  have_history && modes+=(git)
  prepare_worktree
  # The config is read from the folder gitleaks runs in, so a relative path is made absolute.
  case "$cfg" in /*) ;; *) cfg="$root/$cfg" ;; esac
  for mode in "${modes[@]}"; do
    rm -f "$tmp/pii.json"
    local src=$root
    [ "$mode" = dir ] && src=$WT
    (cd "$src" && gitleaks "$mode" . --config "$cfg" --no-banner --no-color --redact --ignore-gitleaks-allow \
      --report-format json --report-path "$tmp/pii.json" --exit-code 1) > "$tmp/pii.log" 2>&1
    local g=$?
    if [ "$g" -ne 0 ] && [ "$g" -ne 1 ]; then
      echo "gitleaks ($label, $mode) failed with exit code $g (config error?)" >&2
      rc=1
      continue
    fi
    echo "$label, gitleaks $mode:"
    python3 scripts/security/summarize.py gitleaks "$tmp/pii.json" $hide || rc=1
  done
  return $rc
}

check_pii() {
  need_gitleaks || return 3
  local rc=0
  pii_run scripts/security/gitleaks-pii.toml "generic personal-data rules" || rc=1
  local list=${PII_DENYLIST_FILE:-}
  if [ -n "${PII_DENYLIST:-}" ] || [ -n "$list" ]; then
    local gen="$tmp/private-pii.toml"
    if [ -n "$list" ]; then python3 scripts/security/pii-config.py "$gen" --file "$list"; else python3 scripts/security/pii-config.py "$gen"; fi
    local g=$?
    if [ "$g" -ne 0 ]; then
      echo "private deny list could not be converted (exit $g)" >&2
      return 1
    fi
    pii_run "$gen" "private deny list (anonymous rules, paths hidden)" --hide-path-rules || rc=1
  else
    echo "private deny list: not set (CI secret PII_DENYLIST). Only the generic rules ran: names, domains and home addresses of the operator are NOT covered." >&2
    [ "$rc" -eq 0 ] && PII_NOTE=1
  fi
  return $rc
}

check_trivy() {
  need trivy || return 3
  prepare_worktree
  echo "trivy fs: secret, misconfig, vuln; HIGH and CRITICAL fail (exceptions: .trivyignore.yaml)"
  (cd "$WT" && trivy fs --quiet --scanners secret,misconfig,vuln --severity HIGH,CRITICAL --exit-code 1 \
    --skip-dirs .git --ignorefile "$root/.trivyignore.yaml" .)
}

check_kubeconform() {
  need kubeconform helm || return 3
  # shellcheck source=ci/security-tools.env
  . ci/security-tools.env
  local out="$tmp/render" c name rc=0
  mkdir -p "$out"
  for c in gitops/charts/*/; do
    name=$(basename "$c")
    local args=()
    # Charts that need values to render at all (the values are made-up and only serve the schema check).
    [ "$name" = notes-site ] && args=(--set site.name=t --set site.host=t.example.test --set site.repo=ssh://git@x/y.git)
    if ! helm template "$name" "$c" --namespace "$name" "${args[@]}" > "$out/$name.yaml" 2> "$out/$name.err"; then
      echo "helm template $name failed:" >&2
      tail -n 5 "$out/$name.err" >&2
      rc=1
    fi
  done
  # Plain manifests: everything with a "kind:" under gitops/ and secrets/ that is not a chart or an encrypted secret.
  local plain=()
  mapfile -t plain < <(git ls-files 'gitops/*.yaml' 'secrets/*.yaml' 2> /dev/null | grep -vE '\.sops\.yaml$|^gitops/charts/' | xargs -r grep -lE '^kind: ' 2> /dev/null)
  echo "kubeconform: ${#plain[@]} plain manifests and $(find "$out" -name '*.yaml' | wc -l | tr -d ' ') rendered charts, Kubernetes $KUBERNETES_VERSION, strict"
  local cache="${XDG_CACHE_HOME:-$HOME/.cache}/kubeconform"
  mkdir -p "$cache"
  # Custom resources (Argo CD, cert-manager, CloudNativePG, ...) are checked against the community schema catalog.
  # ksops: the KSOPS generator files (secrets/*/ksops.yaml) are no Kubernetes objects and have no schema.
  kubeconform -summary -strict -kubernetes-version "$KUBERNETES_VERSION" -cache "$cache" \
    -skip ksops -schema-location default \
    -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
    "${plain[@]}" "$out"/*.yaml || rc=1
  return $rc
}

check_actions() {
  local files=() rc=0 skip=0
  mapfile -t files < <(ls .github/workflows/*.yml .github/workflows/*.yaml .gitea/workflows/*.yml .gitea/workflows/*.yaml 2> /dev/null)
  [ ${#files[@]} -gt 0 ] || { echo "no workflow files"; return 0; }
  if need actionlint; then
    echo "actionlint: ${#files[@]} workflow files"
    actionlint -color=false "${files[@]}" || rc=1
  else
    skip=1
  fi
  if need zizmor; then
    local z=(zizmor --no-progress --format plain)
    # With a token zizmor also asks GitHub (impostor commits, known-vulnerable actions); without, offline audits only.
    if [ -z "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]; then z+=(--offline); else export GH_TOKEN=${GH_TOKEN:-$GITHUB_TOKEN}; fi
    echo "zizmor: ${#files[@]} workflow files (${z[*]:3})"
    "${z[@]}" "${files[@]}" || rc=1
  else
    skip=1
  fi
  [ "$rc" -eq 0 ] && [ "$skip" -eq 1 ] && return 3
  return $rc
}

check_lint() {
  bash scripts/ci-lint.sh yaml
  local a=$?
  bash scripts/ci-lint.sh shell
  local b=$?
  [ "$a" -eq 1 ] || [ "$b" -eq 1 ] && return 1
  [ "$a" -eq 2 ] || [ "$b" -eq 2 ] && { SKIP_REASON="yamllint or shellcheck missing"; return 3; }
  return 0
}

check_tree() {
  echo "check-public-tree.py (positive list: scripts/security/allowed-hosts.txt)"
  python3 scripts/security/check-public-tree.py --root . --walk
}

check_identity() {
  bash scripts/security/check-commit-identity.sh "${IDENTITY_RANGE:-HEAD}"
}

check_export() {
  if [ "$private" != 1 ]; then
    echo "export: only in the private repository (scripts/public is not part of the public version)"
    return 0
  fi
  need gitleaks python3 git || return 3
  need_gitleaks || return 3
  local out="$tmp/export"
  echo "building the public version from the committed HEAD ($(git rev-parse --short HEAD)); uncommitted changes are NOT part of it"
  # --git-init: the real thing, with the neutral single commit; guard and gitleaks run inside and are required.
  python3 scripts/public/lab-public.py "$out" --git-init --yes || return 1
  [ -d "$out" ] || { echo "export folder was not created" >&2; return 1; }
  # Checks of the public version, run by the public version's own script, with the private deny list on top.
  local sel=(secrets pii trivy kubeconform actions lint tree identity) st=()
  [ "$strict" = 1 ] && st=(--strict)
  (cd "$out" && PII_DENYLIST_FILE="$root/scripts/public/denylist.txt" IDENTITY_RANGE=HEAD bash scripts/security-scan.sh "${st[@]}" "${sel[@]}")
  local rc=$?
  # rc 2 (a tool is missing) is reported as such by the inner run; here it is a skip of the export check as a whole.
  [ "$rc" -eq 2 ] && { SKIP_REASON="inner run: a tool is missing"; return 3; }
  return $rc
}

PII_NOTE=0
for CHECK in "${selected[@]}"; do
  echo
  echo "=== $CHECK ==="
  SKIP_REASON=""
  start=$SECONDS
  "check_$CHECK"
  rc=$?
  took=$((SECONDS - start))
  case $rc in
    0) passed+=("$CHECK (${took}s)"); echo "PASS $CHECK" ;;
    3) skipped+=("$CHECK: $SKIP_REASON"); echo "SKIP $CHECK: $SKIP_REASON" ;;
    *) red+=("$CHECK"); echo "FAIL $CHECK" >&2 ;;
  esac
done

echo
echo "Summary:"
[ ${#passed[@]} -gt 0 ] && printf '  PASS %s\n' "${passed[@]}"
[ ${#skipped[@]} -gt 0 ] && printf '  SKIP %s\n' "${skipped[@]}"
[ ${#red[@]} -gt 0 ] && printf '  FAIL %s\n' "${red[@]}"
[ "$PII_NOTE" = 1 ] && echo "  NOTE the private deny list was not used (PII_DENYLIST not set): operator names, domains and addresses are not covered"
if [ ${#red[@]} -gt 0 ]; then
  echo "RED: ${#red[@]} check(s) failed" >&2
  exit 1
fi
if [ ${#skipped[@]} -gt 0 ]; then
  if [ "$strict" = 1 ]; then
    echo "RED (--strict): ${#skipped[@]} check(s) did not run completely" >&2
    exit 1
  fi
  echo "Not everything ran (a tool is missing, see SKIP above)."
  exit 2
fi
echo "All selected checks green."
