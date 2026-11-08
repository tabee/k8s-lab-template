#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
# Builds the docs site with Zensical from docs/ into TARGET.
# Configuration: zensical.toml in the repo root. Runs the same way in the pod
# (deployment docs, container builder) and locally:
#   bash docs/build.sh /workspace/docs-site
# TARGET must not exist or must be empty. Only the build output site/ in the
# repo root is deleted (listed in .gitignore, like .cache/).
# Tools (Python venv, plugin) are cached under ~/.cache/k8s-lab-docs/.
# Needs: bash, git, python3 (>= 3.11) with venv, GNU cp. Guide:
# docs/how-to/docs-site.md
# Also used for the notes sites (gitops/charts/notes-site, docs/how-to/notes-sites.md):
#   ZENSICAL_PROJECT  project folder instead of the repo root (copy of the notes repo)
#   ZENSICAL_PREPARE  Python script that adapts zensical.toml there (before the build)
#   ZENSICAL_STRICT=0 build without --strict (warnings only in the log)
#   MERMAID_SELF_HOST=0  no self-hosted Mermaid (the theme then loads it from unpkg.com)
# Without these variables the behaviour is unchanged. The pins (Zensical,
# Mermaid) live only here (versions: docs/reference/versions.md).
set -euo pipefail

# Mermaid, self-hosted (docs/vendor-mermaid.py): exact version and sha512 of the
# npm tarball (npm view mermaid@VERSION dist.integrity). A new version: change
# both, build, check the diagrams (docs/reference/acceptance-checks.md).
MERMAID_VERSION=11.17.2
MERMAID_TGZ_SHA512='V6K3C8EBdEsPFZXSKMJe6ppQOENxuHARr9GvHX4hh47lAbhMRD9qf4oEK7LoaRQxULMa80/qt5gHO73aCleBBg=='
# For tests: another URL (file://...) for the tarball.
MERMAID_TGZ_URL=${MERMAID_TGZ_URL:-}

out=${1:?Usage: bash docs/build.sh TARGET_DIR}
if [ -e "$out" ] && [ -n "$(ls -A "$out")" ]; then
  echo "ABORT: $out exists and is not empty." >&2
  exit 1
fi
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
repo=${ZENSICAL_PROJECT:-$(git -C "$here" rev-parse --show-toplevel)}

# Build the tools once per pin state (key = hash of the pins).
cache=${XDG_CACHE_HOME:-$HOME/.cache}/k8s-lab-docs
tools=$cache/venv-$(sha256sum < "$here/requirements.txt" | cut -c1-16)
if [ ! -e "$tools/ok" ]; then
  echo "Building tools: $tools"
  rm -rf "$tools"
  python3 -m venv "$tools"
  "$tools/bin/pip" install --quiet --disable-pip-version-check --no-cache-dir \
    --require-hashes --only-binary :all: -r "$here/requirements.txt"
  touch "$tools/ok"
fi

# Notes sites: adapt zensical.toml, delete excluded files, create the
# graph page. Python from the venv (tomllib, pathspec, yaml).
if [ -n "${ZENSICAL_PREPARE:-}" ]; then
  "$tools/bin/python" "$ZENSICAL_PREPARE" "$repo"
fi


# Build in the repo root (docs/concepts/network-edge.md -> /concepts/network-edge/).
# --strict: warnings (for example a dead internal link) abort the build. The
# notes sites set ZENSICAL_STRICT=0: one broken link must not block the whole
# site, the warning stays in the log. Zensical always colours its output;
# sed strips the colour codes (readable in kubectl logs).
strict=(--strict)
if [ "${ZENSICAL_STRICT:-1}" = 0 ]; then
  strict=()
fi
cd "$repo"
"$tools/bin/zensical" build --clean "${strict[@]}" -f zensical.toml 2>&1 \
  | sed -u 's/\x1b\[[0-9;]*m//g'
# Self-hosted Mermaid (no CDN at view time, SRI): after everything that writes
# pages, so every page gets the script tag. Only Python standard library.
if [ "${MERMAID_SELF_HOST:-1}" = 0 ]; then
  echo "MERMAID_SELF_HOST=0: Mermaid comes from the CDN (theme default)"
else
  "$tools/bin/python" "$here/vendor-mermaid.py" "$repo/site" "$cache" \
    "$MERMAID_VERSION" "$MERMAID_TGZ_SHA512" ${MERMAID_TGZ_URL:+"$MERMAID_TGZ_URL"}
fi
mkdir -p "$out"
cp -a site/. "$out/"
echo "Done: $out ($(find "$out" -name '*.html' | wc -l) HTML pages)"
