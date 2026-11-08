#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
# Installs the pinned security scanners (ci/security-tools.env) into one folder, SHA-256 checked.
# Used by the CI workflows (GitHub Actions and Gitea Actions) and by anybody who wants the same versions locally.
#
#   bash scripts/install-security-tools.sh [DEST] [TOOL...]
#
# DEST defaults to $HOME/.local/bin. TOOL: gitleaks trivy trufflehog kubeconform actionlint helm (default: all).
# In CI the folder is put on PATH by the workflow ($GITHUB_PATH). Only linux/amd64; on another system install the
# tools with your package manager (the versions in ci/security-tools.env are the tested ones).
# Offline: SECURITY_TOOLS_CACHE=DIR uses DIR/<archive name> instead of downloading (still checksum-checked).
# Exit code: 0 = installed, 1 = download or checksum error (nothing is installed from an archive that did not match), 2 = usage.
set -eu
cd "$(dirname "$0")/.."
case "${1:-}" in
  -h | --help)
    sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  -*)
    echo "unknown option: $1 (usage: bash scripts/install-security-tools.sh [DEST] [TOOL...], --help)" >&2
    exit 2
    ;;
esac
dest=${1:-$HOME/.local/bin}
[ $# -gt 0 ] && shift
all="gitleaks trivy trufflehog kubeconform actionlint helm"
tools=${*:-$all}

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64) ;;
  *)
    echo "This installer is for linux/amd64 only (this is $(uname -s)-$(uname -m))." >&2
    echo "Install the tools with your package manager, tested versions: ci/security-tools.env" >&2
    exit 2
    ;;
esac

# shellcheck source=ci/security-tools.env
. ci/security-tools.env
mkdir -p "$dest"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

install_one() {
  local name=$1 up url sha archive member
  up=$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')
  eval "url=\${${up}_URL}; sha=\${${up}_SHA256}"
  archive=$tmp/$name.tgz
  if [ -n "${SECURITY_TOOLS_CACHE:-}" ] && [ -f "$SECURITY_TOOLS_CACHE/$(basename "$url")" ]; then
    cp "$SECURITY_TOOLS_CACHE/$(basename "$url")" "$archive"
  else
    curl -fsSL --retry 3 --retry-delay 2 -o "$archive" "$url" || {
      echo "ERROR $name: download failed: $url" >&2
      return 1
    }
  fi
  if ! printf '%s  %s\n' "$sha" "$archive" | sha256sum -c --status -; then
    echo "ERROR $name: SHA-256 does not match ci/security-tools.env (got $(sha256sum "$archive" | cut -d' ' -f1)). Nothing installed." >&2
    return 1
  fi
  member=$name
  [ "$name" = helm ] && member=linux-amd64/helm
  mkdir -p "$tmp/x-$name"
  tar -xzf "$archive" -C "$tmp/x-$name" "$member"
  install -m 0755 "$tmp/x-$name/$member" "$dest/$name"
  echo "installed $name $(eval "echo \${${up}_VERSION}") -> $dest/$name"
}

rc=0
for t in $tools; do
  case " $all " in
    *" $t "*) install_one "$t" || rc=1 ;;
    *)
      echo "usage: bash scripts/install-security-tools.sh [DEST] [$all]" >&2
      exit 2
      ;;
  esac
done
exit $rc
