#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
# Secret initialization, rotation and generation tests for scripts/lab.sh; no live tools or cluster.
# Usage: bash tests/lab-sh-secrets-tests.sh [repo root]
# shellcheck disable=SC2016
set -u
R=$(cd "${1:-$(dirname "${BASH_SOURCE[0]}")/..}" && pwd -P)
fail=0
n=0
# shellcheck source=tests/helpers/lab-sh-sandbox.sh
source "$R/tests/helpers/lab-sh-sandbox.sh"

NAMES=$(sed -n 's/^  - name: //p' "$R/ansible/inventory/group_vars/all/secrets.yml")
echo "== init and secrets (real tools: sops, age, openssl, ssh-keygen)"
MISSING=""
for w in sops age-keygen openssl ssh-keygen python3; do command -v "$w" > /dev/null 2>&1 || MISSING="$MISSING $w"; done
if [ -n "$MISSING" ]; then
  echo "SKIPPED: init tests, missing:$MISSING"
else
  # Only the ansible stub first in PATH (ssh-keygen etc. are real here)
  mkdir -p "$T/bin-init"
  cp "$T/bin/ansible" "$T/bin-init/ansible"
  labi() { # labi HOME REPO ARGS... ; output in $T/out
    local h=$1 r=$2
    shift 2
    HOME=$h PATH=$T/bin-init:$PATH LAB_POLL=0 LAB_REQUIRE_TTY=0 bash "$r/scripts/lab.sh" "$@" > "$T/out" 2>&1
  }
  # Fresh repo with the state of the sandbox, so that the rest stays untouched
  RI=$T/repo-init
  cp -a "$T/repo" "$RI"
  # Public version: .sops.yaml carries a placeholder. For the tests the sandbox gets a foreign,
  # formally valid recipient (58 times q), like an owner would have in their file.
  if grep -q 'age1-PLACEHOLDER' "$RI/.sops.yaml"; then
    sed -i "s#age1-PLACEHOLDER[A-Za-z0-9-]*#age1$(printf 'q%.0s' $(seq 58))#" "$RI/.sops.yaml"
    (cd "$RI" && git add -A && git -c user.name=t -c user.email=t@t commit -q -m foreign)
  fi
  ALTAGE=$(grep -o 'age1[a-z0-9]*' "$RI/.sops.yaml" | head -n 1 | cut -c1-12)
  HI=$T/home-init
  mkdir -m 700 "$HI"
  SOPS_FILES="cert-manager/lab-ca db-lab/backup-s3-creds gitea/backup-s3-creds gitea/gitea-admin gitea/gitea-db-owner gitea/k8up-repo gitea/k8up-s3-creds"

  echo "-- public clone without secrets/ (ADR 0022): init seeds it from secrets.example/"
  RP=$T/repo-pub
  cp -a "$RI" "$RP"
  mkdir -p "$RP"
  (cd "$RP/secrets" && find . -name '*.sops.yaml' -delete)
  mv "$RP/secrets" "$RP/secrets.example"
  HP=$T/home-pub
  mkdir -m 700 "$HP"
  labi "$HP" "$RP" init --dry-run < /dev/null
  has "public clone, dry run names the seeding" "would seed it from secrets.example/" "$T/out"
  ok "public clone, dry run: secrets/ still missing" "$([ -e "$RP/secrets" ] && echo yes || echo no)" no
  labi "$HP" "$RP" init < /dev/null
  has "public clone, init names the seeding" "seeded from secrets.example/" "$T/out"
  ok "public clone, init: every template is in secrets/" "$(find "$RP/secrets" -name '*.sops.yaml.example' | wc -l)" "$(find "$RP/secrets.example" -name '*.sops.yaml.example' | wc -l)"
  rm -rf "$RP" "$HP"

  echo "-- init --dry-run writes nothing"
  labi "$HI" "$RI" init --dry-run < /dev/null; ok "dry-run: exit 0" "$?" 0
  has "dry run reports WOULD CREATE" "WOULD CREATE: age-key" "$T/out"
  # Expected number of SKIP lines with a full set: every file + 7 SOPS files + .sops.yaml
  NEXPECTED=$(($(grep -c '^WOULD' "$T/out") + 1))
  ok "dry run: expected number plausible (at least 20)" "$([ "$NEXPECTED" -ge 20 ] && echo yes || echo no)" yes
  ok "dry run: no file in HOME" "$(find "$HI" -type f | wc -l)" 0
  ok "dry run: .sops.yaml unchanged" "$(cd "$RI" && git status --porcelain .sops.yaml | wc -l)" 0
  has "note: own key is not a recipient" "not a recipient" "$T/out"

  echo "-- init without opt-in: .sops.yaml stays, new SOPS files are refused"
  labi "$HI" "$RI" init < /dev/null; ok "without opt-in: exit 1 (ABORT)" "$?" 1
  has "ABORT names --new-age-key" "--new-age-key" "$T/out"
  ok "without opt-in: .sops.yaml unchanged" "$(cd "$RI" && git status --porcelain .sops.yaml | wc -l)" 0
  ok "without opt-in: no *.sops.yaml created" "$(cd "$RI" && git status --porcelain --untracked-files=all secrets | grep -c 'sops.yaml$')" 0
  ok "without opt-in: key ring was created anyway" "$([ -f "$HI/.config/sops/age/keys.txt" ] && echo yes || echo no)" yes
  has "init: Argo-deploy key created" "CREATED: argocd-deploy-key" "$T/out"
  has "init: note register read-only" "READ-ONLY" "$T/out"
  has "init: public key shown" "ssh-ed25519 " "$T/out"
  hasnot "init: no private key in the output" "PRIVATE KEY" "$T/out"

  echo "-- init --new-age-key creates everything"
  labi "$HI" "$RI" init --new-age-key --yes < /dev/null; ok "init: Exit 0" "$?" 0
  has "init: map at the end" "Secrets map (never shows values)" "$T/out"
  ok "init: file modes only 600 (except the public CA certificate)" "$(find "$HI" -type f ! -name 'lab-ca.crt' -printf '%m\n' | sort -u | tr '\n' ' ')" "600 "
  ok "init: directory modes only 700" "$(find "$HI" -type d -printf '%m\n' | sort -u | tr '\n' ' ')" "700 "
  ok "init: public CA certificate is 644" "$(stat -c %a "$HI/.config/k8s-lab/lab-ca.crt")" 644
  ok "init: 24 SOPS files" "$(cd "$RI" && ls secrets/*/*.sops.yaml | wc -l)" 24
  PUB=$(age-keygen -y "$HI/.config/sops/age/keys.txt")
  has ".sops.yaml has the own recipient" "age: $PUB" "$RI/.sops.yaml"
  hasnot ".sops.yaml no longer has the old recipient" "$ALTAGE" "$RI/.sops.yaml"
  KEYS=$(for f in $SOPS_FILES; do
    SOPS_AGE_KEY_FILE=$HI/.config/sops/age/keys.txt sops decrypt --input-type yaml --output-type json "$RI/secrets/$f.sops.yaml" |
      python3 -c 'import json,sys; o=json.load(sys.stdin); print(sys.argv[1], o["kind"], o["type"], ",".join(sorted(o["data"])))' "$f"
  done)
  has "decrypted: lab CA" "cert-manager/lab-ca Secret kubernetes.io/tls ca.crt,tls.crt,tls.key" <(echo "$KEYS")
  has "decrypted: S3 CNPG" "db-lab/backup-s3-creds Secret Opaque ACCESS_KEY_ID,ACCESS_SECRET_KEY" <(echo "$KEYS")
  has "decrypted: gitea-admin" "gitea/gitea-admin Secret Opaque password,username" <(echo "$KEYS")
  has "decrypted: gitea-db-owner" "gitea/gitea-db-owner Secret kubernetes.io/basic-auth password,username" <(echo "$KEYS")
  has "decrypted: k8up-repo" "gitea/k8up-repo Secret Opaque password" <(echo "$KEYS")
  has "decrypted: k8up-s3-creds" "gitea/k8up-s3-creds Secret Opaque ACCESS_KEY_ID,ACCESS_SECRET_KEY" <(echo "$KEYS")
  has "decrypted: ACME-Token (empty, wave 1)" "cert-manager/acme-dns01-token Secret Opaque token" <(SOPS_AGE_KEY_FILE=$HI/.config/sops/age/keys.txt sops decrypt --input-type yaml --output-type json "$RI/secrets/cert-manager/acme-dns01-token.sops.yaml" | python3 -c 'import json,sys; o=json.load(sys.stdin); print("cert-manager/acme-dns01-token", o["kind"], o["type"], ",".join(sorted(o["data"])))')
  ok "ACME SOPS file: token is empty" "$(SOPS_AGE_KEY_FILE=$HI/.config/sops/age/keys.txt sops decrypt --input-type yaml --output-type json "$RI/secrets/cert-manager/acme-dns01-token.sops.yaml" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["data"]["token"]))')" 0
  has "decrypted: matrix-admin" "matrix/matrix-admin Secret Opaque password,username" <(SOPS_AGE_KEY_FILE=$HI/.config/sops/age/keys.txt sops decrypt --input-type yaml --output-type json "$RI/secrets/matrix/matrix-admin.sops.yaml" | python3 -c 'import json,sys; o=json.load(sys.stdin); print("matrix/matrix-admin", o["kind"], o["type"], ",".join(sorted(o["data"])))')
  has "decrypted: matrix-db-owner" "matrix/matrix-db-owner Secret kubernetes.io/basic-auth password,username" <(SOPS_AGE_KEY_FILE=$HI/.config/sops/age/keys.txt sops decrypt --input-type yaml --output-type json "$RI/secrets/matrix/matrix-db-owner.sops.yaml" | python3 -c 'import json,sys; o=json.load(sys.stdin); print("matrix/matrix-db-owner", o["kind"], o["type"], ",".join(sorted(o["data"])))')
  ok "signing-key SOPS value is empty when the operator file is absent" "$(SOPS_AGE_KEY_FILE=$HI/.config/sops/age/keys.txt sops decrypt --input-type yaml --output-type json "$RI/secrets/matrix/matrix-signing-key.sops.yaml" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["data"]["signing.key"]))')" 0
  CAPEM=$(python3 - "$HI/.config/k8s-lab/lab-ca-secret.yaml" <<'PY'
import base64, re, sys
t = open(sys.argv[1]).read()
m = re.search(r"^\s+ca\.crt:\s*(\S+)", t, re.M)
sys.stdout.write(base64.b64decode(m.group(1)).decode())
PY
)
  has "new CA: nameConstraints critical" "X509v3 Name Constraints: critical" <(echo "$CAPEM" | openssl x509 -noout -text)
  has "new CA: allows DNS:lab.example" "DNS:lab.example" <(echo "$CAPEM" | openssl x509 -noout -text)
  has "new CA: excludes all IPs" "IP:0.0.0.0/0.0.0.0" <(echo "$CAPEM" | openssl x509 -noout -text)
  ok "SOPS files contain no plaintext (no stringData / no plaintext password:)" "$(cd "$RI" && grep -lE '^(stringData|  password: [^E]|  ACCESS_SECRET_KEY: [^E])' secrets/*/*.sops.yaml | wc -l)" 0
  ok "CA is valid (openssl verify, self-signed)" "$(python3 - "$HI/.config/k8s-lab/lab-ca-secret.yaml" <<'PY' | openssl x509 -noout -subject 2> /dev/null | grep -c 'Lab CA'
import base64, re, sys
t = open(sys.argv[1]).read()
m = re.search(r"^\s+ca\.crt:\s*(\S+)", t, re.M)
sys.stdout.write(base64.b64decode(m.group(1)).decode())
PY
)" 1
  # No value in output and log
  cat > "$T/leak.py" <<'PY'
import glob, os, re, sys
home, output, logs = sys.argv[1], sys.argv[2], sys.argv[3]
values = set()
for fpath in glob.glob(home + "/.config/k8s-lab/*") + glob.glob(home + "/.config/rustfs/*") + glob.glob(home + "/.config/sops/age/*"):
    if fpath.endswith((".user", ".yaml", ".crt")):
        continue
    for z in open(fpath, encoding="utf-8", errors="replace"):
        z = z.strip()
        if z.startswith("#") or not z:
            continue
        m = re.match(r"^([A-Z_]+)=(.*)$", z)
        if m:
            if "SECRET" not in m.group(1):
                continue
            z = m.group(2)
        if len(z) >= 12:
            values.add(z)
text = open(output, encoding="utf-8", errors="replace").read()
for l in glob.glob(logs + "/lab-init-*.log") + glob.glob(logs + "/lab-secrets-*.log"):
    text += open(l, encoding="utf-8", errors="replace").read()
print(len(values), sum(1 for w in values if w in text))
PY
  LEAK=$(python3 "$T/leak.py" "$HI" "$T/out" "$H/data/logs")
  ok "leak check found values (the test is meaningful)" "$([ "${LEAK%% *}" -ge 8 ] && echo yes || echo no)" yes
  ok "init: no value in output and log" "${LEAK##* }" 0

  echo "-- second init: everything SKIP, nothing changed"
  (cd "$HI" && find . -type f | sort | xargs sha256sum) > "$T/h1.sum"
  (cd "$RI" && find secrets .sops.yaml -type f | sort | xargs sha256sum) > "$T/s1.sum"
  labi "$HI" "$RI" init < /dev/null; ok "second init: exit 0" "$?" 0
  ok "second init: nothing CREATED/NEW" "$(grep -cE '^(CREATED|RESTORED|ABORT)' "$T/out")" 0
  ok "second init: $NEXPECTED SKIP" "$(grep -c '^SKIP' "$T/out")" "$NEXPECTED"
  (cd "$HI" && find . -type f | sort | xargs sha256sum) | diff -q - "$T/h1.sum" > /dev/null; ok "second init: HOME files byte-identical" "$?" 0
  (cd "$RI" && find secrets .sops.yaml -type f | sort | xargs sha256sum) | diff -q - "$T/s1.sum" > /dev/null; ok "second init: SOPS files and .sops.yaml byte-identical" "$?" 0

  echo "-- secrets: map without values"
  chmod 644 "$HI/.config/k8s-lab/gitea-k3s-lab-db.pw"
  rm -f "$HI/.config/k8s-lab/gitea-k3s-lab-admin.pw"
  labi "$HI" "$RI" secrets < /dev/null; ok "secrets: exit 0" "$?" 0
  # argocd-secrets-deploy-key only exists with a separate secrets repo (ADR 0022).
  for nm in $NAMES; do [ "$nm" = argocd-secrets-deploy-key ] && continue; has "map names $nm" "$nm" "$T/out"; done
  hasnt "same repo: no secrets repo deploy key in the map" "argocd-secrets-deploy-key" "$T/out"
  LAB_TEST_SECRETS_REPO=1 labi "$HI" "$RI" secrets < /dev/null; ok "separate secrets repo: secrets exit 0" "$?" 0
  has "separate secrets repo: map names argocd-secrets-deploy-key" "argocd-secrets-deploy-key" "$T/out"
  ok "map: 6 entries for the password manager (incl. break-glass-key)" "$(grep -c 'password manager$' "$T/out")" 6
  has "map: age key in the password manager" "age-key ★ password manager" "$T/out"
  has "Map: restic password in password manager" "k8up-repo-pw ★ password manager" "$T/out"
  has "map: lab CA in the password manager" "lab-ca ★ password manager" "$T/out"
  has "map: wrong permissions red" "❌ 644" "$T/out"
  has "map: missing file red" "❌ missing" "$T/out"
  has "map: copy command wl-copy" "wl-copy < ~/.config/sops/age/keys.txt" "$T/out"
  has "map: Argo command with kubeconfig" "kubectl --kubeconfig $HI/.kube/k3s-lab.kubeconfig -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d | wl-copy" "$T/out"
  LEAK=$(python3 "$T/leak.py" "$HI" "$T/out" "$H/data/logs")
  ok "secrets: no value in the output" "${LEAK##* }" 0
  ok "secrets creates nothing" "$(find "$HI" -type f | wc -l)" "$(wc -l < "$T/h1.sum" | awk '{ print $1 - 1 }')"
  chmod 600 "$HI/.config/k8s-lab/gitea-k3s-lab-db.pw"

  echo "-- init restores a missing host file from the SOPS file"
  cp -a "$HI/.config/k8s-lab/k8up-k3s-lab-repo.pw" "$T/repo.pw.alt"
  rm -f "$HI/.config/k8s-lab/k8up-k3s-lab-repo.pw" "$HI/.config/k8s-lab/gitea-k3s-lab-admin.pw"
  labi "$HI" "$RI" init < /dev/null; ok "Restore: Exit 0" "$?" 0
  has "restore: RESTORED" "RESTORED: k8up-repo-pw " "$T/out"
  cmp -s "$HI/.config/k8s-lab/k8up-k3s-lab-repo.pw" "$T/repo.pw.alt"; ok "restore: restic password restored identically" "$?" 0
  ok "Restore: Modus 600" "$(stat -c %a "$HI/.config/k8s-lab/k8up-k3s-lab-repo.pw")" 600
  (cd "$RI" && find secrets .sops.yaml -type f | sort | xargs sha256sum) | diff -q - "$T/s1.sum" > /dev/null; ok "restore: SOPS files unchanged" "$?" 0

  echo "-- init does not overwrite an existing file"
  RF=$T/repo-foreign; cp -a "$T/repo" "$RF"
  HF=$T/home-foreign; mkdir -p "$HF/.config/k8s-lab" && chmod 700 "$HF/.config/k8s-lab"
  printf 'my-own-restic-password-1234\n' > "$HF/.config/k8s-lab/k8up-k3s-lab-repo.pw"; chmod 600 "$HF/.config/k8s-lab/k8up-k3s-lab-repo.pw"
  printf 'loose-permissions\n' > "$HF/.config/k8s-lab/gitea-k3s-lab-db.pw"; chmod 640 "$HF/.config/k8s-lab/gitea-k3s-lab-db.pw"
  sum1=$(sha256sum "$HF/.config/k8s-lab/k8up-k3s-lab-repo.pw" "$HF/.config/k8s-lab/gitea-k3s-lab-db.pw")
  labi "$HF" "$RF" init --new-age-key --yes < /dev/null; rc=$?
  sum2=$(sha256sum "$HF/.config/k8s-lab/k8up-k3s-lab-repo.pw" "$HF/.config/k8s-lab/gitea-k3s-lab-db.pw")
  ok "existing files: checksums equal" "$sum2" "$sum1"
  ok "existing file with mode 640 stays 640" "$(stat -c %a "$HF/.config/k8s-lab/gitea-k3s-lab-db.pw")" 640
  has "SKIP for the existing file" "SKIP: k8up-repo-pw" "$T/out"
  has "file with loose permissions is reported (source not 0600)" "gitea-db-owner" "$T/out"
  ok "loose permissions: no silent encryption, exit 1" "$rc" 1
  ok "k8up-repo.sops.yaml contains the existing password" "$(SOPS_AGE_KEY_FILE=$HF/.config/sops/age/keys.txt sops decrypt --input-type yaml --output-type json "$RF/secrets/gitea/k8up-repo.sops.yaml" | python3 -c 'import base64,json,sys; print(base64.b64decode(json.load(sys.stdin)["data"]["password"]).decode().strip())')" "my-own-restic-password-1234"

  echo "-- legacy setup: grown files (roles/sops-secret.sh), init is a pure no-op"
  RM=$T/repo-alt; cp -a "$RI" "$RM"
  HM=$T/home-alt; cp -a "$HI" "$HM"
  (cd "$RM" && rm -f secrets/*/*.sops.yaml)
  # as before: from the host files via sops-secret.sh, the CA like 'export' directly as a secret
  (
    cd "$RM" || exit 1
    export HOME=$HM SOPS_AGE_KEY_FILE=$HM/.config/sops/age/keys.txt
    C=$HM/.config/k8s-lab
    bash ansible/scripts/sops-secret.sh from-env db-lab backup-s3-creds "$C/s3-cnpg-k3s-lab.env"
    bash ansible/scripts/sops-secret.sh from-env gitea backup-s3-creds "$C/s3-cnpg-k3s-lab.env"
    bash ansible/scripts/sops-secret.sh from-env gitea k8up-s3-creds "$C/s3-k8up-k3s-lab.env"
    bash ansible/scripts/sops-secret.sh from-files gitea gitea-admin Opaque "username=@$C/gitea-k3s-lab-admin.user" "password=@$C/gitea-k3s-lab-admin.pw"
    bash ansible/scripts/sops-secret.sh from-files gitea k8up-repo Opaque "password=@$C/k8up-k3s-lab-repo.pw"
    bash ansible/scripts/sops-secret.sh from-files gitea gitea-db-owner kubernetes.io/basic-auth "username=gitea" "password=@$C/gitea-k3s-lab-db.pw"
    sops encrypt --filename-override secrets/cert-manager/lab-ca.sops.yaml --input-type yaml --output-type yaml "$C/lab-ca-secret.yaml" > secrets/cert-manager/lab-ca.sops.yaml
  ) > "$T/alt-legacy.log" 2>&1
  ok "legacy: 7 SOPS files created the old way" "$(cd "$RM" && ls secrets/*/*.sops.yaml 2> /dev/null | wc -l)" 7
  (cd "$HM" && find . -type f | sort | xargs sha256sum) > "$T/hm1.sum"
  (cd "$RM" && find secrets .sops.yaml -type f | sort | xargs sha256sum) > "$T/sm1.sum"
  # New since wave 1: exactly one SOPS file is added (empty ACME token), everything grown stays untouched.
  labi "$HM" "$RM" init --dry-run < /dev/null; ok "Altbestand: init --dry-run Exit 0" "$?" 0
  ok "legacy: --dry-run reports the ACME file, the matrix files, the Keycloak and OIDC files and the runner token files" "$(grep -cE '^(WOULD|CREATED|ABORT)' "$T/out")" 17
  has "legacy: --dry-run names acme-token" "acme-token" "$T/out"
  has "legacy: --dry-run names matrix-admin-pw" "matrix-admin-pw" "$T/out"
  labi "$HM" "$RM" init < /dev/null; ok "Altbestand: init Exit 0" "$?" 0
  ok "legacy: init creates the ACME file, the matrix files, the Keycloak and OIDC files and the runner token files" "$(grep -cE '^(CREATED|RESTORED|ABORT|WOULD)' "$T/out")" 17
  ok "legacy: SKIP lines + 1 CREATED = all $NEXPECTED" "$(($(grep -c '^SKIP' "$T/out") + $(grep -c '^CREATED' "$T/out")))" "$NEXPECTED"
  ok "legacy: ACME SOPS file exists" "$(test -f "$RM/secrets/cert-manager/acme-dns01-token.sops.yaml" && echo yes)" yes
  ok "legacy: ACME token on the host is never created" "$(test -e "$HM/.config/k8s-lab/acme-dns01.token" && echo yes || echo no)" no
  (cd "$HM" && find . -type f | sort | xargs sha256sum) | diff -q - "$T/hm1.sum" > /dev/null; ok "legacy: HOME byte-identical" "$?" 0
  # Exclude only the files this init is allowed to add. Matrix examples stay in both sums.
  (cd "$RM" && find secrets .sops.yaml -type f ! -name 'acme-dns01-token.sops.yaml' ! -path 'secrets/matrix/*.sops.yaml' ! -path 'secrets/keycloak/*.sops.yaml' ! -path 'secrets/gitea/gitea-oidc.sops.yaml' ! -path 'secrets/gitea/gitea-runner-token.sops.yaml' ! -path 'secrets/gitea-runner/*.sops.yaml' | sort | xargs sha256sum) | diff -q - "$T/sm1.sum" > /dev/null; ok "legacy: all grown SOPS files and .sops.yaml unchanged" "$?" 0
  (cd "$RM" && find secrets .sops.yaml -type f | sort | xargs sha256sum) > "$T/sm1.sum"
  labi "$HM" "$RM" init < /dev/null; ok "legacy: second init exit 0" "$?" 0
  ok "legacy: second init only SKIP" "$(grep -c '^SKIP' "$T/out")" "$NEXPECTED"
  (cd "$RM" && find secrets .sops.yaml -type f | sort | xargs sha256sum) | diff -q - "$T/sm1.sum" > /dev/null; ok "legacy: second init changes no file" "$?" 0


  echo "-- init --break-glass: offline recipient (issue 11)"
  RB=$T/repo-bg; cp -a "$RI" "$RB"
  HB=$T/home-bg; cp -a "$HI" "$HB"
  BGF=$HB/.config/k8s-lab/break-glass-age.txt
  OWN=$(age-keygen -y "$HB/.config/sops/age/keys.txt")
  (cd "$RB" && find secrets .sops.yaml -type f | sort | xargs sha256sum) > "$T/bg0.sum"
  (cd "$HB" && find . -type f | sort | xargs sha256sum) > "$T/bgh0.sum"
  labi "$HB" "$RB" init --break-glass --dry-run < /dev/null; ok "break-glass dry run: exit 0" "$?" 0
  has "break-glass dry run: WOULD CREATE" "WOULD CREATE: break-glass key pair" "$T/out"
  has "break-glass dry run: WOULD CHANGE .sops.yaml" "WOULD CHANGE: .sops.yaml: add the break-glass public key" "$T/out"
  ok "break-glass dry run: no key file" "$(test -e "$BGF" && echo yes || echo no)" no
  (cd "$RB" && find secrets .sops.yaml -type f | sort | xargs sha256sum) | diff -q - "$T/bg0.sum" > /dev/null; ok "break-glass dry run: repo files unchanged" "$?" 0
  (cd "$HB" && find . -type f | sort | xargs sha256sum) | diff -q - "$T/bgh0.sum" > /dev/null; ok "break-glass dry run: home files unchanged" "$?" 0

  labi "$HB" "$RB" init --break-glass < /dev/null; ok "break-glass: no question, exit 0" "$?" 0
  cp "$T/out" "$T/bg-first.out"
  has "break-glass: the plan line is printed" "Plan: add recipient" "$T/out"
  ok "break-glass: key file exists" "$(test -f "$BGF" && echo yes || echo no)" yes
  BGPUB=$(age-keygen -y "$BGF")
  ok "break-glass: key file mode 600" "$(stat -c %a "$BGF")" 600
  ok "break-glass: directory mode 700" "$(stat -c %a "$(dirname "$BGF")")" 700
  has ".sops.yaml: online key first, break-glass key last" "age: $OWN,$BGPUB" "$RB/.sops.yaml"
  ok "break-glass: all SOPS files share one recipient set" "$(cd "$RB" && for f in secrets/*/*.sops.yaml; do grep -o 'recipient: age1[0-9a-z]*' "$f" | sort | tr '\n' ' '; echo; done | sort -u | wc -l)" 1
  ok "break-glass: every file has 2 recipients" "$(cd "$RB" && grep -c 'recipient: age1' secrets/*/*.sops.yaml | awk -F: '$2 != 2' | wc -l)" 0
  ok "break-glass: no .sops.yaml.fresh left" "$(test -e "$RB/.sops.yaml.fresh" && echo yes || echo no)" no
  ok "break-glass: the break-glass key decrypts a file" "$(SOPS_AGE_KEY_FILE=$BGF sops decrypt --input-type yaml --output-type json "$RB/secrets/gitea/gitea-admin.sops.yaml" | python3 -c 'import json,sys; print(sorted(json.load(sys.stdin)["data"]))')" "['password', 'username']"
  ok "break-glass: the online key still decrypts a file" "$(SOPS_AGE_KEY_FILE=$HB/.config/sops/age/keys.txt sops decrypt --input-type yaml --output-type json "$RB/secrets/gitea/gitea-admin.sops.yaml" | python3 -c 'import json,sys; print(sorted(json.load(sys.stdin)["data"]))')" "['password', 'username']"
  ok "break-glass: file has exactly one private key line" "$(grep -c '^AGE-SECRET-KEY-1' "$BGF")" 1
  ok "break-glass: file has nothing but comments, blank lines and the key" "$(grep -vcE '^(#.*|AGE-SECRET-KEY-1.*|)$' "$BGF")" 0
  has "break-glass: file carries the password-manager instruction" "password manager" "$BGF"
  ok "break-glass: online key file does not hold the break-glass key" "$(age-keygen -y "$HB/.config/sops/age/keys.txt" | grep -c "$BGPUB")" 0
  ok "break-glass: no SOPS plaintext (no stringData)" "$(cd "$RB" && grep -lE '^stringData' secrets/*/*.sops.yaml | wc -l)" 0
  # Leak check: the private line is in no output and no log
  BGSECRET=$(grep '^AGE-SECRET-KEY-' "$BGF")
  ok "break-glass: leak test finds a private line (test works)" "$([ -n "$BGSECRET" ] && echo yes || echo no)" yes
  hasnot "break-glass: private key not in the output" "AGE-SECRET-KEY" "$T/out"
  ok "break-glass: private key not in the output or any log" "$(cat "$T/out" "$T/bg-first.out" "$H"/data/logs/lab-init-*.log 2> /dev/null | grep -cF "$BGSECRET")" 0
  has "break-glass: next steps name the delete command" "init --break-glass-delete" "$T/out"
  has "break-glass: card lists the key" "break-glass-key" "$T/out"

  echo "-- init --break-glass resumes with an existing key file (e.g. after an interrupted run)"
  RB2=$T/repo-bg2; cp -a "$RI" "$RB2"
  HB2=$T/home-bg2; cp -a "$HI" "$HB2"
  cp "$BGF" "$HB2/.config/k8s-lab/break-glass-age.txt"
  labi "$HB2" "$RB2" init --break-glass < /dev/null; ok "break-glass resume: exit 0" "$?" 0
  has "break-glass resume: reuses the key file" "NOTE: reusing existing key file" "$T/out"
  has "break-glass resume: .sops.yaml has the same recipients" "age: $OWN,$BGPUB" "$RB2/.sops.yaml"

  echo "-- second init --break-glass: nothing changes"
  (cd "$RB" && find secrets .sops.yaml -type f | sort | xargs sha256sum) > "$T/bg1.sum"
  (cd "$HB" && find . -type f | sort | xargs sha256sum) > "$T/bgh1.sum"
  labi "$HB" "$RB" init --break-glass --yes < /dev/null; ok "second break-glass: exit 0" "$?" 0
  ok "second break-glass: nothing CREATED" "$(grep -cE '^(CREATED|ABORT|WOULD)' "$T/out")" 0
  has "second break-glass: SKIP for the recipients" "SKIP: .sops.yaml already has 2 recipients" "$T/out"
  has "second break-glass: NOTE that the key file is still there" "NOTE: key file" "$T/out"
  (cd "$RB" && find secrets .sops.yaml -type f | sort | xargs sha256sum) | diff -q - "$T/bg1.sum" > /dev/null; ok "second break-glass: repo files byte-identical" "$?" 0
  (cd "$HB" && find . -type f | sort | xargs sha256sum) | diff -q - "$T/bgh1.sum" > /dev/null; ok "second break-glass: home files byte-identical" "$?" 0
  labi "$HB" "$RB" init < /dev/null; ok "plain init after break-glass: exit 0" "$?" 0
  ok "plain init after break-glass: nothing ABORTed or CREATED" "$(grep -cE '^(CREATED|ABORT)' "$T/out")" 0
  (cd "$RB" && find secrets .sops.yaml -type f | sort | xargs sha256sum) | diff -q - "$T/bg1.sum" > /dev/null; ok "plain init after break-glass: repo files byte-identical" "$?" 0

  echo "-- init --break-glass-delete"
  pty_run() { # pty_run TYPED_TEXT HOME REPO : runs the delete command on a pseudo terminal, output in $T/out
    python3 - "$1" "$2" "$3" "$T" > "$T/out" 2>&1 <<'PY'
import os, pty, sys
typed, home, repo, tdir = sys.argv[1:5]
env = dict(os.environ, HOME=home, PATH=tdir + "/bin-init:" + os.environ["PATH"], LAB_POLL="0", LAB_REQUIRE_TTY="0")
pid, fd = pty.fork()
if pid == 0:
    os.execvpe("bash", ["bash", repo + "/scripts/lab.sh", "init", "--break-glass-delete"], env)
out = b""
sent = False
while True:
    try:
        d = os.read(fd, 4096)
    except OSError:
        break
    if not d:
        break
    out += d
    if not sent and b"to confirm" in out:
        os.write(fd, typed.encode() + b"\n")
        sent = True
os.waitpid(pid, 0)
sys.stdout.write(out.decode(errors="replace"))
PY
  }
  labi "$HB" "$RB" init --break-glass-delete --dry-run < /dev/null; ok "delete dry run: exit 0" "$?" 0
  has "delete dry run: WOULD DELETE" "WOULD DELETE" "$T/out"
  ok "delete dry run: file stays" "$(test -f "$BGF" && echo yes || echo no)" yes
  labi "$HB" "$RB" init --break-glass-delete --yes < /dev/null; ok "delete without terminal (even with --yes): exit 1" "$?" 1
  has "delete without terminal: needs an interactive confirmation" "needs an interactive confirmation" "$T/out"
  ok "delete without terminal: file stays" "$(test -f "$BGF" && echo yes || echo no)" yes
  pty_run "no" "$HB" "$RB"
  has "delete with a wrong answer: not confirmed" "not confirmed" "$T/out"
  ok "delete with a wrong answer: file stays" "$(test -f "$BGF" && echo yes || echo no)" yes
  pty_run "delete" "$HB" "$RB"
  has "delete confirmed: DELETED" "DELETED: " "$T/out"
  ok "delete confirmed: file is gone" "$(test -e "$BGF" && echo yes || echo no)" no
  hasnot "delete: private key not in the output" "AGE-SECRET-KEY" "$T/out"
  ok "delete: .sops.yaml still has both recipients" "$(grep -c "age: $OWN,$BGPUB" "$RB/.sops.yaml")" 1
  labi "$HB" "$RB" init --break-glass-delete < /dev/null; ok "delete again: exit 0 (nothing to delete)" "$?" 0
  has "delete again: SKIP" "SKIP: no break-glass key file" "$T/out"
  labi "$HB" "$RB" init --break-glass --yes < /dev/null; ok "break-glass after delete: exit 0" "$?" 0
  ok "break-glass after delete: no new key file" "$(test -e "$BGF" && echo yes || echo no)" no
  has "break-glass after delete: SKIP" "SKIP: .sops.yaml already has 2 recipients" "$T/out"
  labi "$HB" "$RB" secrets < /dev/null; ok "card after delete: exit 0" "$?" 0
  has "card after delete: break-glass-key starred for the password manager" "break-glass-key ★ password manager" "$T/out"
  has "card after delete: absence is by design" "absent by design" "$T/out"

  echo "-- break-glass-delete refuses a key that is not a recipient"
  RX=$T/repo-bgx; cp -a "$RI" "$RX"
  HX=$T/home-bgx; cp -a "$HI" "$HX"
  age-keygen -o "$HX/.config/k8s-lab/break-glass-age.txt" 2> /dev/null
  pty_run "delete" "$HX" "$RX"
  has "refuses: not a break-glass recipient" "not a break-glass recipient" "$T/out"
  ok "refuses: file stays" "$(test -f "$HX/.config/k8s-lab/break-glass-age.txt" && echo yes || echo no)" yes
  labi "$HX" "$RX" init --break-glass --yes < /dev/null; rc=$?
  ok "reuse of a foreign key file as break-glass key: works (it is not the online key)" "$rc" 0
  RY=$T/repo-bgy; cp -a "$RI" "$RY"
  HY=$T/home-bgy; cp -a "$HI" "$HY"
  cp "$HY/.config/sops/age/keys.txt" "$HY/.config/k8s-lab/break-glass-age.txt"
  labi "$HY" "$RY" init --break-glass --yes < /dev/null; ok "online key as break-glass file: exit 1" "$?" 1
  has "online key as break-glass file: refused" "Refusing to use it as break-glass key" "$T/out"
  ok "online key as break-glass file: .sops.yaml unchanged" "$(cd "$RY" && sha256sum .sops.yaml)" "$(grep ' .sops.yaml$' "$T/bg0.sum")"

  echo "-- lab.sh option checks for the break-glass flags"
  labi "$HB" "$RB" status --break-glass < /dev/null; ok "status --break-glass: exit 1" "$?" 1
  has "message: flags only for init" "only apply to init" "$T/out"
  labi "$HB" "$RB" init --break-glass --break-glass-delete < /dev/null; ok "both flags: exit 1" "$?" 1
  has "message: flags exclude each other" "exclude each other" "$T/out"

  echo "-- lab.sh ca-rotation (the new CA already has nameConstraints -> SKIP, nothing touched)"
  (cd "$RI" && find secrets .sops.yaml -type f | sort | xargs sha256sum; cd "$HI" && find . -type f | sort | xargs sha256sum) > "$T/cr1.sum"
  labi "$HI" "$RI" ca-rotation --dry-run < /dev/null; ok "ca-rotation --dry-run: Exit 0" "$?" 0
  has "ca-rotation: SKIP because nameConstraints are there" "SKIP" "$T/out"
  has "ca-rotation: reason given" "nameConstraints" "$T/out"
  labi "$HI" "$RI" ca-rotation --yes < /dev/null; ok "ca-rotation --yes: Exit 0" "$?" 0
  ok "ca-rotation creates no backup" "$(find "$HI/.config/k8s-lab" -maxdepth 1 -name 'ca-old-*' | wc -l)" 0
  (cd "$RI" && find secrets .sops.yaml -type f | sort | xargs sha256sum; cd "$HI" && find . -type f | sort | xargs sha256sum) | diff -q - "$T/cr1.sum" > /dev/null; ok "ca-rotation (SKIP) changes no file" "$?" 0

  echo "-- legacy setup: a differing value is never overwritten (ABORT)"
  printf 'a-completely-different-admin-password\n' > "$HM/.config/k8s-lab/gitea-k3s-lab-admin.pw"
  labi "$HM" "$RM" init < /dev/null; ok "differing value: exit 1" "$?" 1
  has "ABORT reported" "ABORT" "$T/out"
  (cd "$RM" && find secrets .sops.yaml -type f | sort | xargs sha256sum) | diff -q - "$T/sm1.sum" > /dev/null; ok "differing value: SOPS files unchanged" "$?" 0
fi

echo "== generate: the one generator for the Ansible roles (only missing files, never replace)"
EH=$T/home-erz
mkdir -p "$EH"
cat > "$T/gen.json" <<JSON
{"entries": [
 {"name": "t-pw", "kind": "pw", "path": "$EH/a/t.pw", "length": 24},
 {"name": "t-rustfs", "kind": "rustfs", "path": "$EH/b/rustfs.env"},
 {"name": "t-s3", "kind": "s3env", "path": "$EH/b/s3.env", "s3_bucket": "bkt", "s3_endpoint": "http://192.168.122.1:9000", "s3_user": "usr"},
 {"name": "t-ssh", "kind": "ssh", "path": "$EH/c/key", "comment": "t-deploy (test)"},
 {"name": "t-age", "kind": "age", "path": "$EH/d/age.txt"}
]}
JSON
EZ() { python3 "$T/repo/scripts/lab-secrets.py" generate --json - "$@" < "$T/gen.json" > "$T/out" 2>&1; }
EZ --name t-pw --name t-rustfs --name t-s3 --name t-ssh; ok "generate: exit 0" "$?" 0
ok "generate: 4 NEW lines" "$(grep -c '^NEW' "$T/out")" 4
ok "generate: password file mode 600" "$(stat -c %a "$EH/a/t.pw")" 600
ok "generate: password has 24 characters" "$(tr -d '\n' < "$EH/a/t.pw" | wc -c)" 24
ok "generate: rustfs.env mode 600" "$(stat -c %a "$EH/b/rustfs.env")" 600
has "generate: rustfs.env has the access key" "RUSTFS_ACCESS_KEY=root-" "$EH/b/rustfs.env"
has "generate: s3.env has the bucket header" "# S3 access, bucket bkt only" "$EH/b/s3.env"
has "generate: key comment" "t-deploy (test)" "$EH/c/key.pub"
hasnot "generate: output shows no value" "RUSTFS_SECRET_KEY" "$T/out"
(cd "$EH" && find . -type f | sort | xargs sha256sum) > "$T/gen1.sum"
EZ --name t-pw --name t-rustfs --name t-s3 --name t-ssh; ok "generate second time: exit 0" "$?" 0
ok "generate second time: 4 SKIP, no NEW" "$(grep -c '^SKIP' "$T/out")/$(grep -c '^NEW' "$T/out")" 4/0
(cd "$EH" && find . -type f | sort | xargs sha256sum) | diff -q - "$T/gen1.sum" > /dev/null; ok "generate second time: files byte-identical" "$?" 0
EZ --name t-age; ok "generate: age belongs to init: exit 1" "$?" 1
has "generate: message about age" "is not created by generate" "$T/out"
EZ --name does-not-exist; ok "generate: unknown name: exit 1" "$?" 1
python3 "$T/repo/scripts/lab-secrets.py" generate --json - < "$T/gen.json" > "$T/out" 2>&1; ok "generate without --name: exit 1" "$?" 1


echo
echo "$n checks, $fail failures"
[ "$fail" = 0 ]
