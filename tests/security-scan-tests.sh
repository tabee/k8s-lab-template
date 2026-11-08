#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
# Tests for scripts/security-scan.sh and the helpers in scripts/security/: every check must turn RED on a planted
# violation, stay green on a clean tree, never print the planted value, and a missing tool must be a SKIP (exit 2),
# red under --strict. No cluster and no secrets; trivy and kubeconform are not run here (they need downloads), they are
# part of the CI run of scripts/security-scan.sh itself.
# The planted values are assembled at runtime, never written as plaintext in this file (this file is public).
# Needs: git, python3; gitleaks (>= 8.19), actionlint, zizmor are used when installed (else a SKIP line with the install hint).
# Usage: bash tests/security-scan-tests.sh [repo root]
set -u
# Fake personal hosts are assembled at run time so that the test file itself passes the personal-data and host checks.
EXAMPLE_ORG="example-person$(printf "%s" .)org"
ACME_COM="acme-widgets$(printf "%s" .)com"
R=$(cd "${1:-$(dirname "${BASH_SOURCE[0]}")/..}" && pwd -P)
mkdir -p "$HOME/.cache/lab-sh-tests"
T=$(mktemp -d -p "$HOME/.cache/lab-sh-tests")
# shellcheck disable=SC2064
trap "rm -rf '$T'" EXIT
fail=0
n=0
ok() { n=$((n + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else echo "FAIL $1 (is '$2', want '$3')"; fail=$((fail + 1)); fi; }
rc() { "$@" > /dev/null 2>&1; echo $?; }
git_neutral() { git -c user.name=t -c user.email=t@example.org -c commit.gpgsign=false "$@"; }
have() { command -v "$1" > /dev/null 2>&1; }
skip() { echo "SKIP: $1 is not installed ($2): the checks that need it do not run here"; }

# A fresh small repository with the real scripts and configs, one clean commit.
mini() {
  local d=$T/$1
  rm -rf "$d"
  mkdir -p "$d/scripts" "$d/ci" "$d/.gitea/workflows"
  cp -r "$R/scripts/security" "$d/scripts/"
  cp "$R/scripts/security-scan.sh" "$R/scripts/ci-lint.sh" "$d/scripts/"
  cp "$R/ci/security-tools.env" "$R/ci/control-tools.env" "$R/ci/trufflehog-exclude.txt" "$d/ci/"
  cp "$R/.gitleaks.toml" "$R/.trivyignore.yaml" "$d/"
  cp "$R/.github/workflows/security.yml" "$d/.gitea/workflows/"
  printf '# demo\nNothing personal in here.\n' > "$d/README.md"
  (cd "$d" && git init -q -b main && git add -A && git_neutral commit -q -m clean)
  echo "$d"
}
# commit_all DIR: commit the planted file
commit_all() { (cd "$1" && git add -A && git_neutral commit -q -m planted); }
scan() { (cd "$1" && shift && bash scripts/security-scan.sh "$@"); }

echo "== 1. usage"
D=$(mini usage)
ok "unknown check name is a usage error (3)" "$(rc scan "$D" nonsense)" 3
ok "--list names all nine checks" "$(scan "$D" --list | grep -Ec '^(secrets|pii|trivy|kubeconform|actions|lint|tree|identity|export):')" 9
ok "--help prints the header and exits 0" "$(rc scan "$D" --help)" 0

echo "== 2. a missing tool is a SKIP with an install hint (exit 2), red under --strict"
# A PATH with the basics but without any scanner.
NB=$T/nobin
mkdir -p "$NB"
for t in bash env git python3 mktemp rm cat sed grep tr cut ls wc head tail dirname basename sort uniq printf xargs find mkdir date awk id uname mv cp chmod ln readlink; do
  p=$(command -v "$t" 2> /dev/null) && ln -sf "$p" "$NB/$t"
done
(cd "$D" && PATH=$NB bash scripts/security-scan.sh secrets > "$T/nobin.log" 2>&1)
ok "without gitleaks the secrets check exits 2" "$?" 2
ok "the SKIP line names the tool and the installer" "$(grep -c 'SKIP secrets: gitleaks is not installed. Install: bash scripts/install-security-tools.sh' "$T/nobin.log")" 1
(cd "$D" && PATH=$NB bash scripts/security-scan.sh --strict secrets > "$T/nobin2.log" 2>&1)
ok "without gitleaks --strict is red (1)" "$?" 1
(cd "$D" && PATH=$NB bash scripts/security-scan.sh actions > "$T/nobin3.log" 2>&1)
ok "without actionlint and zizmor the actions check exits 2" "$?" 2
(cd "$D" && PATH=$NB bash scripts/security-scan.sh trivy > "$T/nobin4.log" 2>&1)
ok "without trivy the trivy check exits 2" "$?" 2
ok "the summary says that not everything ran" "$(grep -c 'Not everything ran' "$T/nobin4.log")" 1

echo "== 3. identity: a personal commit address is red, noreply is green"
if have git; then
  D=$(mini ident)
  ok "clean history is green" "$(rc scan "$D" identity)" 0
  (cd "$D" && echo x >> README.md && git add -A && git -c user.name=t -c "user.email=$(printf 'someone%s%s' @ "$EXAMPLE_ORG")" -c commit.gpgsign=false commit -q -m personal)
  ok "a personal author address is red" "$(rc scan "$D" identity)" 1
  ok "the address itself is not printed" "$(scan "$D" identity 2>&1 | grep -c 'example-person')" 0
  (cd "$D" && git -c user.name=t -c user.email=t@example.org -c commit.gpgsign=false commit -q --allow-empty -m later)
  ok "only the new commits can be checked (range)" "$(cd "$D" && IDENTITY_RANGE=HEAD~1..HEAD bash scripts/security-scan.sh identity > /dev/null 2>&1; echo $?)" 0
  ok "the whole history stays red" "$(rc scan "$D" identity)" 1
  (cd "$D" && git -c user.name=t -c "user.email=12345+name@users.noreply.github.com" -c commit.gpgsign=false commit -q --allow-empty -m gh)
  ok "ALLOWED_COMMIT_EMAILS allows a maintainer on purpose" "$(cd "$D" && ALLOWED_COMMIT_EMAILS='[a-z]+@example-person\.org' IDENTITY_RANGE=HEAD bash scripts/security-scan.sh identity > /dev/null 2>&1; echo $?)" 0
fi

echo "== 4. public tree: hosts, e-mails, keys, SOPS ciphertext"
D=$(mini tree)
ok "clean tree is green" "$(rc scan "$D" tree)" 0
host="intranet.acme-widgets.$(printf 'io')"
printf 'see https://%s/status\n' "$host" > "$D/notes.md"
ok "a real host name is red" "$(rc scan "$D" tree)" 1
ok "the host is not printed" "$(scan "$D" tree 2>&1 | grep -c 'acme-widgets')" 0
rm "$D/notes.md"
printf 'contact: %s\n' "jane.doe$(printf '@')${ACME_COM}" > "$D/notes.md"
ok "a real e-mail address is red" "$(rc scan "$D" tree)" 1
rm "$D/notes.md"
printf 'server: %s\n' "$(printf '%s.%s.%s.%s' 93 184 216 34)" > "$D/notes.md"
ok "a public IPv4 address is red" "$(rc scan "$D" tree)" 1
rm "$D/notes.md"
printf 'server: %s\n' "$(printf '%s.%s.%s.%s' 192 0 2 10)" > "$D/notes.md"
ok "a documentation IPv4 address (RFC 5737) is green" "$(rc scan "$D" tree)" 0
rm "$D/notes.md"
mkdir -p "$D/secrets/x"
printf 'sops:\n    age: []\n' > "$D/secrets/x/db.sops.yaml"
ok "a real *.sops.yaml file is red" "$(rc scan "$D" tree)" 1
rm -r "$D/secrets"
printf 'creation_rules: []\n' > "$D/.sops.yaml"
printf 'sops:\n' > "$D/db.sops.yaml.example"
ok "the SOPS config .sops.yaml and a *.example template are allowed" "$(rc scan "$D" tree)" 0
rm "$D/.sops.yaml" "$D/db.sops.yaml.example"
printf -- '-----BEGIN %s PRIVATE KEY-----\n' "OPENSSH" > "$D/key.txt"
ok "a private key block is red" "$(rc scan "$D" tree)" 1
rm "$D/key.txt"
mkdir -p "$D/secrets/x"
printf 'apiVersion: v1\nkind: Secret\n' > "$D/secrets/x/plain.yaml"
ok "any file under secrets/ is red (secrets-dir, ADR 0022)" "$(rc scan "$D" tree)" 1
ok "the finding is named secrets-dir" "$(scan "$D" tree 2>&1 | grep -c 'secrets-dir')" 1
printf 'sops:\n    age: []\n' > "$D/secrets/x/db.sops.yaml"
printf '/secrets/\n' > "$D/.gitignore"
ok "a git-ignored secrets/ (imported ciphertext) is not walked" "$(rc scan "$D" tree)" 0
ok "the skip is named" "$(scan "$D" tree 2>&1 | grep -c 'secrets/ is git-ignored')" 1
git -C "$D" add -f secrets/x/plain.yaml
ok "a tracked file under a git-ignored secrets/ is still red (git ls-files)" "$(cd "$D" && python3 scripts/security/check-public-tree.py --root . --allowed-hosts scripts/security/allowed-hosts.txt > /dev/null 2>&1; echo $?)" 1
git -C "$D" rm -q --cached secrets/x/plain.yaml
rm -r "$D/secrets" "$D/.gitignore"
printf -- '-----BEGIN %s PRIVATE KEY-----\n' "OPENSSH" > "$D/key.txt"
rm "$D/key.txt"
printf 'x\n' > "$D/id_ed25519"
ok "a key file name is red" "$(rc scan "$D" tree)" 1
rm "$D/id_ed25519"
ok "clean again" "$(rc scan "$D" tree)" 0

echo "== 5. secrets and personal data (gitleaks)"
if have gitleaks && gitleaks dir --help > /dev/null 2>&1; then
  D=$(mini secret)
  ok "clean tree: secrets green" "$(rc scan "$D" secrets)" 0
  ok "clean tree: pii green" "$(rc scan "$D" pii)" 0
  tok="ghp_$(python3 -c 'import secrets,string; print("".join(secrets.choice(string.ascii_letters + string.digits) for _ in range(36)))')"
  printf 'token = "%s"\n' "$tok" > "$D/config.txt"
  ok "a planted GitHub token is red (working tree)" "$(rc scan "$D" secrets)" 1
  ok "the token is not printed" "$(scan "$D" secrets 2>&1 | grep -c "$tok")" 0
  commit_all "$D"
  rm "$D/config.txt"
  commit_all "$D"
  ok "a token deleted again is still red (history)" "$(rc scan "$D" secrets)" 1
  ok "the history finding names the commit" "$(scan "$D" secrets 2>&1 | grep -c 'commit ')" 1

  # Personal data: each shape on its own line in a fresh repo. The values are assembled from parts.
  D=$(mini pii)
  {
    printf 'ahv %s\n' "756.$(printf '%s' 1234).$(printf '%s' 5678).97"
    printf 'iban %s\n' "CH56 0483 5012 3456 $(printf '%s' 7800) 9"
    printf 'phone %s\n' "+41 79 $(printf '%s' 555) 12 34"
    printf 'mail %s\n' "jane.doe$(printf '@')${ACME_COM}"
    printf 'chat %s\n' "$(printf '@')jane:matrix.${ACME_COM}"
    printf 'geboren am: 03.04.%s\n' "$(printf '%s' 1980)"
  } > "$D/people.md"
  scan "$D" pii > "$T/pii.log" 2>&1
  ok "planted personal data is red" "$?" 1
  for rule in pii-ahv-number pii-iban-ch-li pii-phone-number pii-email-address pii-matrix-user-id pii-date-of-birth; do
    ok "rule $rule fires" "$(grep -c "$rule" "$T/pii.log")" 1
  done
  ok "no value is printed (not the name, not the number)" "$(grep -Ec 'jane|acme-widgets|1234|0483' "$T/pii.log")" 0
  printf 'neutral %s and %s and %s\n' "alice$(printf '@')example.org" "$(printf '@')alice:matrix.example.org" "CH00 0000 0000 0000 0000 0" > "$D/people.md"
  ok "neutral addresses and the example IBAN are green" "$(rc scan "$D" pii)" 0
  printf 'clone git%s:owner/repo.git\n' "$(printf '@')github.com" > "$D/people.md"
  ok "the ssh user git@host is no personal address" "$(rc scan "$D" pii)" 0

  # Private deny list as CI secret: anonymous rules, the word never in the log
  word="zz$(printf 'quux')wombat"
  printf 'the %s was here\n' "$word" > "$D/people.md"
  ok "without the private deny list this word is not known (green, with a note)" "$(scan "$D" pii 2>&1 | grep -c 'NOT covered')" 1
  (cd "$D" && PII_DENYLIST="$(printf 'private-name\t%s' "$word")" bash scripts/security-scan.sh pii > "$T/pii2.log" 2>&1)
  ok "PII_DENYLIST: the private word is red" "$?" 1
  ok "PII_DENYLIST: the word is not in the log" "$(grep -c "$word" "$T/pii2.log")" 0
  ok "PII_DENYLIST: the rule name (also private) is not in the log" "$(grep -c 'private-name' "$T/pii2.log")" 0
  cp "$D/people.md" "$D/$word.txt"
  (cd "$D" && PII_DENYLIST="$(printf 'private-name\t%s' "$word")" bash scripts/security-scan.sh pii > "$T/pii3.log" 2>&1)
  ok "PII_DENYLIST: a private word in a FILE NAME is not printed either" "$(grep -c "$word" "$T/pii3.log")" 0
  ok "a broken deny list entry is an error, not a silent green" "$(cd "$D" && PII_DENYLIST="$(printf 'bad\t(unclosed')" bash scripts/security-scan.sh pii > /dev/null 2>&1; echo $?)" 1
  # git metadata is not content
  ok "git metadata (.git/config, logs) is not scanned as content" "$(cd "$D" && git config user.email "me$(printf '@')${ACME_COM}" && rm -f people.md "$word.txt" && bash scripts/security-scan.sh pii > /dev/null 2>&1; echo $?)" 0
else
  skip gitleaks "bash scripts/install-security-tools.sh"
fi

echo "== 5b. working-tree scans cover only what git would commit (ignored folders are out of scope)"
# Simulates ansible/.ansible/collections/... (Galaxy collections, git-ignored): third-party files with a token-like
# value and a test fixture that trivy would flag. Nothing here is a real secret; the token is made up at run time.
bad_manifest() {
  printf '%s\n' 'apiVersion: apps/v1' 'kind: Deployment' 'metadata: {name: nginx-d, namespace: test-1}' 'spec:' \
    '  selector: {matchLabels: {app: n}}' '  template:' '    metadata: {labels: {app: n}}' '    spec:' '      containers:' \
    '      - name: n' '        image: nginx' '        securityContext: {privileged: true}'
}
if have gitleaks && gitleaks dir --help > /dev/null 2>&1; then
  D=$(mini ignored)
  col="$D/ansible/.ansible/collections/ansible_collections/kubernetes/core"
  mkdir -p "$col/plugins/modules" "$col/tests/fixtures"
  tok="ghp_$(python3 -c 'import secrets,string; print("".join(secrets.choice(string.ascii_letters + string.digits) for _ in range(36)))')"
  printf 'token = "%s"\n' "$tok" > "$col/plugins/modules/kubeconfig.py"
  bad_manifest > "$col/tests/fixtures/deploy.yaml"
  printf '.ansible/\n' > "$D/.gitignore"
  (cd "$D" && git add -A && git_neutral commit -q -m "ignore .ansible")
  ok "control: the fake token in the ignored folder is detectable by gitleaks" "$(cd "$D" && gitleaks dir --no-banner --no-color --exit-code 1 . > /dev/null 2>&1; echo $?)" 1
  ok "the fixture folder is really git-ignored" "$(cd "$D" && git check-ignore -q ansible/.ansible/collections/ansible_collections/kubernetes/core/plugins/modules/kubeconfig.py; echo $?)" 0
  ok "a fake secret in an ignored folder is not scanned (secrets green)" "$(rc scan "$D" secrets)" 0
  ok "a fake secret in an ignored folder is not scanned (pii green)" "$(rc scan "$D" pii)" 0
  ok "the scan says how many files it looks at" "$(scan "$D" secrets 2>&1 | grep -c '^working tree: [0-9]* files')" 1
  # An untracked file that is NOT ignored is still scanned.
  printf 'token = "%s"\n' "$tok" > "$D/config.txt"
  ok "a fake secret in an untracked, not ignored file IS found" "$(rc scan "$D" secrets)" 1
  ok "the token is not printed" "$(scan "$D" secrets 2>&1 | grep -c "$tok")" 0
  # The same file tracked (staged and committed).
  commit_all "$D"
  ok "a fake secret in a tracked file IS found" "$(rc scan "$D" secrets)" 1
  # A fresh repo with a clean history: a tracked file deleted on disk does not break the scan, an uncommitted edit of a
  # tracked file counts.
  D=$(mini edited)
  printf 'x\n' > "$D/keep.txt"
  commit_all "$D"
  rm "$D/keep.txt"
  ok "a tracked file deleted on disk (not committed) does not break the scan" "$(rc scan "$D" secrets)" 0
  printf 'token = "%s"\n' "$tok" >> "$D/README.md"
  ok "an uncommitted edit of a tracked file IS found" "$(rc scan "$D" secrets)" 1
else
  skip gitleaks "bash scripts/install-security-tools.sh"
fi
if have trivy && [ -d "${XDG_CACHE_HOME:-$HOME/.cache}/trivy" ]; then
  D=$(mini ignoredtrivy)
  col="$D/ansible/.ansible/collections/ansible_collections/kubernetes/core/tests/fixtures"
  mkdir -p "$col"
  bad_manifest > "$col/deploy.yaml"
  printf '.ansible/\n' > "$D/.gitignore"
  (cd "$D" && git add -A && git_neutral commit -q -m "ignore .ansible")
  ok "a bad manifest in an ignored folder is not scanned (trivy green)" "$(rc scan "$D" trivy)" 0
  mkdir -p "$D/k8s"
  bad_manifest > "$D/k8s/deploy.yaml"
  ok "a bad manifest in an untracked, not ignored file IS found (trivy red)" "$(rc scan "$D" trivy)" 1
else
  skip "trivy (or its cache, run the trivy check once)" "bash scripts/install-security-tools.sh"
fi

echo "== 6. workflow checks (actionlint, zizmor)"
if have actionlint && have zizmor; then
  D=$(mini wf)
  ok "the real security workflow is green" "$(rc scan "$D" actions)" 0
  mkdir -p "$D/.github/workflows"
  cat > "$D/.github/workflows/bad.yml" << 'YML'
name: bad
on: pull_request_target
jobs:
  b:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: echo "${{ github.event.pull_request.title }}"
YML
  scan "$D" actions > "$T/wf.log" 2>&1
  ok "unpinned action, pull_request_target and injection are red" "$?" 1
  rm "$D/.github/workflows/bad.yml"
  printf 'name: broken\non: push\njobs:\n  b:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo ${{ nope.nothing }}\n' > "$D/.github/workflows/broken.yml"
  ok "an expression error (actionlint) is red" "$(rc scan "$D" actions)" 1
else
  skip "actionlint or zizmor" "bash scripts/install-tools.sh; bash scripts/install-security-tools.sh"
fi

echo "== 7. the pieces the checks rely on"
ok "ci/security-tools.env pins five scanners with SHA-256 (Helm is shared)" "$(grep -Ec '^[A-Z]+_SHA256=[0-9a-f]{64}$' "$R/ci/security-tools.env")" 5
ok "ci/control-tools.env pins shared Helm with SHA-256" "$(grep -Ec '^HELM_SHA256=[0-9a-f]{64}$' "$R/ci/control-tools.env")" 1
ok "every Python tool is pinned with hashes" "$(grep -Ec '^(zizmor|yamllint|shellcheck-py|pyyaml|pathspec)==' "$R/ci/requirements-security.txt")" 5
ok "the gitleaks PII config is valid TOML" "$(python3 -c 'import sys,tomllib; tomllib.load(open(sys.argv[1],"rb"))' "$R/scripts/security/gitleaks-pii.toml" > /dev/null 2>&1; echo $?)" 0
ok "the installer refuses an unknown tool" "$(rc bash "$R/scripts/install-security-tools.sh" "$T/inst" nonsense)" 2
ok "the installer takes --help and never an option as the target folder" "$(rc bash "$R/scripts/install-security-tools.sh" --help)$(rc bash "$R/scripts/install-security-tools.sh" --nonsense)" 02
ok "the installer rejects an archive with a wrong checksum" "$(
  mkdir -p "$T/cache"
  . "$R/ci/security-tools.env"
  echo wrong > "$T/cache/$(basename "$GITLEAKS_URL")"
  SECURITY_TOOLS_CACHE="$T/cache" rc bash "$R/scripts/install-security-tools.sh" "$T/inst" gitleaks
)" 1
ok "nothing was installed from the wrong archive" "$(ls "$T/inst" 2> /dev/null | wc -l | tr -d ' ')" 0

echo
if [ "$fail" -ne 0 ]; then
  echo "RED: $fail of $n checks failed" >&2
  exit 1
fi
echo "All $n checks green."
