#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
# Install/check the control-PC toolchain on Ubuntu 24.04, without touching the lab.
# Release binaries live in ~/.local/bin; only missing apt packages need sudo.
set -euo pipefail
cd "$(dirname "$0")/.."
root=$PWD
# Version probes must not phone home or update local checkpoint caches.
export CHECKPOINT_DISABLE=1 SOPS_DISABLE_VERSION_CHECK=1
# shellcheck source=ci/control-tools.env
. ci/control-tools.env
mode=install
no_upgrade=0
skip_apt=0
skip_ansible=0
usage() {
  echo "Usage: bash scripts/install-tools.sh [--check|--dry-run] [--no-upgrade] [--skip-apt] [--skip-ansible]"
  echo "--skip-apt/--skip-ansible are partial sandbox runs, not a complete host readiness check."
}
for arg in "$@"; do
  case "$arg" in
    --check) [ "$mode" != dry-run ] || { usage >&2; exit 2; }; mode=check ;;
    --dry-run) [ "$mode" != check ] || { usage >&2; exit 2; }; mode=dry-run ;;
    --no-upgrade) no_upgrade=1 ;;
    --skip-apt) skip_apt=1 ;;
    --skip-ansible) skip_ansible=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
case "$(uname -s)-$(uname -m)" in
  Linux-x86_64) ;;
  *) echo "ERROR: only Linux amd64 is supported (including the pinned VM image)." >&2; exit 2 ;;
esac
dest=$HOME/.local/bin
export PIPX_HOME=${PIPX_HOME:-$HOME/.local/share/pipx}
export PIPX_BIN_DIR=$dest
venv=$PIPX_HOME/venvs/ansible-core
case ":$PATH:" in
  *":$dest:"*) ;;
  *) echo "WARNING: prepend $dest to PATH before operating the lab." >&2 ;;
esac
rc=0
changes=0
tmp=
trap '[ -z "$tmp" ] || rm -rf "$tmp"' EXIT
need() {
  echo "missing/wrong $1 (want $2)"
  if [ "$mode" = check ]; then rc=1; return 1; fi
  if [ "$mode" = dry-run ]; then echo "would install $1 $2"; return 1; fi
  if [ "$no_upgrade" = 1 ] && [ "$3" != missing ]; then
    echo "ERROR: --no-upgrade preserves $1 $3" >&2
    rc=1
    return 1
  fi
}
apt_packages() {
  local p status
  local missing=()
  local packages=(ca-certificates curl openssl openssh-client git gh jq unzip tar coreutils gawk
    python3 python3-venv python3-yaml pipx qemu-system-x86 qemu-utils libvirt-daemon-system
    libvirt-clients podman ufw uidmap dbus-user-session acl rsync gzip util-linux)
  for p in "${packages[@]}"; do
    status=$(dpkg-query -W -f='${Status}' "$p" 2>/dev/null || true)
    if [ "$status" = 'install ok installed' ]; then echo "ok apt $p"; else missing+=("$p"); fi
  done
  [ "${#missing[@]}" -gt 0 ] || return 0
  echo "missing apt ${missing[*]}"
  case "$mode" in
    check) rc=1; return ;;
    dry-run) echo "would apt-get install ${missing[*]}"; return ;;
  esac
  # Validate once, then never open a second password prompt. No password is stored.
  local elevate=()
  if [ "$(id -u)" != 0 ]; then sudo -v; elevate=(sudo -n); fi
  "${elevate[@]}" apt-get update
  "${elevate[@]}" apt-get install -y "${missing[@]}"
  changes=$((changes + 1))
}
version() {
  local name=$1 cmd=${2:-$1} output
  if [ $# = 1 ] && [ -x "$dest/$name" ]; then cmd=$dest/$name; fi
  command -v "$cmd" >/dev/null 2>&1 || return 1
  case "$name" in
    tofu) output=$("$cmd" version 2>/dev/null) ;;
    kubectl) output=$("$cmd" version --client -o json 2>/dev/null) || return 1
      printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["clientVersion"]["gitVersion"].removeprefix("v"))'
      return ;;
    helm) output=$("$cmd" version --short 2>/dev/null) ;;
    sops|age|age-keygen|zizmor) output=$("$cmd" --version 2>/dev/null) ;;
  esac
  # Use a complete semantic version, never a substring (1.2.3 != 1.2.30).
  printf '%s\n' "$output" | sed -n '1s/^[^0-9]*\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)\([+ ].*\)\{0,1\}$/\1/p'
}
install_binary() {
  local name=$1 up wanted current url sha archive member companion
  up=${name^^}
  local vvar=${up}_VERSION uvar=${up}_URL svar=${up}_SHA256
  wanted=${!vvar}; url=${!uvar}; sha=${!svar}
  current=$(version "$name" || true)
  if [ -z "$current" ] && { [ -x "$dest/$name" ] || command -v "$name" >/dev/null 2>&1; }; then current=unknown; fi
  if [ -x "$dest/$name" ] && [ "$(command -v "$name" || true)" != "$dest/$name" ]; then
    echo "WARNING: $name is installed locally; prepend $dest to PATH to use it." >&2
  fi
  if [ "$current" = "$wanted" ]; then
    if [ "$name" != age ] || [ "$(version age-keygen || true)" = "$wanted" ]; then
      echo "ok $name $wanted"; return
    fi
    companion=$(version age-keygen || true)
    current=${companion:-missing}
    if [ -z "$companion" ] && { [ -x "$dest/age-keygen" ] || command -v age-keygen >/dev/null 2>&1; }; then current=unknown; fi
  fi
  need "$name" "$wanted" "${current:-missing}" || return 0
  [ -n "$tmp" ] || tmp=$(mktemp -d)
  archive=$tmp/$(basename "$url")
  if [ -n "${CONTROL_TOOLS_CACHE:-}" ]; then
    cp "$CONTROL_TOOLS_CACHE/$(basename "$url")" "$archive"
  else
    curl -fLsS --retry 3 -o "$archive" "$url"
  fi
  if ! printf '%s  %s\n' "$sha" "$archive" | sha256sum -c --status -; then
    echo "ERROR: $name SHA-256 mismatch; nothing installed from this download." >&2
    exit 1
  fi
  mkdir -p "$tmp/x-$name" "$dest"
  case "$name" in
    tofu) unzip -q "$archive" tofu -d "$tmp/x-$name"; member=tofu ;;
    helm) member=linux-amd64/helm; tar -xzf "$archive" -C "$tmp/x-$name" "$member" ;;
    age) member=age/age; tar -xzf "$archive" -C "$tmp/x-$name" age/age age/age-keygen ;;
    *) member=$name; cp "$archive" "$tmp/x-$name/$member" ;;
  esac
  # Rename on the same filesystem, so an interrupted copy cannot leave a partial executable.
  install -m 0755 "$tmp/x-$name/$member" "$dest/.$name.install-$$"
  mv -f "$dest/.$name.install-$$" "$dest/$name"
  if [ "$name" = age ]; then
    install -m 0755 "$tmp/x-$name/age/age-keygen" "$dest/.age-keygen.install-$$"
    mv -f "$dest/.age-keygen.install-$$" "$dest/age-keygen"
  fi
  [ "$(version "$name" "$dest/$name")" = "$wanted" ] || {
    echo "ERROR: unexpected installed version for $name" >&2; exit 1;
  }
  echo "installed $name $wanted"
  changes=$((changes + 1))
}
python_version() {
  [ -x "$venv/bin/python" ] || return 1
  "$venv/bin/python" -c 'import importlib.metadata,sys; print(importlib.metadata.version(sys.argv[1]))' "$1" 2>/dev/null
}
prepare_python() {
  [ -n "$tmp" ] || tmp=$(mktemp -d)
  [ ! -d "$tmp/wheels" ] || return 0
  python3 -m venv "$tmp/bootstrap"
  mkdir "$tmp/wheels"
  # Hash-check the entire dependency closure before pipx sees any package.
  # Offline pipx resolution also avoids applying --require-hashes to pipx's
  # separate shared-pip bootstrap (which requests pip>=23.1).
  "$tmp/bootstrap/bin/python" -m pip download --require-hashes --only-binary=:all: \
    -r "$root/ci/requirements-control.txt" -d "$tmp/wheels"
  printf '%s  %s\n' "$ANSIBLE_CORE_SHA256" "$tmp/wheels/$(basename "$ANSIBLE_CORE_URL")" | sha256sum -c --status - || {
    echo "ERROR: ansible-core SHA-256 mismatch; no Python packages installed." >&2; exit 1;
  }
}
security_python_tools() {
  local wanted current
  wanted=$(sed -n 's/^zizmor==\([^ ]*\).*/\1/p' ci/requirements-security.txt)
  [ -n "$wanted" ] || { echo "ERROR: missing zizmor pin" >&2; exit 1; }
  current=$(version zizmor || true)
  if [ -z "$current" ] && { [ -x "$dest/zizmor" ] || command -v zizmor >/dev/null 2>&1; }; then current=unknown; fi
  if [ "$current" = "$wanted" ]; then echo "ok zizmor $wanted"; return; fi
  need zizmor "$wanted" "${current:-missing}" || return 0
  [ -n "$tmp" ] || tmp=$(mktemp -d)
  python3 -m venv "$tmp/security-bootstrap"
  mkdir -p "$tmp/security-wheels"
  # Verify the security lock before installing the sole pipx app from local wheels.
  "$tmp/security-bootstrap/bin/python" -m pip download --require-hashes --only-binary=:all: \
    -r "$root/ci/requirements-security.txt" -d "$tmp/security-wheels"
  pipx install --force --pip-args="--no-index --find-links=$tmp/security-wheels" "zizmor==$wanted"
  [ "$(version zizmor)" = "$wanted" ] || { echo "ERROR: zizmor version mismatch" >&2; exit 1; }
  echo "installed zizmor $wanted"
  changes=$((changes + 1))
}
collection_version() {
  python3 -c 'import json,sys; from pathlib import Path
namespace,name=sys.argv[2].split(".")
p=Path(sys.argv[1])/"ansible_collections"/namespace/name/"MANIFEST.json"
print(json.loads(p.read_text())["collection_info"]["version"])' "$HOME/.ansible/collections" "$1" 2>/dev/null
}
ansible_tools() {
  local current package wanted name requirements
  for package in ansible-core kubernetes jsonpatch; do
    case "$package" in
      ansible-core) wanted=$ANSIBLE_CORE_VERSION ;;
      kubernetes) wanted=$KUBERNETES_PYTHON_VERSION ;;
      jsonpatch) wanted=$JSONPATCH_VERSION ;;
    esac
    current=$(python_version "$package" || true)
    # Check the exposed entry points as well as the isolated environment.
    if [ "$package" = ansible-core ]; then
      for name in ansible ansible-playbook ansible-galaxy; do
        if [ ! -x "$dest/$name" ] && [ "$current" = "$wanted" ]; then current=; fi
      done
    fi
    if [ "$current" = "$wanted" ]; then echo "ok $package $wanted"; continue; fi
    if ! need "$package" "$wanted" "${current:-missing}"; then
      # A later lock install must not silently upgrade a protected core version.
      if [ "$package" = ansible-core ] && [ "$no_upgrade" = 1 ] && [ -n "$current" ]; then return; fi
      continue
    fi
    prepare_python
    if [ "$package" = ansible-core ]; then
      pipx install --force --pip-args="--no-index --find-links=$tmp/wheels" "ansible-core==$wanted"
    else
      pipx inject --force --pip-args="--no-index --find-links=$tmp/wheels" ansible-core "$package==$wanted"
    fi
    [ "$(python_version "$package")" = "$wanted" ] || { echo "ERROR: Python version mismatch: $package" >&2; exit 1; }
    echo "installed $package $wanted"
    changes=$((changes + 1))
  done
  # Read exact pins from the existing Galaxy requirements, not a second collection list.
  requirements=$(python3 - <<'PYCOLLECTIONS'
import re
from pathlib import Path
name = None
entries = []
for raw in Path("ansible/requirements.yml").read_text().splitlines():
    line = raw.split("#", 1)[0].strip()
    if not line or line in ("---", "collections:"):
        continue
    match = re.fullmatch(r"- name: ([a-z0-9_]+\.[a-z0-9_]+)", line)
    if match and name is None:
        name = match[1]
        continue
    match = re.fullmatch(r"version: [\"']?([0-9]+\.[0-9]+\.[0-9]+)[\"']?", line)
    if match and name is not None:
        entries.append((name, match[1]))
        name = None
        continue
    raise SystemExit("ERROR: expected exact name/version collection pins in ansible/requirements.yml")
if name is not None or not entries:
    raise SystemExit("ERROR: incomplete collection pins in ansible/requirements.yml")
for name, version in entries:
    print(name, version)
PYCOLLECTIONS
  )
  while read -r name wanted; do
    # Reading the manifest avoids Ansible's temporary-directory creation in --check.
    current=$(collection_version "$name" || true)
    if [ "$current" = "$wanted" ]; then echo "ok $name $wanted"; continue; fi
    need "$name" "$wanted" "${current:-missing}" || continue
    # --no-deps: all collections used by the lab are explicitly pinned in requirements.yml.
    "$dest/ansible-galaxy" collection install --force --no-deps -p "$HOME/.ansible/collections" "$name:$wanted"
    [ "$(collection_version "$name")" = "$wanted" ] || { echo "ERROR: collection version mismatch: $name" >&2; exit 1; }
    echo "installed $name $wanted"
    changes=$((changes + 1))
  done <<< "$requirements"
}
[ "$skip_apt" = 1 ] || apt_packages
for tool in tofu kubectl helm sops age; do install_binary "$tool"; done
[ "$skip_ansible" = 1 ] || ansible_tools
security_python_tools
# Optional site-specific preflight tools cannot be guessed or installed safely.
for tool in ${LAB_TOOLS_EXTRA:-}; do
  if command -v "$tool" >/dev/null 2>&1 || [ -x "/usr/sbin/$tool" ]; then
    echo "ok extra $tool"
  else
    echo "missing extra $tool: install the site-specific tool manually" >&2
    rc=1
  fi
done
echo "changes $changes"
exit "$rc"
