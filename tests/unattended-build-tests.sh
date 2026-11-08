#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
# Offline behaviour tests: no VM, network, credentials or running cluster.
set -eu
R=$(cd "${1:-$(dirname "${BASH_SOURCE[0]}")/..}" && pwd -P)
PYTHONDONTWRITEBYTECODE=1 python3 "$R/tests/unattended-build-tests.py" "$R"
