#!/usr/bin/env bash
# Stage 7 (KSOPS): helpers for encrypted secrets under secrets/.
# Runbook: docs/learning-path/stage-7-ksops.md. Usage in the k8s-lab repo root:
#
#   ansible/scripts/sops-secret.sh export NS NAME [FILE]
#       Store secret NAME from namespace NS (cluster) encrypted,
#       default target secrets/NS/NAME.sops.yaml. Labels stay (managed-by
#       becomes argocd), annotation only Prune=false,Delete=false. Plaintext
#       only goes through a pipe, never to disk. Afterwards the file is
#       decrypted and compared with the cluster (hash).
#       Target exists already: same content = SKIP, otherwise ABORT.
#   ansible/scripts/sops-secret.sh from-env NS NAME ENVFILE [FILE]
#       Store secret NAME (namespace NS) from an env file (lines KEY=VALUE,
#       comments # ok, mode 0600) encrypted, without a cluster.
#       Stage 8b: ENVFILE ~/.config/k8s-lab/s3-cnpg-k3s-lab.env (from
#       backup-host.yml). Plaintext only in the pipe; then hash comparison
#       decrypted file = env file. Target present: same SKIP, otherwise ABORT.
#   ansible/scripts/sops-secret.sh from-files NS NAME TYPE KEY=VALUE|KEY=@FILE ...
#       Secret NAME of type TYPE (Opaque, kubernetes.io/basic-auth, ...) from
#       single values. KEY=@FILE reads the file (mode 0600, one line,
#       one trailing newline does not count), KEY=VALUE only for values that are
#       no secret (visible in the process list). Target secrets/NS/NAME.sops.yaml.
#       Stage 8c: Gitea DB, Gitea admin, restic repo password.
#       Hash comparison as with from-env. Target present: same SKIP, otherwise ABORT.
#   ansible/scripts/sops-secret.sh from-json TARGET [--check]
#       Secret as JSON from stdin (data base64, comes from lab.sh init), store
#       encrypted to TARGET (secrets/.../*.sops.yaml). Plaintext only in
#       the pipe. Target present: same hash = SKIP, otherwise ABORT. --check creates
#       nothing, only reports SKIP, ABORT or "WOULD store NEW".
#   ansible/scripts/sops-secret.sh hash-cluster NS NAME
#   ansible/scripts/sops-secret.sh hash-file FILE
#       SHA-256 over type and data (secret in the cluster or decrypted
#       file). Same hash = byte-identical values. Never shows values.
#
# Needs kubectl (KUBECONFIG), sops, python3. Decrypting needs the
# private age key (SOPS_AGE_KEY_FILE or ~/.config/sops/age/keys.txt).
set -euo pipefail

usage() { sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

# Canonical form (type + data as base64, sorted) -> SHA-256. stringData
# counts like data (that is how the API stores it). Reads JSON from stdin.
canon_hash() {
  python3 -c '
import base64, hashlib, json, sys
o = json.load(sys.stdin)
d = dict(o.get("data") or {})
for k, v in (o.get("stringData") or {}).items():
    d[k] = base64.b64encode(v.encode()).decode()
c = json.dumps({"type": o.get("type", "Opaque"), "data": d}, sort_keys=True, separators=(",", ":"))
print(hashlib.sha256(c.encode()).hexdigest())'
}

hash_cluster() { kubectl get secret -n "$1" "$2" -o json | canon_hash; }
hash_file() { sops decrypt --input-type yaml --output-type json "$1" | canon_hash; }

# Clean secret for Git: only name, namespace, labels, type, data.
clean() {
  python3 -c '
import json, sys
o = json.load(sys.stdin)
m = o["metadata"]
labels = dict(m.get("labels") or {})
labels["app.kubernetes.io/managed-by"] = "argocd"
out = {
    "apiVersion": "v1",
    "kind": "Secret",
    "metadata": {
        "name": m["name"],
        "namespace": m["namespace"],
        "labels": labels,
        # Argo CD creates and updates, but never deletes (not even when the
        # app is deleted or when the file is missing).
        "annotations": {"argocd.argoproj.io/sync-options": "Prune=false,Delete=false"},
    },
    "type": o.get("type", "Opaque"),
    "data": o.get("data") or {},
}
json.dump(out, sys.stdout)'
}

# Secret from an env file (KEY=VALUE): same form as clean(). Never shows values.
env_secret() {
  python3 - "$1" "$2" "$3" <<'PY'
import base64, json, re, sys
ns, name, path = sys.argv[1:4]
data = {}
with open(path, encoding="utf-8") as f:
    for nr, z in enumerate(f, 1):
        z = z.rstrip("\n")
        if not z.strip() or z.lstrip().startswith("#"):
            continue
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$", z)
        if not m or m.group(1) in data:
            sys.exit("ABORT: %s line %d: expected KEY=VALUE (key only once)" % (path, nr))
        data[m.group(1)] = base64.b64encode(m.group(2).encode()).decode()
if not data:
    sys.exit("ABORT: %s contains no KEY=VALUE line" % path)
json.dump({"apiVersion": "v1", "kind": "Secret",
           "metadata": {"name": name, "namespace": ns,
                        "labels": {"app.kubernetes.io/managed-by": "argocd"},
                        "annotations": {"argocd.argoproj.io/sync-options": "Prune=false,Delete=false"}},
           "type": "Opaque", "data": data}, sys.stdout)
PY
}

# Secret from KEY=VALUE / KEY=@FILE (stage 8c). Never shows values.
files_secret() {
  python3 - "$@" <<'PY'
import base64, json, os, re, stat, sys
ns, name, stype = sys.argv[1:4]
data = {}
for arg in sys.argv[4:]:
    m = re.match(r"^([-._A-Za-z0-9]+)=(.*)$", arg, re.S)
    if not m or m.group(1) in data:
        sys.exit("ABORT: expected KEY=VALUE or KEY=@FILE, key only once (%s)" % arg.split("=", 1)[0])
    k, v = m.group(1), m.group(2)
    if v.startswith("@"):
        p = os.path.expanduser(v[1:])
        if not os.path.isfile(p):
            sys.exit("ABORT: %s is missing (value for %s)." % (p, k))
        mode = stat.S_IMODE(os.stat(p).st_mode)
        if mode != 0o600:
            sys.exit("ABORT: %s has mode %o, expected 600 (chmod 600 %s)." % (p, mode, p))
        with open(p, encoding="utf-8") as f:
            v = f.read()
        if v.endswith("\n"):
            v = v[:-1]
        if not v or "\n" in v:
            sys.exit("ABORT: %s must contain exactly one non-empty line." % p)
    elif not v:
        sys.exit("ABORT: %s is empty." % k)
    data[k] = base64.b64encode(v.encode()).decode()
if not data:
    sys.exit("ABORT: no values given")
if stype == "kubernetes.io/basic-auth" and not {"username", "password"} <= set(data):
    sys.exit("ABORT: kubernetes.io/basic-auth needs username and password")
json.dump({"apiVersion": "v1", "kind": "Secret",
           "metadata": {"name": name, "namespace": ns,
                        "labels": {"app.kubernetes.io/managed-by": "argocd"},
                        "annotations": {"argocd.argoproj.io/sync-options": "Prune=false,Delete=false"}},
           "type": stype, "data": data}, sys.stdout)
PY
}

# Store encrypted: store_new TARGET EXPECTEDHASH SOURCE COMMAND...
# COMMAND writes the secret as JSON to stdout (plaintext only in the pipe).
store_new() {
  local target=$1 expected=$2 source=$3 tmp actual
  shift 3
  mkdir -p "$(dirname "$target")"
  tmp=$(mktemp "$(dirname "$target")/.sops-export.XXXXXX")
  # shellcheck disable=SC2064 # hold tmp now
  trap "rm -f '$tmp'" EXIT
  "$@" | sops encrypt --input-type json --output-type yaml --filename-override "$target" /dev/stdin > "$tmp"
  # Empty values ("") are left in plaintext by sops (nothing to protect, e.g. the empty ACME token); everything else must be ENC.
  if ! awk '/^data:/ {d = 1; next} /^[^ ]/ {d = 0} d && $2 !~ /^ENC\[AES256_GCM/ && $2 != "\"\"" {bad = 1} END {exit bad}' "$tmp"; then
    echo "ABORT: result contains unencrypted values. Nothing stored." >&2; exit 1
  fi
  actual=$(hash_file "$tmp")
  if [ "$actual" != "$expected" ]; then
    echo "ABORT: decrypted file does not match $source (${actual:0:16}... != ${expected:0:16}...)." >&2; exit 1
  fi
  chmod 0644 "$tmp"
  mv -n "$tmp" "$target"
  if [ -e "$tmp" ]; then
    echo "ABORT: $target has been created in the meantime. Nothing overwritten." >&2; exit 1
  fi
  echo "new: $target (encrypted, decrypted = $source, sha256 ${expected:0:16}...)"
}

[ $# -ge 1 ] || usage
cmd=$1; shift
case "$cmd" in
  hash-cluster) [ $# -eq 2 ] || usage; hash_cluster "$1" "$2" ;;
  hash-file) [ $# -eq 1 ] || usage; hash_file "$1" ;;
  export)
    [ $# -ge 2 ] && [ $# -le 3 ] || usage
    ns=$1; name=$2; target=${3:-secrets/$ns/$name.sops.yaml}
    if [ ! -f .sops.yaml ] || [ ! -d .git ]; then
      echo "ABORT: run in the k8s-lab repo root (.sops.yaml is missing here)." >&2; exit 1
    fi
    case "$target" in
      secrets/*.sops.yaml) ;;
      *) echo "ABORT: target must be secrets/.../*.sops.yaml (rule in .sops.yaml), is: $target" >&2; exit 1 ;;
    esac
    expected=$(hash_cluster "$ns" "$name")
    if [ -e "$target" ]; then
      actual=$(hash_file "$target")
      if [ "$actual" = "$expected" ]; then
        echo "SKIP (identical to the cluster, sha256 ${expected:0:16}...): $target"; exit 0
      fi
      echo "ABORT: $target exists with different content than $ns/$name in the cluster." >&2
      echo "  File ${actual:0:16}..., cluster ${expected:0:16}... Nothing overwritten." >&2
      exit 1
    fi
    mkdir -p "$(dirname "$target")"
    tmp=$(mktemp "$(dirname "$target")/.sops-export.XXXXXX")
    trap 'rm -f "$tmp"' EXIT
    # --filename-override: sops picks the rule from .sops.yaml by the target.
    kubectl get secret -n "$ns" "$name" -o json | clean \
      | sops encrypt --input-type json --output-type yaml --filename-override "$target" /dev/stdin > "$tmp"
    # Every value under data: must be encrypted.
    if ! awk '/^data:/ {d = 1; next} /^[^ ]/ {d = 0} d && $2 !~ /^ENC\[AES256_GCM/ {bad = 1} END {exit bad}' "$tmp"; then
      echo "ABORT: result contains unencrypted values. Nothing stored." >&2; exit 1
    fi
    actual=$(hash_file "$tmp")
    if [ "$actual" != "$expected" ]; then
      echo "ABORT: decrypted file does not match the cluster (${actual:0:16}... != ${expected:0:16}...)." >&2; exit 1
    fi
    chmod 0644 "$tmp"
    mv -n "$tmp" "$target"
    if [ -e "$tmp" ]; then
      echo "ABORT: $target has been created in the meantime. Nothing overwritten." >&2; exit 1
    fi
    echo "new: $target (encrypted, decrypted = cluster, sha256 ${expected:0:16}...)"
    ;;
  from-env)
    [ $# -ge 3 ] && [ $# -le 4 ] || usage
    ns=$1; name=$2; envfile=$3; target=${4:-secrets/$ns/$name.sops.yaml}
    if [ ! -f .sops.yaml ] || [ ! -d .git ]; then
      echo "ABORT: run in the k8s-lab repo root (.sops.yaml is missing here)." >&2; exit 1
    fi
    case "$target" in
      secrets/*.sops.yaml) ;;
      *) echo "ABORT: target must be secrets/.../*.sops.yaml (rule in .sops.yaml), is: $target" >&2; exit 1 ;;
    esac
    if [ ! -f "$envfile" ]; then echo "ABORT: $envfile is missing (run backup-host.yml first)." >&2; exit 1; fi
    mode=$(stat -c %a "$envfile")
    if [ "$mode" != 600 ]; then
      echo "ABORT: $envfile has mode $mode, expected 600 (chmod 600 $envfile)." >&2; exit 1
    fi
    # Read only first: report format errors cleanly (line number, never values).
    env_secret "$ns" "$name" "$envfile" > /dev/null || exit 1
    expected=$(env_secret "$ns" "$name" "$envfile" | canon_hash)
    if [ -e "$target" ]; then
      actual=$(hash_file "$target")
      if [ "$actual" = "$expected" ]; then
        echo "SKIP (identical to $envfile, sha256 ${expected:0:16}...): $target"; exit 0
      fi
      echo "ABORT: $target exists with different content than $envfile." >&2
      echo "  File ${actual:0:16}..., env ${expected:0:16}... Nothing overwritten." >&2
      exit 1
    fi
    mkdir -p "$(dirname "$target")"
    tmp=$(mktemp "$(dirname "$target")/.sops-export.XXXXXX")
    trap 'rm -f "$tmp"' EXIT
    env_secret "$ns" "$name" "$envfile" | sops encrypt --input-type json --output-type yaml --filename-override "$target" /dev/stdin > "$tmp"
    if ! awk '/^data:/ {d = 1; next} /^[^ ]/ {d = 0} d && $2 !~ /^ENC\[AES256_GCM/ {bad = 1} END {exit bad}' "$tmp"; then
      echo "ABORT: result contains unencrypted values. Nothing stored." >&2; exit 1
    fi
    actual=$(hash_file "$tmp")
    if [ "$actual" != "$expected" ]; then
      echo "ABORT: decrypted file does not match $envfile (${actual:0:16}... != ${expected:0:16}...)." >&2; exit 1
    fi
    chmod 0644 "$tmp"
    mv -n "$tmp" "$target"
    if [ -e "$tmp" ]; then
      echo "ABORT: $target has been created in the meantime. Nothing overwritten." >&2; exit 1
    fi
    echo "new: $target (encrypted, decrypted = $envfile, sha256 ${expected:0:16}...)"
    ;;
  from-json)
    [ $# -ge 1 ] && [ $# -le 2 ] || usage
    target=$1; check=0
    if [ "${2:-}" = --check ]; then check=1; elif [ $# -eq 2 ]; then usage; fi
    if [ ! -f .sops.yaml ] || [ ! -d .git ]; then
      echo "ABORT: run in the k8s-lab repo root (.sops.yaml is missing here)." >&2; exit 1
    fi
    case "$target" in
      secrets/*.sops.yaml) ;;
      *) echo "ABORT: target must be secrets/.../*.sops.yaml (rule in .sops.yaml), is: $target" >&2; exit 1 ;;
    esac
    # Plaintext only in this variable (memory), printf is a builtin.
    JSON=$(cat)
    expected=$(printf '%s' "$JSON" | canon_hash)
    if [ -e "$target" ]; then
      actual=$(hash_file "$target")
      if [ "$actual" = "$expected" ]; then
        echo "SKIP (identical to the host files, sha256 ${expected:0:16}...): $target"; exit 0
      fi
      echo "ABORT: $target exists with different content than the host files." >&2
      echo "  File ${actual:0:16}..., host ${expected:0:16}... Nothing overwritten." >&2
      exit 1
    fi
    if [ "$check" = 1 ]; then
      echo "WOULD store NEW (sha256 ${expected:0:16}...): $target"; exit 0
    fi
    emit_json() { printf '%s' "$JSON"; }
    store_new "$target" "$expected" "the host files" emit_json
    ;;
  from-files)
    [ $# -ge 4 ] || usage
    ns=$1; name=$2; target=secrets/$1/$2.sops.yaml
    if [ ! -f .sops.yaml ] || [ ! -d .git ]; then
      echo "ABORT: run in the k8s-lab repo root (.sops.yaml is missing here)." >&2; exit 1
    fi
    # Read only first: report errors cleanly (file, mode, never values).
    files_secret "$@" > /dev/null || exit 1
    expected=$(files_secret "$@" | canon_hash)
    if [ -e "$target" ]; then
      actual=$(hash_file "$target")
      if [ "$actual" = "$expected" ]; then
        echo "SKIP (identical to the source files, sha256 ${expected:0:16}...): $target"; exit 0
      fi
      echo "ABORT: $target exists with different content than the source files ($ns/$name)." >&2
      echo "  File ${actual:0:16}..., sources ${expected:0:16}... Nothing overwritten." >&2
      exit 1
    fi
    store_new "$target" "$expected" "the source files" files_secret "$@"
    ;;
  *) usage ;;
esac
