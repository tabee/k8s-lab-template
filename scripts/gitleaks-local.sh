#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
# Secret scan with gitleaks, locally and in the Gitea workflow (docs: docs/how-to/secret-scan.md).
#   bash scripts/gitleaks-local.sh            whole history (all branches and tags)
#   bash scripts/gitleaks-local.sh --staged   only the staged, not yet committed changes
# Locally the script starts the gitleaks image with podman (otherwise docker) and
# calls itself inside it with --direct. The workflow
# .github/workflows/gitleaks.yml calls --direct directly: the scan options
# therefore exist only here. The image (version and digest) exists only in the workflow.
# Only redacted findings are printed (--redact), never values.
# Exit code: 0 = nothing found, 1 = finding, other = error.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
workflow=.github/workflows/gitleaks.yml
config=.gitleaks.toml

mode=historie
direct=0
for arg in "$@"; do
  case "$arg" in
    --direct) direct=1 ;;
    --staged) mode=staged ;;
    *) echo "Unknown option: $arg (allowed: --staged)" >&2; exit 2 ;;
  esac
done

if [ "$direct" = 1 ]; then
  # The actual gitleaks options run here (in the container or in the workflow).
  cd "$root"
  args=(git --redact --no-banner --no-color --verbose --exit-code 1 --ignore-gitleaks-allow --config "$config")
  if [ "$mode" = staged ]; then
    args+=(--staged)
  fi
  exec gitleaks "${args[@]}" .
fi

cd "$root"
if [ ! -f "$workflow" ] || [ ! -f "$config" ]; then
  echo "ABORT: $workflow or $config is missing in the repo root $root." >&2
  exit 2
fi
mapfile -t lines < <(sed -n 's/^[[:space:]]*image:[[:space:]]*\(ghcr\.io\/gitleaks\/gitleaks:[^[:space:]]*\).*$/\1/p' "$workflow")
if [ "${#lines[@]}" -ne 1 ]; then
  echo "ABORT: $workflow must contain exactly one line 'image: ghcr.io/gitleaks/gitleaks:...' (found: ${#lines[@]})." >&2
  exit 2
fi
image=${lines[0]}
case "$image" in
  *@sha256:*) ;;
  *) echo "ABORT: image without digest (@sha256:...): $image" >&2; exit 2 ;;
esac

engine=${GITLEAKS_ENGINE:-}
if [ -z "$engine" ]; then
  if command -v podman >/dev/null; then
    engine=podman
  elif command -v docker >/dev/null; then
    engine=docker
  else
    echo "ABORT: neither podman nor docker found." >&2
    exit 2
  fi
fi

echo "gitleaks: $image ($engine, mode: $mode)"
extra=()
if [ "$mode" = staged ]; then
  extra+=(--staged)
fi
# Mount the repo read-only. label=disable: no SELinux relabel in the own repo.
# safe.directory: the container user is not the owner of the repo (docker).
exec "$engine" run --rm --security-opt label=disable --entrypoint bash \
  -v "$root:/repo:ro" -w /repo \
  -e GIT_CONFIG_COUNT=1 -e GIT_CONFIG_KEY_0=safe.directory -e GIT_CONFIG_VALUE_0=/repo \
  "$image" scripts/gitleaks-local.sh --direct ${extra[@]+"${extra[@]}"}
