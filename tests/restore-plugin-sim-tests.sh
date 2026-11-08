#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
# Behaviour test of the barman-cloud plugin wait in ansible/restore-clusters.yml (third real
# `lab.sh rebuild --restore`, 2026-11-03: the plugin pod waited 12 minutes for TLS secrets that
# cert-manager had not issued yet, and the plain Deployment wait gave up after 10 minutes).
# It runs the REAL playbook from the task "Wait until the barman-cloud plugin is ready" on, against stub
# modules (tests/recover-sim/plugin_sim.py) that model cert-manager, the Certificates, the plugin pod
# and the cnpg Argo CD application. One tick per module call, delay 0: no sleeping.
# No cluster, no network, no secret.
# Usage: bash tests/restore-plugin-sim-tests.sh [repo root]
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
R=$(cd "${1:-$HERE/..}" && pwd -P)
SIM=$HERE/recover-sim
fail=0
n=0
ok() { n=$((n + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else echo "FAIL $1 (actual '$2', expected '$3')"; fail=$((fail + 1)); fi; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

if ! command -v ansible-playbook > /dev/null 2>&1 || ! python3 -c 'import yaml' 2> /dev/null; then
  echo "SKIP restore-plugin-sim-tests: ansible-playbook or PyYAML missing"
  exit 0
fi

# sim SCENARIO [extra ansible args] -> exit code in $rc, log in $T/log, state in $T/state.json.
# Budget of the run: 1 min = 60 polls, help after 0.5 min = 30 polls (delay 0).
sim() {
  local sc=$1
  shift
  python3 "$SIM/engine.py" init "$sc" "$T/state.json"
  (
    cd "$R/ansible" || exit 99
    SIM_STATE=$T/state.json SIM_DIR=$SIM ANSIBLE_COLLECTIONS_PATH=$SIM/collections ANSIBLE_FORCE_COLOR=0 \
      ANSIBLE_LOCALHOST_WARNING=False ANSIBLE_INVENTORY_UNPARSED_WARNING=False \
      timeout 300 ansible-playbook restore-clusters.yml \
      --start-at-task "Wait until the barman-cloud plugin is ready (cert-manager, Certificates, Deployment)" \
      -e restore_plugin_timeout_min=1 -e restore_plugin_delay=0 -e restore_plugin_nudge_after_min=0.5 \
      -e restore_plugin_pod_grace_min=0.5 -e restore_dir="$T/render" -e backup_s3_data_dir="$T/nodata" "$@" > "$T/log" 2>&1
  )
  rc=$?
}
events() { python3 "$SIM/engine.py" events "$T/state.json"; }
has() { events | grep -c -- "$1"; }
logs() { grep -c -- "$1" "$T/log"; }
yes() { [ "$1" -gt 0 ] && echo present || echo absent; }
ticks() { python3 "$SIM/engine.py" get "$T/state.json" tick; }
reached_service() { yes "$(logs 'Wait until the barman-cloud plugin Service has a ready endpoint')"; }

# 1. Everything comes up quickly: no help is needed and the play goes on to the Service wait.
sim pl-ok
ok "ok: the plugin wait passes" "$(yes "$(logs 'The barman-cloud plugin is ready after')")" present
ok "ok: the play goes on to the Service wait" "$(reached_service)" present
ok "ok: no sync by hand" "$(has 'one-off sync')" 0
ok "ok: no pod deleted" "$(has 'pod deleted')" 0

# 2. cert-manager is slow (CRD missing for 8 polls, Certificates after 45 polls, later than the help point
#    of 30 polls). The Argo CD sync did not fail, so there is nothing to nudge.
sim pl-slow
ok "slow: the plugin wait passes after the help point" "$(yes "$(logs 'The barman-cloud plugin is ready after')")" present
ok "slow: more than 45 polls were used" "$([ "$(ticks)" -gt 45 ] && echo yes)" yes
ok "slow: a missing CRD is only 'not yet'" "$(yes "$(logs 'Failed to find exact match')")" absent
ok "slow: no sync by hand while the sync did not fail" "$(has 'one-off sync')" 0

# 3. The sync of the cnpg application FAILED and created no Certificate: one sync by hand.
sim pl-nudge
ok "nudge: the plugin wait passes" "$(yes "$(logs 'The barman-cloud plugin is ready after')")" present
ok "nudge: exactly one sync by hand" "$(has 'one-off sync of cnpg')" 1
ok "nudge: the sync carries prune, options and retry of the app" "$(has '"prune": true.*"retry": {"limit": 5}\|"retry": {"limit": 5}.*"prune": true')" 1
ok "nudge: the message says why" "$(yes "$(logs 'One sync was started by hand')")" present

# 3b. The sync is still running (not failed): do not interfere.
sim pl-nudge-running
ok "running sync: no sync by hand" "$(has 'one-off sync')" 0
ok "running sync: the wait ends with the diagnosis" "$([ $rc -ne 0 ] && echo failed)" failed

# 4. The pod is stuck on the missing secrets although the Certificates are Ready: delete the plugin pod once.
sim pl-stuckpod
ok "stuck pod: the plugin wait passes" "$(yes "$(logs 'The barman-cloud plugin is ready after')")" present
ok "stuck pod: exactly one pod delete" "$(has 'pod deleted')" 1
ok "stuck pod: only the plugin pod is selected" "$(has 'pod deleted by selector app.kubernetes.io/name=plugin-barman-cloud in cnpg-system')" 1
ok "stuck pod: the reason is named" "$(yes "$(logs 'ProgressDeadlineExceeded')")" present

# 5. Certificates never become Ready: stop with a diagnosis that names the recovery command.
sim pl-nocerts
ok "no certs: the play stops" "$([ $rc -ne 0 ] && echo failed)" failed
ok "no certs: the stage is named" "$(yes "$(logs 'the Certificates barman-cloud-client and barman-cloud-server in cnpg-system are not Ready')")" present
ok "no certs: the recovery command is named" "$(yes "$(logs 'ansible-playbook restore-clusters.yml')")" present
ok "no certs: the way on is named" "$(yes "$(logs 'recover-files.yml --tags restore,resume,verify')")" present
ok "no certs: the budget variable is named" "$(yes "$(logs 'restore_plugin_timeout_min')")" present
ok "no certs: the play never reaches the Service wait" "$(reached_service)" absent
ok "no certs: at most the budget of polls (60) plus the diagnosis was used" "$([ "$(ticks)" -le 70 ] && echo yes)" yes
ok "no certs: no pod deleted" "$(has 'pod deleted')" 0

# 6. cert-manager never comes up.
sim pl-nocm
ok "no cert-manager: the play stops" "$([ $rc -ne 0 ] && echo failed)" failed
ok "no cert-manager: the stage is named" "$(yes "$(logs 'cert-manager is not running')")" present
ok "no cert-manager: it stopped after the budget, not after 10 minutes" "$([ "$(ticks)" -ge 60 ] && echo yes)" yes

# 7. The Deployment never becomes Available: the pod is deleted once, then the diagnosis.
sim pl-dead
ok "dead plugin: the play stops" "$([ $rc -ne 0 ] && echo failed)" failed
ok "dead plugin: the stage is named" "$(yes "$(logs 'the plugin Deployment plugin-barman-cloud in cnpg-system is not Available')")" present
ok "dead plugin: one pod delete only" "$(has 'pod deleted')" 1

# 8. The budget is one place: a bigger value is used as it is.
sim pl-nocerts -e restore_plugin_timeout_min=1.5
ok "budget: 1.5 min means more polls than 1 min" "$([ "$(ticks)" -ge 85 ] && echo yes)" yes

echo "$n checks, $fail failed"
[ $fail -eq 0 ]
