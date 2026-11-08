#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
# Tests for the lab CA with nameConstraints (issue #7): openssl proofs, Go client, rotation with real sops/age,
# CEL rules of the ValidatingAdmissionPolicy (celpy, optional). None of it touches the user's HOME or a cluster.
# Usage: bash tests/ca-nameconstraints-tests.sh [repo root]
set -u
R=$(cd "${1:-$(dirname "${BASH_SOURCE[0]}")/..}" && pwd -P)
mkdir -p "$HOME/.cache/lab-sh-tests"
T=$(mktemp -d -p "$HOME/.cache/lab-sh-tests")
trap 'rm -rf "$T"' EXIT
PY="$R/scripts/lab-secrets.py"
fail=0
n=0
ok() { n=$((n + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else echo "FAIL $1 (actual '$2', expected '$3')"; fail=$((fail + 1)); fi; }
has() { n=$((n + 1)); if grep -qF -- "$2" "$3"; then echo "OK   $1"; else echo "FAIL $1 (missing: $2)"; fail=$((fail + 1)); fi; }
rc() { "$@" > /dev/null 2>&1; echo $?; }
DOM=lab.example

echo "== openssl: the CA that lab.sh init builds"
# Use the function build_ca from lab-secrets.py itself (no second code path in the test)
python3 - "$R/scripts" "$T" "$DOM" <<'PY'
import importlib.util, sys, os
spec = importlib.util.spec_from_file_location("g", os.path.join(sys.argv[1], "lab-secrets.py"))
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)
e = {"ca_cn": sys.argv[3] + " Lab CA", "ca_domain": sys.argv[3]}
k, z = g.build_ca(e)
open(os.path.join(sys.argv[2], "ca.key"), "wb").write(k)
open(os.path.join(sys.argv[2], "ca.crt"), "wb").write(z)
PY
ok "CA built" "$(test -s "$T/ca.crt" && echo yes)" yes
openssl x509 -in "$T/ca.crt" -noout -text > "$T/ca.txt"
has "CA: nameConstraints critical" "X509v3 Name Constraints: critical" "$T/ca.txt"
has "CA: allows DNS:$DOM" "DNS:$DOM" "$T/ca.txt"
has "CA: excludes IPv4" "IP:0.0.0.0/0.0.0.0" "$T/ca.txt"
has "CA: basicConstraints CA:TRUE critical" "CA:TRUE" "$T/ca.txt"

leaf() { # leaf NAME SAN... : sign a leaf certificate with the CA
  local name=$1
  shift
  openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout "$T/$name.key" -subj "/CN=$name" -out "$T/$name.csr" 2> /dev/null
  printf 'subjectAltName=%s\nextendedKeyUsage=serverAuth\n' "$(IFS=,; echo "$*")" > "$T/$name.ext"
  openssl x509 -req -in "$T/$name.csr" -CA "$T/ca.crt" -CAkey "$T/ca.key" -CAcreateserial -days 30 -extfile "$T/$name.ext" -out "$T/$name.crt" 2> /dev/null
}
verify_leaf() { openssl verify -CAfile "$T/ca.crt" -purpose sslserver "$T/$1.crt" > "$T/v-$1.log" 2>&1; echo $?; }

leaf inside DNS:argocd.$DOM
ok "Leaf argocd.$DOM: openssl verify OK" "$(verify_leaf inside)" 0
leaf sub DNS:a.b.argocd.$DOM
ok "Leaf a.b.argocd.$DOM: OK (subdomain)" "$(verify_leaf sub)" 0
leaf outside DNS:evil.example.com
ok "Leaf evil.example.com: rejected" "$(verify_leaf outside)" 2
has "  Reason: permitted subtree violation" "permitted subtree violation" "$T/v-outside.log"
leaf almost DNS:argocd.${DOM}.evil.com
ok "Leaf argocd.${DOM}.evil.com: rejected (a name prefix is not enough)" "$(verify_leaf almost)" 2
leaf mixed DNS:argocd.$DOM DNS:evil.example.com
ok "Leaf with one name outside: rejected" "$(verify_leaf mixed)" 2
leaf ip DNS:argocd.$DOM IP:192.168.122.50
ok "Leaf with IP SAN: rejected" "$(verify_leaf ip)" 2
has "  Reason: excluded subtree violation" "excluded subtree violation" "$T/v-ip.log"
leaf ip6 DNS:argocd.$DOM IP:fd00::1
ok "Leaf with IPv6 SAN: rejected" "$(verify_leaf ip6)" 2
leaf wild DNS:*.$DOM
ok "Leaf *.$DOM: OK" "$(verify_leaf wild)" 0

echo "== Go: clients enforce the restriction, the issuer (CreateCertificate) does not"
if command -v go > /dev/null 2>&1; then
  mkdir -p "$T/go"
  cat > "$T/go/main.go" <<'GO'
package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"fmt"
	"math/big"
	"os"
	"time"
)

func main() {
	caPEM, _ := os.ReadFile(os.Args[1])
	keyPEM, _ := os.ReadFile(os.Args[2])
	cb, _ := pem.Decode(caPEM)
	ca, err := x509.ParseCertificate(cb.Bytes)
	if err != nil {
		panic(err)
	}
	kb, _ := pem.Decode(keyPEM)
	ki, err := x509.ParsePKCS8PrivateKey(kb.Bytes)
	if err != nil {
		panic(err)
	}
	pool := x509.NewCertPool()
	pool.AddCert(ca)
	fmt.Println("go-ca-critical", len(ca.PermittedDNSDomains) == 1, ca.PermittedDNSDomainsCritical)
	for _, name := range []string{"argocd." + os.Args[3], "evil.example.com"} {
		k, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		t := &x509.Certificate{SerialNumber: big.NewInt(time.Now().UnixNano()), Subject: pkix.Name{CommonName: name},
			DNSNames: []string{name}, NotBefore: time.Now().Add(-time.Minute), NotAfter: time.Now().Add(time.Hour),
			KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}
		der, err := x509.CreateCertificate(rand.Reader, t, ca, &k.PublicKey, ki)
		fmt.Println("go-signed", name, err == nil)
		if err != nil {
			continue
		}
		leaf, _ := x509.ParseCertificate(der)
		_, verr := leaf.Verify(x509.VerifyOptions{Roots: pool, DNSName: name, KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}})
		fmt.Println("go-client-accepted", name, verr == nil)
	}
}
GO
  # PKCS8 for Go
  openssl pkcs8 -topk8 -nocrypt -in "$T/ca.key" -out "$T/ca.p8" 2> /dev/null
  (cd "$T/go" && cat > go.mod <<'MOD'
module nctest

go 1.21
MOD
  GOFLAGS=-mod=mod GOCACHE="$HOME/.cache/go-build" go run . "$T/ca.crt" "$T/ca.p8" "$DOM" > "$T/go.out" 2>&1)
  has "Go reads the critical nameConstraints" "go-ca-critical true true" "$T/go.out"
  has "Go issuer signs inside the zone" "go-signed argocd.$DOM true" "$T/go.out"
  has "Go client accepts inside the zone" "go-client-accepted argocd.$DOM true" "$T/go.out"
  has "Go issuer signs OUTSIDE (checks nothing, hence the VAP)" "go-signed evil.example.com true" "$T/go.out"
  has "Go client rejects outside" "go-client-accepted evil.example.com false" "$T/go.out"
else
  echo "SKIP go not installed"
fi

echo "== Rotation: lab.sh ca-rotation (lab-secrets.py) with real sops and age"
if ! command -v age-keygen >/dev/null 2>&1 || ! command -v sops >/dev/null 2>&1; then
  echo "SKIP ca-rotation: age-keygen or sops is not installed"
else
# Repo: only the CA template, own .sops.yaml, own age key, old CA WITHOUT nameConstraints
RP=$T/repo
mkdir -p "$RP"
(cd "$R" && git ls-files -co --exclude-standard -z -- ansible/scripts secrets/cert-manager/lab-ca.sops.yaml.example | tar --null -T - -cf - 2> /dev/null) | tar -xf - -C "$RP"
# A public clone has secrets/ only as an untracked, git-ignored copy of secrets.example/ (ADR 0022).
mkdir -p "$RP/secrets/cert-manager"
cp "$R/secrets/cert-manager/lab-ca.sops.yaml.example" "$RP/secrets/cert-manager/"
H=$T/home
mkdir -p "$H/.config/k8s-lab" "$H/.config/sops/age"
chmod 700 "$H/.config/k8s-lab" "$H/.config/sops/age"
age-keygen -o "$H/.config/sops/age/keys.txt" 2> /dev/null
chmod 600 "$H/.config/sops/age/keys.txt"
PUB=$(age-keygen -y "$H/.config/sops/age/keys.txt")
cat > "$RP/.sops.yaml" <<EOF
creation_rules:
  - path_regex: ^secrets/.*\.sops\.yaml$
    encrypted_regex: ^(data|stringData)$
    age: $PUB
EOF
(cd "$RP" && git init -q -b main && git add -A && git -c user.name=t -c user.email=t@t commit -q -m t)
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$T/old.key" 2> /dev/null
openssl req -x509 -new -key "$T/old.key" -sha256 -days 3650 -subj "/CN=$DOM Lab CA" -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" -out "$T/old.crt" 2> /dev/null
b64() { base64 -w0 "$1"; }
CAF=$H/.config/k8s-lab/lab-ca-secret.yaml
PUBCRT=$H/.config/k8s-lab/lab-ca.crt
printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: lab-ca\n  namespace: cert-manager\ntype: kubernetes.io/tls\ndata:\n  ca.crt: %s\n  tls.crt: %s\n  tls.key: %s\n' \
  "$(b64 "$T/old.crt")" "$(b64 "$T/old.crt")" "$(b64 "$T/old.key")" > "$CAF"
chmod 600 "$CAF"
cp "$T/old.crt" "$PUBCRT"
chmod 644 "$PUBCRT"
SOPSF=$RP/secrets/cert-manager/lab-ca.sops.yaml
# old SOPS file as on an older installation: from the host secret
(cd "$RP" && SOPS_AGE_KEY_FILE=$H/.config/sops/age/keys.txt sops encrypt --filename-override secrets/cert-manager/lab-ca.sops.yaml \
  --input-type yaml --output-type yaml "$CAF" > "$SOPSF")
ok "old SOPS file created" "$(test -s "$SOPSF" && echo yes)" yes
cat > "$T/geh.json" <<EOF
{"entries": [
 {"name": "age-key", "kind": "age", "path": "$H/.config/sops/age/keys.txt"},
 {"name": "lab-ca", "kind": "ca", "path": "$CAF", "ca_name": "lab-ca", "ca_namespace": "cert-manager",
  "ca_cn": "$DOM Lab CA", "ca_domain": "$DOM", "public_path": "$PUBCRT"}
]}
EOF
rot() { HOME=$H bash -c 'python3 "$0" ca-rotation --json "$1" --repo "$2" "${@:3}" < /dev/null' "$PY" "$T/geh.json" "$RP" "$@" > "$T/rot.out" 2>&1; }
hashes() { (cd "$H" && find .config -type f | sort | xargs sha256sum) | sha256sum | cut -d' ' -f1; (cd "$RP" && find secrets -type f | sort | xargs sha256sum) | sha256sum | cut -d' ' -f1; }

H0=$(hashes)
rot --dry-run; ok "--dry-run exit 0" "$?" 0
has "--dry-run reports WOULD" "WOULD" "$T/rot.out"
ok "--dry-run changes nothing" "$(hashes)" "$H0"
rot; ok "without --yes and without tty: no confirmation, exit 1 (ABORT)" "$?" 1
has "without confirmation: ABORT message" "no confirmation" "$T/rot.out"
ok "without confirmation changes nothing" "$(hashes)" "$H0"
OLDSOPS=$(sha256sum < "$SOPSF")
rot --yes; ok "--yes: Exit 0" "$?" 0
has "BACKED UP reported" "BACKED UP" "$T/rot.out"
has "REPLACED reported" "REPLACED" "$T/rot.out"
has "SOPS file CREATED" "CREATED" "$T/rot.out"
ok "output shows no key" "$(grep -c 'PRIVATE KEY\|LS0tLS1CRUdJTiBF' "$T/rot.out")" 0
BAK=$(find "$H/.config/k8s-lab" -maxdepth 1 -type d -name 'ca-old-*' | head -1)
ok "backup folder there, mode 700" "$(stat -c %a "$BAK" 2> /dev/null)" 700
ok "backup contains the old CA (secret, crt, SOPS)" "$(find "$BAK" -mindepth 1 -maxdepth 1 2> /dev/null | wc -l)" 3
ok "backed-up old SOPS file is the old one" "$(sha256sum < "$BAK/lab-ca.sops.yaml")" "$OLDSOPS"
ok "host CA file mode 600" "$(stat -c %a "$CAF")" 600
ok "public certificate mode 644" "$(stat -c %a "$PUBCRT")" 644
openssl x509 -in "$PUBCRT" -noout -text > "$T/new.txt"
has "new public certificate has critical nameConstraints" "X509v3 Name Constraints: critical" "$T/new.txt"
ok "fingerprint differs from the old CA" "$([ "$(openssl x509 -in "$PUBCRT" -noout -fingerprint)" != "$(openssl x509 -in "$T/old.crt" -noout -fingerprint)" ] && echo yes)" yes
# decrypt SOPS file: ca.crt == public certificate, key matches it
PLAIN=$(SOPS_AGE_KEY_FILE=$H/.config/sops/age/keys.txt sops decrypt --input-type yaml --output-type json "$SOPSF")
echo "$PLAIN" | python3 -c 'import base64,json,sys; d=json.load(sys.stdin)["data"]; open(sys.argv[1],"wb").write(base64.b64decode(d["tls.crt"])); open(sys.argv[2],"wb").write(base64.b64decode(d["tls.key"]))' "$T/s.crt" "$T/s.key"
ok "SOPS certificate == public certificate" "$(cmp -s "$T/s.crt" "$PUBCRT" && echo yes)" yes
ok "SOPS key matches the certificate" "$(diff <(openssl x509 -in "$T/s.crt" -noout -pubkey) <(openssl pkey -in "$T/s.key" -pubout) > /dev/null && echo yes)" yes
ok "SOPS file differs from before" "$([ "$(sha256sum < "$SOPSF")" != "$OLDSOPS" ] && echo yes)" yes
ok "SOPS file contains no plaintext key" "$(grep -c "BEGIN EC\|BEGIN PRIVATE\|LS0tLS1CRUdJTiBF" "$SOPSF")" 0
# the new CA signs inside the zone and rejects outside
cp "$T/s.crt" "$T/ca.crt"
cp "$T/s.key" "$T/ca.key"
leaf n_in DNS:git.$DOM
ok "new CA: leaf git.$DOM OK" "$(verify_leaf n_in)" 0
leaf n_out DNS:git.example.org
ok "new CA: leaf git.example.org rejected" "$(verify_leaf n_out)" 2

H1=$(hashes)
rot --yes; ok "second rotation: exit 0" "$?" 0
has "second rotation: SKIP (already has nameConstraints)" "SKIP" "$T/rot.out"
ok "second rotation changes nothing" "$(hashes)" "$H1"
rot --dry-run; has "second dry run: SKIP" "SKIP" "$T/rot.out"

echo "-- Rotation aborts cleanly if sops cannot encrypt (everything back)"
H2=$T/home2
cp -a "$H" "$H2"
rm -rf "$H2/.config/k8s-lab"/ca-old-*
cp "$T/old.crt" "$H2/.config/k8s-lab/lab-ca.crt"
printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: lab-ca\n  namespace: cert-manager\ntype: kubernetes.io/tls\ndata:\n  ca.crt: %s\n  tls.crt: %s\n  tls.key: %s\n' \
  "$(b64 "$T/old.crt")" "$(b64 "$T/old.crt")" "$(b64 "$T/old.key")" > "$H2/.config/k8s-lab/lab-ca-secret.yaml"
sed "s#$H/#$H2/#g" "$T/geh.json" > "$T/geh2.json"
RP2=$T/repo2
cp -a "$RP" "$RP2"
cp "$BAK/lab-ca.sops.yaml" "$RP2/secrets/cert-manager/lab-ca.sops.yaml"
sed -i 's#^    age: .*#    age: age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq#' "$RP2/.sops.yaml"
A0=$(sha256sum < "$H2/.config/k8s-lab/lab-ca-secret.yaml")
S0=$(sha256sum < "$RP2/secrets/cert-manager/lab-ca.sops.yaml")
HOME=$H2 python3 "$PY" ca-rotation --json "$T/geh2.json" --repo "$RP2" --yes > "$T/rot2.out" 2>&1 < /dev/null
ok "broken recipient: exit 1" "$?" 1
has "message: everything put back" "put back" "$T/rot2.out"
ok "host CA unchanged after abort" "$(sha256sum < "$H2/.config/k8s-lab/lab-ca-secret.yaml")" "$A0"
ok "SOPS file unchanged after abort" "$(sha256sum < "$RP2/secrets/cert-manager/lab-ca.sops.yaml")" "$S0"
ok "public certificate unchanged after abort" "$(cmp -s "$T/old.crt" "$H2/.config/k8s-lab/lab-ca.crt" && echo yes)" yes
fi

echo "== CEL of the ValidatingAdmissionPolicy (celpy)"
CELPY=$HOME/.cache/celvenv/bin/python
if [ -x "$CELPY" ] && [ -f "$R/tests/ca-vap-cel-tests.py" ]; then
  "$CELPY" "$R/tests/ca-vap-cel-tests.py" "$R/gitops/platform/cert-manager/manifests/policy-lab-ca-names.yaml" > "$T/cel.out" 2>&1
  ok "CEL rules of the VAP" "$?" 0
  tail -3 "$T/cel.out"
else
  echo "SKIP celpy venv ($CELPY) missing, CEL rules not checked"
fi

echo
echo "$n checks, $fail failures"
[ "$fail" = 0 ]
