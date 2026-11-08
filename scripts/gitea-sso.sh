#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
# Shared read-only probe; pass the namespace/context-aware kubectl command prefix.
# A failed exec must never count as a present source.
sso_source_present_with() {
  local sources
  sources=$("$@" exec "deploy/${GITEA_SSO_DEPLOY:-gitea}" -c gitea -- gitea admin auth list --vertical-bars 2>/dev/null) || return 1
  printf '%s\n' "$sources" | awk -F'|' '{n = $2; gsub(/[ \t]/, "", n)} n == "keycloak" {f = 1} END {exit !f}'
}
