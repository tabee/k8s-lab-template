#!/usr/bin/python
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
# Test stub of kubernetes.core.k8s_log for tests/recover-sim-tests.sh. The cluster is
# the in-memory model in tests/recover-sim/engine.py (SIM_DIR, SIM_STATE).
from __future__ import annotations

import os
import sys

from ansible.module_utils.basic import AnsibleModule  # noqa: F401 (makes Ansible ship the module utils)

DOCUMENTATION = "module: k8s_log\nshort_description: test stub\n"


def main():
    sys.path.insert(0, os.environ["SIM_DIR"])
    import engine
    engine.run_module("k8s_log")


if __name__ == "__main__":
    main()
