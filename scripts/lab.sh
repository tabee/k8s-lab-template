#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
# lab.sh: a thin wrapper around rebuilding the whole lab.
# Tofu builds the house (VM), Ansible furnishes it (OS, k3s, Argo CD),
# Argo CD brings the services. This script only calls them in order,
# checks beforehand and takes the time. No values here: everything is in
# infra/envs/local/lab.yaml (+ lab.local.yaml) and in ansible/inventory/group_vars.
#
#   bash scripts/lab.sh up          build the VM and set everything up (idempotent)
#   bash scripts/lab.sh down        tear the VM down (cluster data gone, backups stay);
#                                   refuses while a completed backup's end WAL is not archived yet
#   bash scripts/lab.sh rebuild     down + up, stopwatch per phase and in total.
#                                   --restore keeps the Postgres bucket and applies recovery
#                                   only inside the cluster (Git stays on initdb). A running
#                                   VM gets a new CNPG and K8up backup first. A missing
#                                   completed backup fails the WAL check (no skip). Double
#                                   confirmation (the word 'restore', then the VM name;
#                                   --yes does not skip it). --no-export does not apply.
#   bash scripts/lab.sh purge       down + clean the host thoroughly (double confirmation)
#   bash scripts/lab.sh status      show the state (changes nothing)
#   bash scripts/lab.sh acceptance  measure and test: back up a dummy repo and a dummy table,
#                                   delete, restore, compare
#   bash scripts/lab.sh export      back up the VM disk (parachute before tearing down)
#   bash scripts/lab.sh tools install|check  install/check the control-PC toolchain
#   bash scripts/lab.sh preflight   only the preflight checks
#   bash scripts/lab.sh init        create your own key ring (age, CA, passwords, S3,
#                                   deploy key) and render SOPS files from the templates;
#                                   idempotent, existing files stay (SKIP)
#   bash scripts/lab.sh ca-rotation replace the lab CA without nameConstraints with a new one with nameConstraints
#                                   (the old one is backed up, confirmation, not part of up);
#                                   then the steps in docs/how-to/ca-rotation.md
#   bash scripts/lab.sh secrets     secrets map: path, permissions, copy command (never values)
#   bash scripts/lab.sh customize   write domain, repo address, gateway, VM and ingress networks from lab.yaml into
#                                   gitops/ and zensical.toml (Argo CD only reads Git);
#                                   then commit and push. Idempotent.
#   bash scripts/lab.sh secrets-repo export DIR   copy the SOPS files (ciphertext only, never decrypted) from secrets/
#                                   into DIR, a clone of the private secrets repo (secrets_repo_url, ADR 0022);
#                                   idempotent (SKIP), ABORT on any non-ciphertext file; --prune deletes files
#                                   the source no longer has; then commit and push in DIR yourself.
#   bash scripts/lab.sh secrets-repo import DIR   the other way: put secrets/ from a secrets repo clone into this
#                                   working copy (fresh public clone before init/up; secrets/ stays git-ignored there)
#   bash scripts/lab.sh repo-egress  write the git server address(es) (repo_egress_cidrs) and the SSH port of
#                                   repo_url into the egress NetworkPolicies under gitops/ (idempotent);
#                                   then commit and push. --resolve first looks up the host of repo_url and
#                                   writes repo_egress_cidrs to lab.local.yaml (no question);
#                                   --dry-run shows what would change.
#   bash scripts/lab.sh trust ACTION  source trust for rebuilds (ADR 0023): the commit Argo CD reads from repo_url must be
#                                   the last trusted commit or a descendant whose commits are all SSH-signed by an
#                                   allowed signer (.gitea/allowed_signers of the parent commit). ACTION: status |
#                                   init COMMIT (record the first trusted commit, typed confirmation) | check (verify
#                                   the commit at repo_url now and advance the trusted commit) | release (take the
#                                   pin off Argo CD after a rebuild whose re-check failed, after a passed check).
#                                   up and rebuild pin Argo CD to the verified commit and release it after the
#                                   re-check (issue 71). State outside Git: ~/.config/k8s-lab/trusted-head.
#                                   up, rebuild and preflight run the check (source_trust in lab.yaml: auto | on | off).
#   bash scripts/lab.sh source ACTION  where Argo CD reads the code from (ADR 0024). ACTION: status | github | gitea.
#                                   github: write source: github into lab.local.yaml, then customize and repo-egress
#                                   (repo address github_repo_url, GitHub host keys and address ranges, egress to
#                                   github.com:22 only); gitea: the way back. Argo CD only reads Git, so the change must be
#                                   committed, signed and pushed to main before up/rebuild (docs/how-to/neuaufbau-github.md).
#                                   In github mode the source trust check is always on and the GitHub commit must equal
#                                   the Git server's origin/main (sync lag or a changed mirror aborts). With the Git
#                                   server unreachable it must equal local main (last locally known state, with a
#                                   warning); GitHub ahead of that needs --trust-override (docs/how-to/neuaufbau-github.md).
#   bash scripts/lab.sh sync-host   running VM, new service or new name in git: argocd.yml (Argo CD AppProject
#                                   destinations and the rest of the Argo CD setup) and backup-host.yml (managed
#                                   /etc/hosts block, needs sudo). Idempotent, no VM change, no push.
#   bash scripts/lab.sh replica ACTION  off-host copy of the backups on a second machine (issue #3).
#                                   ACTION: config | hostkey | install | status | verify | mirror | preflight |
#                                   restore DIR (pull the copy back into a NEW empty directory).
#                                   install uses your personal key ONCE, nothing else runs as root.
#   bash scripts/lab.sh alert ACTION  alerts when a backup or the edge fails (issue #8; heartbeat = external ping).
#                                   ACTION: install | status | run | test | verify (default: status).
#   bash scripts/lab.sh restore-drill  prove that Gitea (database + files) comes back from the backups ALONE, in a
#                                   throwaway namespace, timed (issue #4). Double confirmation (the word
#                                   'restore-drill', then the VM name; --yes does not skip it) and a fresh export are
#                                   required; --no-export does not apply. Nothing real is deleted.
#   bash scripts/lab.sh backup [--check]  wait for readiness, create/check CNPG and K8up backups, check WAL.
#   bash scripts/lab.sh gitea-import DUMPFILE|recipients|accept|recover  restore a `gitea dump` of the production
#                                   forge into the lab Gitea (repos and users only; idempotent: same dump = SKIP,
#                                   foreign content = ABORT unless --replace). Own options (--replace, --yes,
#                                   --dry-run, --reimport, --no-backup, ...): see scripts/gitea-import.sh and
#                                   docs/how-to/gitea-import.md. Not a lab.sh option set: they go straight through.
#   bash scripts/lab.sh matrix-import DUMPFILE|recipients|prepare DUMPFILE|accept|backup|recover  optional: import
#                                   the Synapse of the production homeserver (server_name, signing key, accounts,
#                                   rooms, history, media, E2EE keys) into the lab Matrix. Federation stays off.
#                                   Idempotent: same dump = SKIP, foreign content = ABORT unless --replace. The old
#                                   server is only read (scripts/matrix-import-vps-dump.sh over SSH). Own options
#                                   (--dry-run, --replace, --max-age, ...): see scripts/matrix-import.sh and
#                                   docs/how-to/matrix-import.md. They go straight through.
#   bash scripts/lab.sh kit export DIR | verify DIR | import DIR  emergency kit (ADR 0025): every key and password that lives
#                                   only on this PC, in ONE age-encrypted archive on a USB stick (DIR = the mount point), plus a
#                                   plaintext manifest (paths, sizes, sha256, no content) and README-NOTFALL.txt.
#                                   export: --must-only, --allow-missing; verify: decrypts to a tmpfs only and compares;
#                                   import: --force, --dry-run, --repo CLONE. Own options, they go straight through to
#                                   scripts/emergency-kit.sh (docs/how-to/notfall-neuaufbau.md, docs/reference/emergency-kit.md).
#   bash scripts/lab.sh budget      memory budget: compare the peaks measured by the last acceptance run with the
#                                   limits in git (scripts/memory-budget.py report); --apply writes the
#                                   proposed lower limits into git files (never raises one); then commit,
#                                   push and run: cd ansible && ansible-playbook argocd.yml
#
# Options: --yes (down/rebuild without [y/N]; purge, restore-drill and rebuild --restore ALWAYS ask twice),
#   --restore (rebuild only: keep the Postgres bucket, apply recovery in the cluster, do not change Git),
#   --no-export (down/rebuild/purge without a fresh export), --live (export without
#   shutting down), --destroy-ok (up may replace existing parts),
#   --include-image (purge: also delete the image cache and the libvirt base volume),
#   --new-age-key (init: enter an own key in .sops.yaml),
#   --dry-run (init, customize, ca-rotation, repo-egress, secrets-repo: only show what would happen, write nothing),
#   --break-glass (init: also create an OFFLINE age recipient; the private key goes only to a
#   0600 file under ~/.config/k8s-lab/ and is never printed; .sops.yaml gets it as last recipient,
#   all secrets/**/*.sops.yaml are re-encrypted; no question: the flag is the confirmation),
#   --break-glass-delete (init: delete that key file after it is in the password manager;
#   always asks for a typed confirmation, --yes does not skip it),
#   --fetch-host-keys (customize: fetch the host keys of the Git server and enter them as repo_known_hosts
#   in lab.local.yaml, with confirmation; with source: github the keys of github.com, compared with the
#   fingerprints GitHub publishes, as github_known_hosts, no question),
#   --resolve, --dry-run (repo-egress only, see above),
#   --apply (budget only, see above),
#   --trust-override (up, rebuild, preflight, trust release: accept a commit that fails the source trust check after you type its
#   short id; --yes does not skip it. Without a recorded trusted commit use trust init instead).
# Logs: <log_dir>/lab-<command>-<timestamp>.log (mode 0600).
# Docs: docs/how-to/rebuild.md, docs/how-to/restore-drill.md, docs/how-to/backup-replica.md, docs/how-to/alerts.md,
# docs/how-to/gitea-import.md, docs/how-to/matrix-import.md, docs/how-to/notfall-neuaufbau.md,
# docs/reference/secrets-map.md. The script never shows the value of a secret.
# shellcheck disable=SC2154
set -euo pipefail

LAB_CALLER_PWD=$PWD
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
cd "$REPO"
# shellcheck source=scripts/gitea-sso.sh
source "$REPO/scripts/gitea-sso.sh"
POLL=${LAB_POLL:-10}
YES=0
NO_EXPORT=0
LIVE=0
DESTROY_OK=0
INCLUDE_IMAGE=0
NEW_AGE=0
BREAK_GLASS=0
BREAK_GLASS_DELETE=0
DRY_RUN=0
HOST_KEYS=0
RESOLVE=0
PRUNE=0
APPLY=0
TRUST_OVERRIDE=0
TRUST_CHECKED=""
GIT_SERVER_DOWN=0 # set by pf_git: source github and the Git server (origin) could not be fetched (ADR 0024)
ORIGIN_IS_MIRROR=0 # set by pf_git: origin of this clone IS the GitHub mirror (a fresh clone from GitHub after a total loss)
TRUST_OVERRIDE_OK="" # commit the typed --trust-override already covered in this run
# Commit that Argo CD is pinned to while up/rebuild run (issue 71): set by pf_trust, released after the re-check.
PIN_REV=""
TRUST_RECHECKED=0

SAMPLER_PID=""
SAMPLER_STOP=""
# (flags and subcommands are parsed in main)
POS=()
SECRETS_JSON=""
SUDO_PW=""
LOG=""
VM_RESTART=0
ZN=()
ZS=()
ZR=()
ZT0=$SECONDS
PHASE_NAME=""
PHASE_T0=0
CHANGED_TOTAL=0
CHANGED_TEXT=""
# rebuild --restore sets this so build_phases restores files. up and plain rebuild leave it at 0.
RECOVER_FILES=0
# rebuild --restore: do not empty the Postgres bucket, do not edit Git.
RESTORE=0
# wait_for_argo hides applications whose name matches this extended regex (empty = all).
ARGO_SKIP=""
# rebuild --restore: 1 from the start of the pause until the resume has run. If the script ends while it is 1,
# cleanup says loudly that auto-sync of root/gitea/matrix may still be off.
ROOT_PAUSED=0
RECOVER_NEXT=pause,restore,resume,verify # tags still to run when rebuild --restore stops (cleanup prints them)
# Alert marker file this run wrote (issue #21), removed by cleanup. Empty = none.
MAINT_FILE=""
# Test marker: no terminal requirement (answers then come via stdin).
REQUIRE_TTY=${LAB_REQUIRE_TTY:-1}
KVM=${LAB_KVM:-/dev/kvm}
# Ansible pattern for the control machine (inventory group backup_host in ansible/inventory/local.yml). The only
# place in this script: change the group or host there, or set LAB_INVENTORY_HOST for another inventory.
INVENTORY_HOST=${LAB_INVENTORY_HOST:-backup_host}
# Additional required tools (space separated), checked by the preflight on top of the built-in list.
EXTRA_TOOLS=${LAB_TOOLS_EXTRA:-}

# ------------------------------------------------------------------ Helpers
die() { echo "ERROR: $*" >&2; exit 1; }
notice() { echo "Note: $*"; }
fmt_duration() { printf '%dm%02ds' $(($1 / 60)) $(($1 % 60)); }
now_text() { date '+%Y-%m-%d %H:%M:%S'; }

# Value from lab.yaml, lab.local.yaml wins (flat keys, one line per value).
cfg_roh() {
  local f w v="" found=1
  for f in "$REPO/infra/envs/local/lab.yaml" "$REPO/infra/envs/local/lab.local.yaml"; do
    [ -f "$f" ] || continue
    if w=$(awk -v k="$1" '
      index($0, k ":") == 1 {
        v = substr($0, length(k) + 2)
        gsub(/^[ \t]+/, "", v); sub(/[ \t]+#.*$/, "", v); gsub(/[ \t]+$/, "", v)
        if (v ~ /^".*"$/ || v ~ /^\047.*\047$/) v = substr(v, 2, length(v) - 2)
        r = v; ok = 1
      }
      END { if (!ok) exit 1; print r }' "$f"); then
      v=$w; found=0
    fi
  done
  [ "$found" = 0 ] || return 1
  printf '%s\n' "$v"
}
cfg() {
  local v
  v=$(cfg_roh "$1") || return 1
  case $v in
    "~") v=$HOME ;;
    "~"/*) v=$HOME${v#"~"} ;;
    *) ;;
  esac
  printf '%s\n' "$v"
}

LAB_KEYS=(vm_name domain vcpu memory_mib disk_gb network_name vm_ip vm_cidr gateway libvirt_uri ssh_user ssh_key
  repo_url image_url image_sha256 image_file image_cache_dir export_dir log_dir wait_ssh wait_argo export_max_age_h
  matrix_server_name)
cfg_load() {
  local k v
  for k in "${LAB_KEYS[@]}"; do
    if v=$(cfg "$k") && [ -n "$v" ]; then
      printf -v "L_$k" '%s' "$v"
    else
      die "Key '$k' is missing or empty in infra/envs/local/lab.yaml (or lab.local.yaml)."
    fi
  done
  # Optional (ADR 0024): where Argo CD reads from. gitea = repo_url, github = github_repo_url (the private mirror).
  # The same override sits in ansible/inventory/group_vars/all/lab.yml and scripts/repo-egress.py.
  L_source=$(cfg source 2>/dev/null) || L_source=gitea
  case $L_source in
    gitea) ;;
    github)
      L_repo_url=$(cfg github_repo_url 2>/dev/null) || L_repo_url=
      case $L_repo_url in
        ssh://git@github.com/* | ssh://git@github.com:22/*) ;;
        *) die "source: github needs github_repo_url = ssh://git@github.com/OWNER/REPO.git (github.com, SSH port 22; is '${L_repo_url:-empty}')." ;;
      esac
      ;;
    *) die "source must be gitea or github (is '$L_source') in lab.yaml / lab.local.yaml." ;;
  esac
  # Optional (ADR 0022): repo of the SOPS apps, default the code repo.
  L_secrets_repo_url=$(cfg secrets_repo_url 2>/dev/null) || L_secrets_repo_url=
  [ -n "$L_secrets_repo_url" ] || L_secrets_repo_url=$L_repo_url
  # Optional (ADR 0023): source trust check of the commit Argo CD reads. auto | on | off.
  L_source_trust=$(cfg source_trust 2>/dev/null) || L_source_trust=auto
  case $L_source_trust in
    auto | on | off) ;;
    *) die "source_trust must be auto, on or off (is '$L_source_trust') in lab.yaml / lab.local.yaml." ;;
  esac
  if [ "$L_source" = github ]; then
    [ "$L_source_trust" != off ] || die "source_trust: off is refused with source: github (the mirror sits on a public forge, ADR 0024)."
    # A GitHub deploy key belongs to ONE repository, so a second (secrets) repo would need a second key and a second
    # trust path: not supported yet, the SOPS files come from the mirror itself (docs/how-to/neuaufbau-github.md).
    [ "$L_secrets_repo_url" = "$L_repo_url" ] || die "secrets_repo_url must be empty with source: github (the SOPS files come from the mirror; ADR 0024)."
  fi
  if [ -f "$REPO/infra/envs/local/lab.local.yaml" ]; then
    while read -r k; do
      grep -Eq "^$k:" "$REPO/infra/envs/local/lab.yaml" || die "Unknown key '$k' in lab.local.yaml (typo? Only the keys from lab.yaml are allowed)."
    done < <(sed -nE 's/^([a-z_0-9]+):.*/\1/p' "$REPO/infra/envs/local/lab.local.yaml")
  fi
  VM=$L_vm_name
  URI=$L_libvirt_uri
  TF=(tofu "-chdir=$REPO/infra/envs/local")
  VIRSH=(virsh -c "$URI")
  SSH_OPT=(-n -i "$L_ssh_key" -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5)
}

# Values only Ansible knows (key paths, buckets, ...): one call.
load_values() {
  [ -z "${W_loaded:-}" ] || return 0
  command -v ansible >/dev/null || die "ansible is missing."
  local out err code
  err=$(mktemp)
  out=$(cd "$REPO/ansible" && ANSIBLE_CALLBACK_RESULT_FORMAT=json timeout 120 ansible "$INVENTORY_HOST" -m ansible.builtin.debug -a 'msg={{ lab_values | to_json }}' 2>"$err") || {
    tail -n 15 "$err" >&2; rm -f "$err"
    die "Ansible values not readable (cd ansible && ansible $INVENTORY_HOST -m debug -a 'msg={{ lab_values }}')."
  }
  rm -f "$err"
  code=$(printf '%s' "$out" | python3 -c '
import json, re, shlex, sys
t = sys.stdin.read()
d = json.loads(json.loads(t.split("=>", 1)[1])["msg"])
for k, v in d.items():
    assert re.fullmatch(r"[a-z_0-9]+", k), k
    if isinstance(v, list):
        print("W_%s=(%s)" % (k, " ".join(shlex.quote(str(x)) for x in v)))
    else:
        print("W_%s=%s" % (k, shlex.quote(str(v))))
') || die "Ansible values cannot be evaluated."
  eval "$code"
  W_loaded=1
  export KUBECONFIG=$W_kubeconfig
}

# List of the secrets (only paths and descriptions, never values) from Ansible into a file.
load_secrets() {
  [ -z "$SECRETS_JSON" ] || return 0
  command -v ansible >/dev/null || { echo "ansible is missing." >&2; return 1; }
  command -v python3 >/dev/null || { echo "python3 is missing." >&2; return 1; }
  local out err
  err=$(mktemp)
  out=$(cd "$REPO/ansible" && ANSIBLE_CALLBACK_RESULT_FORMAT=json timeout 120 ansible "$INVENTORY_HOST" -m ansible.builtin.debug -a 'msg={{ secrets_all | to_json }}' 2>"$err") || {
    tail -n 15 "$err" >&2; rm -f "$err"
    return 1
  }
  rm -f "$err"
  SECRETS_JSON=$(mktemp)
  printf '%s' "$out" | python3 -c 'import json, sys; json.dump(json.loads(sys.stdin.read().split("=>", 1)[1])["msg"], sys.stdout)' > "$SECRETS_JSON" || { rm -f "$SECRETS_JSON"; SECRETS_JSON=""; return 1; }
}

# The secrets map. Must never make a run fail (display only).
print_map() {
  if load_secrets; then
    python3 "$REPO/scripts/lab-secrets.py" map --json "$SECRETS_JSON" || notice "Secrets map not readable."
  else
    notice "Secrets map not readable (bash scripts/lab.sh secrets shows the error)."
  fi
  return 0
}

log_start() {
  # Authenticate before tee and long phases; Ansible still needs the password, not a TTY timestamp.
  case $1 in up|rebuild|export|purge|acceptance|sync-host) ask_sudo ;; esac
  local dir
  dir=$(cfg log_dir) || dir="$HOME/k8s-lab-data/logs"
  mkdir -p "$dir"; chmod 0700 "$dir"
  LOG="$dir/lab-$1-$(date +%Y%m%d-%H%M%S).log"
  : > "$LOG"; chmod 0600 "$LOG"
  exec > >(tee -a "$LOG") 2>&1
  echo "Log: $LOG"
  echo "Start: $(now_text), command: $*"
}

# Stopwatch: phase "title" command args... (runs in this shell, the return value is kept)
phase() {
  local title=$1 t0=$SECONDS rc=0
  shift
  echo
  echo "=== [$(date +%H:%M:%S)] $title ==="
  PHASE_NAME=$title
  PHASE_T0=$t0
  # Errexit does not apply in the body: every body checks its own commands (|| return 1 or die).
  "$@" || rc=$?
  PHASE_NAME=""
  local d=$((SECONDS - t0))
  ZN+=("$title"); ZS+=("$d"); ZR+=("$rc")
  if [ "$rc" = 0 ]; then
    echo "=== $title: done in $(fmt_duration "$d") ==="
  else
    echo "=== $title: FAILED after $(fmt_duration "$d") (exit code $rc) ===" >&2
  fi
  return "$rc"
}

timing_table() {
  [ "${#ZN[@]}" -gt 0 ] || return 0
  local i total=$((SECONDS - ZT0)) res
  echo
  echo "Timings (stopwatch)"
  printf '  %-52s %8s  %s\n' Phase Duration Result
  for i in "${!ZN[@]}"; do
    res=OK
    [ "${ZR[$i]}" = 0 ] || res="ERROR (${ZR[$i]})"
    printf '  %-52s %8s  %s\n' "${ZN[$i]}" "$(fmt_duration "${ZS[$i]}")" "$res"
  done
  printf '  %-52s %8s\n' TOTAL "$(fmt_duration "$total")"
}

# Alerts stay silent while the VM is built or destroyed on purpose (issue #21). lab-alert.py honours the marker
# only while this process lives and for maintenance_max_hours, so a killed run cannot silence real alarms for long.
# Needs W_* (load_values). Without alerts or without the path (old values) it does nothing.
maintenance_begin() { # maintenance_begin COMMAND
  local f=${W_alert_maintenance_file:-}
  [ "${W_alert_enabled:-False}" = True ] && [ -n "$f" ] || return 0
  if mkdir -p "$(dirname "$f")" 2>/dev/null \
    && printf '{"pid": %s, "started": %s, "command": "%s"}\n' "$$" "$(date +%s)" "$1" > "$f.tmp.$$" 2>/dev/null \
    && mv -f "$f.tmp.$$" "$f" 2>/dev/null; then
    MAINT_FILE=$f
    echo "Alerts paused while lab.sh $1 runs (marker $f, removed at the end)."
  else
    rm -f "$f.tmp.$$" 2>/dev/null
    echo "NOTE: could not write the alert marker $f. Desktop alarms for the missing VM are possible." >&2
  fi
}

maintenance_end() {
  [ -z "$MAINT_FILE" ] || rm -f "$MAINT_FILE" "$MAINT_FILE.tmp.$$" 2>/dev/null
  MAINT_FILE=""
}

cleanup() {
  local rc=$?
  set +e
  maintenance_end
  if [ "$ROOT_PAUSED" = 1 ]; then
    {
      echo
      echo "ATTENTION: Argo CD auto-sync of root, gitea and matrix may still be OFF (rebuild --restore stopped before the resume)."
      echo "  Nothing turns it on again by itself. Check:  kubectl -n argocd get applications.argoproj.io -o custom-columns=NAME:.metadata.name,AUTO:.spec.syncPolicy.automated"
      echo "  Continue where it stopped (the tags run in this order, each part is safe to repeat):  cd ansible && ansible-playbook recover-files.yml --tags $RECOVER_NEXT"
      echo "  Or only turn sync back on:  cd ansible && ansible-playbook recover-files.yml --tags resume"
      echo "  (resume is idempotent and puts root back last; see docs/how-to/rebuild.md)"
    } >&2
  fi
  if [ "$VM_RESTART" = 1 ]; then
    echo "Starting VM $VM again (it was shut down for the export) ..."
    "${VIRSH[@]}" start "$VM" >/dev/null 2>&1
    VM_RESTART=0
  fi
  if [ -n "$PHASE_NAME" ]; then
    ZN+=("$PHASE_NAME (aborted)"); ZS+=("$((SECONDS - PHASE_T0))"); ZR+=("$rc")
  fi
  sampler_stop || true
  timing_table
  SUDO_PW=""
  [ -z "$SECRETS_JSON" ] || rm -f "$SECRETS_JSON"
  [ -z "$LOG" ] || echo "End: $(now_text), exit code $rc, log: $LOG"
  return "$rc"
}
trap cleanup EXIT

ask_yes() {
  [ "$YES" = 1 ] && return 0
  if [ "$REQUIRE_TTY" = 1 ] && [ ! -t 0 ]; then die "needs a terminal (or --yes)."; fi
  local a
  read -r -p "$1 [y/N] " a || a=""
  case "$a" in y|Y|yes|Yes|j|J|ja|Ja) return 0 ;; *) return 1 ;; esac
}

# Double confirmation: first type the word (default "purge"), then the name of the VM. --yes does not apply here.
ask_double() { # ask_double [WORD]
  local w=${1:-purge}
  if [ "$REQUIRE_TTY" = 1 ] && [ ! -t 0 ]; then die "$w needs a terminal (double confirmation)."; fi
  local a
  read -r -p "Confirmation 1 of 2: type the word '$w' to continue: " a || a=""
  [ "$a" = "$w" ] || { echo "Aborted (nothing changed)."; return 1; }
  read -r -p "Confirmation 2 of 2: type the name of the VM ($VM): " a || a=""
  [ "$a" = "$VM" ] || { echo "Aborted (nothing changed)."; return 1; }
}

ask_sudo() {
  # Never trace secret expansion, even when the caller enabled bash -x.
  set +x
  [ -z "$SUDO_PW" ] || return 0
  load_values
  command -v "$W_sudo_exe" >/dev/null || die "sudo program '$W_sudo_exe' not found (ansible_become_exe in ansible/inventory/local.yml)."
  if [ "$REQUIRE_TTY" = 1 ] && ! ( : </dev/tty ) 2>/dev/null; then
    die "needs a controlling terminal (prompt for the sudo password). Nothing changed."
  fi
  echo "Requesting the sudo password on the terminal (120 s timeout)."
  if [ "$REQUIRE_TTY" = 1 ]; then
    printf 'sudo password for this machine (%s), once, not shown: ' "$W_sudo_exe" >/dev/tty
    IFS= read -rs -t 120 SUDO_PW </dev/tty || die "sudo password prompt timed out or was cancelled. Nothing changed."
    printf '\n' >/dev/tty
  else
    IFS= read -rs -t 120 SUDO_PW || die "sudo password prompt timed out or was cancelled. Nothing changed."
  fi
  echo
  [ -n "$SUDO_PW" ] || die "Empty sudo password refused. Nothing changed."
  if ! printf '%s\n' "$SUDO_PW" | "$W_sudo_exe" -S -k -p '' -v 2>/dev/null; then
    SUDO_PW=""
    die "sudo password wrong (or $W_sudo_exe refuses it). Nothing changed."
  fi
  echo "OK: sudo password is correct."
}

# changed sum from the PLAY RECAP of an output file (without bc/jq)
count_changed() {
  sed -nE 's/^[^ ]+ +: ok=[0-9]+ +changed=([0-9]+) .*/\1/p' "$1" | awk '{ s += $1 } END { print s + 0 }'
}
book_ans() { # book_ans NAME OUTPUTFILE
  local n
  n=$(count_changed "$2")
  CHANGED_TOTAL=$((CHANGED_TOTAL + n))
  CHANGED_TEXT="$CHANGED_TEXT  $1: changed=$n"$'\n'
}
# ansible-playbook in the directory ansible/ (the return value is kept)
ans() {
  local tmp rc=0
  tmp=$(mktemp)
  (cd "$REPO/ansible" && ansible-playbook "$@") 2>&1 | tee "$tmp" || rc=1
  book_ans "$1" "$tmp"
  rm -f "$tmp"
  return "$rc"
}
# The same with the sudo password via stdin (never on the command line, never in the log)
ans_sudo() {
  # Defensive for callers outside the logged entry points; never send an empty password.
  ask_sudo
  local tmp rc=0
  tmp=$(mktemp)
  (cd "$REPO/ansible" && printf '%s\n' "$SUDO_PW" | ansible-playbook "$@" --become-password-file -) 2>&1 | tee "$tmp" || rc=1
  book_ans "$1" "$tmp"
  rm -f "$tmp"
  return "$rc"
}

# ------------------------------------------------------------------ VM state
vm_state() {
  local z
  if z=$("${VIRSH[@]}" domstate "$VM" 2>/dev/null); then
    printf '%s\n' "$z" | head -n 1
  else
    echo missing
  fi
}
tofu_count() {
  "${TF[@]}" state list 2>/dev/null | grep -c . || true
}
tofu_init() {
  "${TF[@]}" init -input=false -lockfile=readonly >/dev/null || {
    "${TF[@]}" init -input=false -lockfile=readonly
    return 1
  }
}

json_value() { # json_value 'json' 'python expression over d'
  printf '%s' "$1" | python3 -c 'import json, sys; d = json.load(sys.stdin); print(eval(sys.argv[1]))' "$2"
}

# ------------------------------------------------------------------ Preflight
PF_ERRORS=0
PF_WARN=0
pf_ok() { echo "  ok      $*"; }
pf_error() { echo "  ERROR  $*" >&2; PF_ERRORS=$((PF_ERRORS + 1)); }
pf_warn() { echo "  Warning $*"; PF_WARN=$((PF_WARN + 1)); }

# Tools the lab needs. sops and age: secrets (lab.sh init, KSOPS); podman: rustfs backup target (Quadlet);
# ufw: the host firewall role. ufw usually lives in /usr/sbin, which is not always in the PATH of a normal user.
PF_TOOLS=(tofu ansible-playbook ansible kubectl helm virsh qemu-img ssh ssh-keygen git python3 curl sha256sum awk sops age age-keygen podman ufw)
# Optional tools: only a hint, never an error.
PF_TOOLS_OPTIONAL=("argocd|Argo CD CLI, only needed for the argocd commands in docs/how-to/argocd-access.md#argocd-cli")

pf_have() { command -v "$1" >/dev/null || [ -x "/usr/sbin/$1" ]; }

pf_tools() {
  local t o
  for t in "${PF_TOOLS[@]}" $EXTRA_TOOLS; do
    if pf_have "$t"; then pf_ok "Tool $t"; else pf_error "Tool '$t' is missing. Run: bash scripts/lab.sh tools install (site-specific extras may need manual installation)."; fi
  done
  for o in "${PF_TOOLS_OPTIONAL[@]}"; do
    if pf_have "${o%%|*}"; then pf_ok "Optional tool ${o%%|*}"; else echo "  hint    optional tool '${o%%|*}' not found (${o#*|})."; fi
  done
}

pf_libvirt() {
  if [ -r "$KVM" ] && [ -w "$KVM" ]; then
    pf_ok "$KVM readable and writable"
  else
    pf_error "/dev/kvm is missing or no permissions (KVM active? Member of the group kvm?)."
  fi
  if "${VIRSH[@]}" version >/dev/null 2>&1; then
    pf_ok "libvirt reachable ($URI)"
  else
    pf_error "libvirt not reachable: virsh -c $URI version (libvirtd running? Member of the group libvirt?)."
    return 0
  fi
  local n
  n=$("${VIRSH[@]}" net-info "$L_network_name" 2>/dev/null || true)
  if printf '%s\n' "$n" | grep -Eq '^Active:[[:space:]]+yes'; then
    pf_ok "Network $L_network_name active"
  else
    pf_error "libvirt network '$L_network_name' not active (virsh -c $URI net-start $L_network_name)."
  fi
  if "${VIRSH[@]}" net-dumpxml "$L_network_name" 2>/dev/null | grep -Fq "address='$L_gateway'"; then
    pf_ok "Network $L_network_name has the gateway $L_gateway"
  else
    pf_error "Network '$L_network_name' does not have the address $L_gateway (lab.yaml: gateway/vm_cidr do not match the libvirt network)."
  fi
  local pool file_path free_gib
  pool=$("${VIRSH[@]}" pool-info default 2>/dev/null || true)
  if printf '%s\n' "$pool" | grep -Eq '^State:[[:space:]]+running'; then
    pf_ok "Storage pool default is running"
    file_path=$("${VIRSH[@]}" pool-dumpxml default 2>/dev/null | sed -nE 's#.*<path>(.*)</path>.*#\1#p' | head -n 1)
    if [ -n "$file_path" ] && [ -d "$file_path" ]; then
      free_gib=$(df -Pk "$file_path" | awk 'NR == 2 { print int($4 / 1048576) }')
      if [ "$free_gib" -ge $((L_disk_gb / 2 + 5)) ]; then pf_ok "Space in the pool ($file_path): ${free_gib} GiB free"; else pf_error "Space in the pool ($file_path): only ${free_gib} GiB free, need at least $((L_disk_gb / 2 + 5)) GiB."; fi
    fi
  else
    pf_error "Storage pool 'default' is not running (virsh -c $URI pool-start default)."
  fi
}

pf_memory() {
  # Prod parity (issue #9): the lab VM has the RAM of the planned server, so the lab is a faithful memory test.
  local prod
  [ -f "$REPO/infra/envs/prod/lab.yaml" ] || return 0  # no prod profile (e.g. a kit without it): nothing to compare
  prod=$(sed -nE 's/^memory_mib:[[:space:]]*([0-9]+).*/\1/p' "$REPO/infra/envs/prod/lab.yaml" 2>/dev/null | head -n 1)
  if [ -z "$prod" ]; then
    pf_warn "memory_mib of the prod profile not readable (infra/envs/prod/lab.yaml)."
  elif [ "$L_memory_mib" = "$prod" ]; then
    pf_ok "VM memory ${L_memory_mib} MiB = prod profile"
  else
    pf_warn "VM memory ${L_memory_mib} MiB differs from the prod profile (${prod} MiB): the lab is no faithful memory test. Remove memory_mib from lab.local.yaml (docs/reference/memory-budget.md)."
  fi
}

pf_space() {
  local d f
  for d in "$L_image_cache_dir" "$L_export_dir" "$L_log_dir"; do
    mkdir -p "$d" 2>/dev/null || { pf_error "Cannot create directory $d."; continue; }
  done
  f=$(df -Pk "$L_export_dir" | awk 'NR == 2 { print int($4 / 1048576) }')
  if [ "$f" -ge 20 ]; then pf_ok "Space for exports ($L_export_dir): ${f} GiB free"; else pf_error "Space for exports ($L_export_dir): only ${f} GiB free (at least 20 GiB)."; fi
}

pf_keys() {
  if [ -f "$L_ssh_key" ] && [ -f "$L_ssh_key.pub" ]; then
    pf_ok "SSH key $L_ssh_key (+ .pub)"
  else
    pf_error "SSH key is missing: $L_ssh_key and $L_ssh_key.pub (ssh_key in lab.yaml or lab.local.yaml)."
  fi
  if [ -f "$W_age_key" ]; then
    pf_ok "age key present (path $W_age_key, content is never read)"
    [ "$(stat -c %a "$W_age_key")" = 600 ] || pf_warn "age key does not have mode 0600."
  else
    pf_error "age key is missing: $W_age_key (without it neither SOPS files nor Argo CD can decrypt secrets; docs/learning-path/stage-7-ksops.md)."
  fi
  if [ -f "$W_deploy_key" ]; then pf_ok "Argo CD deploy key present ($W_deploy_key)"; else pf_error "Argo CD deploy key is missing: $W_deploy_key (docs/learning-path/stage-7-ksops.md, docs/tutorials/lab-for-friends.md)."; fi
  local f
  for f in "$W_rustfs_root_env" "${W_rustfs_env_files[@]}" "${W_secret_files[@]}"; do
    if [ -f "$f" ]; then pf_ok "Env/secret file present: $f"; else pf_error "File missing: $f (rustfs/Gitea/Matrix/Keycloak secrets, docs/learning-path/stage-8a-backup-target.md, docs/learning-path/stage-8c-gitea.md, docs/how-to/matrix.md, docs/how-to/keycloak.md)."; fi
  done
}

# origin_is_mirror: is the remote "origin" of this clone the GitHub mirror itself (github_repo_url)? That is a clone made
# from GitHub when the Git server and the PC are gone (docs/how-to/notfall-neuaufbau.md). The raw URL from .git/config is
# compared as host/owner/repo, so SSH or HTTPS spelling and url.insteadOf rewrites do not matter.
origin_is_mirror() {
  local o m
  norm_remote() {
    printf '%s' "$1" | sed -e 's#^[A-Za-z+]*://##' -e 's#^[^@/]*@##' -e 's#^\([^/:]*\):\([^0-9]\)#\1/\2#' -e 's#/*$##' -e 's#\.git$##' | tr '[:upper:]' '[:lower:]'
  }
  m=$(cfg github_repo_url 2>/dev/null) || return 1
  [ -n "$m" ] || return 1
  o=$(git config --get remote.origin.url 2>/dev/null) || return 1
  [ -n "$o" ] || return 1
  [ "$(norm_remote "$o")" = "$(norm_remote "$m")" ]
}

pf_git() {
  local kh gsc rc=0 branch local_head remote
  ORIGIN_IS_MIRROR=0
  if origin_is_mirror; then ORIGIN_IS_MIRROR=1; fi
  branch=$(git branch --show-current)
  if [ "$branch" = main ]; then pf_ok "Branch main"; else pf_error "Branch is '$branch', expected main (Argo CD reads main)."; fi
  if [ "$L_source" = github ]; then
    pf_ok "Source: GitHub mirror $L_repo_url (source: github, ADR 0024); origin below is the Git server that feeds it"
  fi
  if [ "$ORIGIN_IS_MIRROR" = 1 ] && [ "$L_source" != github ]; then
    pf_error "origin of this clone is the GitHub mirror (github_repo_url), but source is $L_source: Argo CD would read the Git server, not GitHub. After a total loss run bash scripts/lab.sh kit import DIR (it restores lab.local.yaml with source: github) or bash scripts/lab.sh source github (docs/how-to/notfall-neuaufbau.md)."
  fi
  # No prompt: a fresh clone over HTTPS without a login must fail fast, not ask for a password in the middle of the checks.
  if GIT_TERMINAL_PROMPT=0 git fetch --quiet origin main 2>/dev/null; then
    local_head=$(git rev-parse HEAD)
    remote=$(git rev-parse origin/main)
    if [ "$local_head" = "$remote" ]; then
      pf_ok "main == origin/main (${local_head:0:7}), Argo CD sees your state"
    else
      pf_error "main (${local_head:0:7}) and origin/main (${remote:0:7}) differ: push or pull first, Argo CD only reads origin."
    fi
    if [ "$ORIGIN_IS_MIRROR" = 1 ] && [ "$L_source" = github ]; then
      pf_warn "origin is the GitHub mirror itself (clone made from GitHub): there is no independent Git server to compare with. What protects you is the trusted commit (~/.config/k8s-lab/trusted-head, bash scripts/lab.sh trust status) and the SSH signatures, nothing else (docs/how-to/notfall-neuaufbau.md)."
    fi
  elif [ "$L_source" = github ] && [ "$ORIGIN_IS_MIRROR" = 1 ]; then
    # Rebuild from a GitHub clone without a GitHub login right now: the deploy key below still reads GitHub.
    GIT_SERVER_DOWN=1
    local_head=$(git rev-parse HEAD)
    pf_warn "origin is the GitHub mirror itself and cannot be fetched with your own login now (not signed in, or no network): the comparison uses the last fetched state, local main ${local_head:0:7}. There is no independent Git server; the trusted commit and the SSH signatures are the protection (gh auth login, then git pull --ff-only; docs/how-to/notfall-neuaufbau.md)."
    remote=$(git rev-parse --verify --quiet origin/main) || remote=
    if [ -z "$remote" ]; then
      pf_warn "no origin/main ref in this clone: only local main ${local_head:0:7} is the reference."
    elif [ "$local_head" = "$remote" ]; then
      pf_ok "main == origin/main as last fetched (${local_head:0:7}); GitHub was not asked with your login now"
    else
      pf_error "main (${local_head:0:7}) and origin/main as last fetched (${remote:0:7}) differ and origin cannot be fetched: run git pull --ff-only once you are signed in."
    fi
    if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
      pf_error "tracked files have uncommitted changes and origin cannot be fetched: local main is the only reference, so it must be clean (commit or git stash; untracked files are ignored)."
    fi
  elif [ "$L_source" = github ]; then
    # The main use of the mirror: rebuild while the Git server is down. The reference is then the last LOCALLY known state.
    GIT_SERVER_DOWN=1
    local_head=$(git rev-parse HEAD)
    pf_warn "Git server (origin) is unreachable: the comparison with GitHub uses the last locally known state, local main ${local_head:0:7}, not the live Git server. Keep this clone current (git pull --ff-only while the Git server is up); docs/how-to/neuaufbau-github.md."
    remote=$(git rev-parse --verify --quiet origin/main) || remote=
    if [ -z "$remote" ]; then
      pf_warn "no origin/main ref in this clone (never fetched from the Git server): only local main ${local_head:0:7} is the reference."
    elif [ "$local_head" = "$remote" ]; then
      pf_ok "main == origin/main as last fetched (${local_head:0:7}); the Git server was not asked now"
    else
      pf_error "main (${local_head:0:7}) and origin/main as last fetched (${remote:0:7}) differ and the Git server is unreachable: this clone is not in a known state. Run git pull --ff-only (or push) once the Git server is up."
    fi
    if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
      pf_error "tracked files have uncommitted changes and the Git server is unreachable: local main is the only reference, so it must be clean (commit or git stash; untracked files are ignored)."
    fi
  else
    pf_error "git fetch origin fails (network, access to the Git server?)."
  fi
  if [ -n "$(git status --porcelain -- gitops ansible infra)" ]; then pf_warn "uncommitted changes under gitops/, ansible/ or infra/ (Argo CD does not see them)."; fi
  case $L_repo_url in
    *example.org* | *YOUR-NAME*)
      pf_error "repo_url is still the placeholder ($L_repo_url): set your own repo address in lab.local.yaml, then run bash scripts/lab.sh customize (docs/tutorials/lab-for-friends.md)."
      return 0
      ;;
    *) ;;
  esac
  kh=$(mktemp)
  printf '%s\n' "${W_known_hosts[@]}" > "$kh"
  if [ -f "$W_deploy_key" ]; then
    gsc="ssh -i $W_deploy_key -o IdentitiesOnly=yes -o UserKnownHostsFile=$kh -o StrictHostKeyChecking=yes -o BatchMode=yes -o ConnectTimeout=10"
    GIT_SSH_COMMAND=$gsc git ls-remote "$W_repo_url" HEAD >/dev/null 2>&1 || rc=$?
    if [ "$rc" = 0 ]; then
      pf_ok "Deploy key reads $W_repo_url (host key matches argocd_repo_known_hosts)"
    else
      if [ "$L_source" = github ]; then
        pf_error "Deploy key cannot reach the GitHub repo: $W_repo_url (public key $W_deploy_key.pub added read-only under Settings > Deploy keys of that repo? Network? docs/how-to/neuaufbau-github.md)."
      else
        pf_error "Deploy key cannot reach the repo: $W_repo_url (key registered in Gitea as a deploy key? Host key in group_vars/all/argocd.yml current? Network/VPN?)."
      fi
    fi
  fi
  # Separate private secrets repo (ADR 0022): own deploy key, same host keys.
  local srepo=${W_secrets_repo_url:-$W_repo_url}
  if [ "$srepo" != "$W_repo_url" ]; then
    case $srepo in
      *example.org* | *YOUR-NAME*)
        pf_error "secrets_repo_url is still the placeholder ($srepo): set it in lab.local.yaml (docs/how-to/private-secrets-repo.md)."
        ;;
      *)
        if [ ! -f "${W_secrets_deploy_key:-}" ]; then
          pf_error "Deploy key of the secrets repo is missing: ${W_secrets_deploy_key:-?} (bash scripts/lab.sh init creates it; docs/how-to/private-secrets-repo.md)."
        else
          rc=0
          gsc="ssh -i $W_secrets_deploy_key -o IdentitiesOnly=yes -o UserKnownHostsFile=$kh -o StrictHostKeyChecking=yes -o BatchMode=yes -o ConnectTimeout=10"
          GIT_SSH_COMMAND=$gsc git ls-remote "$srepo" HEAD >/dev/null 2>&1 || rc=$?
          if [ "$rc" = 0 ]; then
            pf_ok "Secrets deploy key reads $srepo"
          else
            pf_error "Secrets deploy key cannot reach the secrets repo: $srepo (registered read-only as a deploy key there? Network?)."
          fi
        fi
        ;;
    esac
  fi
  rm -f "$kh"
}

# Arguments for lab-customize.py from lab.yaml. Only Ansible knows the ingress networks (edge_ingress_cidrs)
# (placeholders vm_cidr/gateway/vm_ip resolved): load_values must have run before.
customize_args() {
  local list_csv
  list_csv=$(IFS=,; printf '%s' "${W_edge_ingress_cidrs[*]}")
  CUSTOM_ARGS=(--repo "$REPO" --domain "$L_domain" --repo-url "$L_repo_url" --secrets-repo-url "$L_secrets_repo_url" --gateway "$L_gateway" --vm-cidr "$L_vm_cidr" --vm-ip "$L_vm_ip" --edge-ingress-cidrs "$list_csv" --server-name "$L_matrix_server_name")
}

pf_stand() {
  local out rc=0
  customize_args
  out=$(python3 "$REPO/scripts/lab-customize.py" "${CUSTOM_ARGS[@]}" --check 2>&1) || rc=$?
  if [ "$rc" = 0 ]; then
    pf_ok "gitops/ matches lab.yaml (domain, repo address, gateway, network, ingress networks; gitops/values-state.yaml)"
  else
    pf_error "gitops/ does not match lab.yaml: bash scripts/lab.sh customize, then commit and push. $(printf '%s' "$out" | head -n 3 | tr '\n' ' ')"
  fi
}

pf_networks() {
  local f
  pf_stand
  for f in "${W_gitops_gateway_files[@]}"; do
    if grep -Fq "http://$L_gateway:" "$REPO/$f"; then pf_ok "gitops: $f names gateway $L_gateway"; else pf_error "gitops: $f does not name the gateway $L_gateway (bash scripts/lab.sh customize)."; fi
  done
  local c
  for f in "${W_gitops_cidr_files[@]}"; do
    for c in "${W_edge_ingress_cidrs[@]}"; do
      if grep -Fq -- "- $c" "$REPO/$f"; then pf_ok "gitops: $f names ingress network $c"; else pf_error "gitops: $f does not name the ingress network $c (bash scripts/lab.sh customize)."; fi
    done
  done
  if grep -rqF ".$L_domain" "$REPO/gitops"; then pf_ok "gitops: domain $L_domain is present"; else pf_warn "gitops/ does not contain the domain $L_domain (bash scripts/lab.sh customize)."; fi
}

pf_repo_egress() {
  local out rc=0
  out=$(python3 "$REPO/scripts/repo-egress.py" --repo "$REPO" --check 2>&1) || rc=$?
  if [ "$rc" = 0 ]; then
    pf_ok "gitops/: the git server address and port in the egress policies match lab.yaml (repo_egress_cidrs, repo_url)"
  else
    pf_error "egress policies do not match lab.yaml: bash scripts/lab.sh repo-egress --resolve (first time) or bash scripts/lab.sh repo-egress, then commit and push. $(printf '%s' "$out" | head -n 3 | tr '\n' ' ')"
  fi
  if [ "$L_source" = github ]; then
    rc=0
    out=$(python3 "$REPO/scripts/repo-egress.py" --repo "$REPO" --check-live 2>&1) || rc=$?
    case $rc in
      0) pf_ok "github.com resolves into github_egress_cidrs now (the pods can reach it on port 22)" ;;
      1) pf_error "$(printf '%s' "$out" | head -n 1)" ;;
      *) pf_warn "could not check whether github.com still lies in github_egress_cidrs: $(printf '%s' "$out" | head -n 1)" ;;
    esac
  fi
}

pf_rustfs() {
  if [ -f "$REPO/ansible/roles/backup_s3/files/rustfs-s3.py" ] && python3 "$REPO/ansible/roles/backup_s3/files/rustfs-s3.py" health --endpoint "http://127.0.0.1:$W_rustfs_port" --wait 5 >/dev/null 2>&1; then
    pf_ok "rustfs answers on 127.0.0.1:$W_rustfs_port"
  else
    pf_warn "rustfs does not answer on 127.0.0.1:$W_rustfs_port (backup-host.yml in 'up' sets it up)."
  fi
}

preflight_min() {
  cfg_load
  load_values
  PF_ERRORS=0; PF_WARN=0
  pf_tools
  [ "$PF_ERRORS" = 0 ] || return 1
}

# ------------------------------------------------------------------ Source trust (ADR 0023)
# Argo CD verifies only GnuPG signatures, not the SSH signatures of this repo. So before the cluster reads repo_url,
# scripts/lab-trust.sh checks that the commit at repo_url is the last trusted commit (stored OUTSIDE Git) or a
# descendant whose commits are all SSH-signed by an allowed signer. docs/concepts/source-trust.md
TRUST_STATE=${LAB_TRUST_DIR:-$HOME/.config/k8s-lab}/trusted-head
TRUST_PUBLIC_HOSTS="github.com gitlab.com codeberg.org bitbucket.org"

trust_host() { # host of an ssh:// or scp-style repo address
  printf '%s' "$1" | sed -E 's#^[a-z+]+://##; s#^[^@/]*@##; s#[:/].*$##'
}

# auto: on as soon as a trusted commit is recorded or repo_url is a public forge; on: always; off: never.
trust_active() {
  [ "$L_source" != github ] || return 0 # a public forge: always checked (ADR 0024), source_trust off is refused
  case $L_source_trust in
    on) return 0 ;;
    off) return 1 ;;
    *) ;;
  esac
  [ ! -f "$TRUST_STATE" ] || return 0
  case " $TRUST_PUBLIC_HOSTS " in
    *" $(trust_host "$W_repo_url") "*) return 0 ;;
    *) return 1 ;;
  esac
}

# Fetches main of repo_url with the Argo CD deploy key and the pinned host keys (the same way Argo CD reads it) and
# prints the commit id. Only the object is fetched: no branch, no config changes.
trust_fetch_head() {
  local kh gsc rc=0
  [ -f "$W_deploy_key" ] || return 1
  kh=$(mktemp)
  printf '%s\n' "${W_known_hosts[@]}" > "$kh"
  gsc="ssh -i $W_deploy_key -o IdentitiesOnly=yes -o UserKnownHostsFile=$kh -o StrictHostKeyChecking=yes -o BatchMode=yes -o ConnectTimeout=10"
  GIT_SSH_COMMAND=$gsc git fetch --quiet "$W_repo_url" refs/heads/main >/dev/null 2>&1 || rc=$?
  rm -f "$kh"
  [ "$rc" = 0 ] || return 1
  git rev-parse --verify --quiet FETCH_HEAD
}

trust_confirm_override() { # trust_confirm_override COMMIT [unseen]: typed confirmation, --yes does not apply
  local a
  if [ "$REQUIRE_TTY" = 1 ] && [ ! -t 0 ]; then
    echo "--trust-override needs a terminal (typed confirmation)." >&2
    return 1
  fi
  if [ "${2:-}" = unseen ]; then
    echo "OVERRIDE: you are about to build the lab from a GitHub commit this PC never saw from the Git server (the Git server is unreachable)."
    echo "  Read it first: git log HEAD..${1:0:7}"
  else
    echo "OVERRIDE: you are about to build the lab from a commit that FAILED the source trust check."
  fi
  echo "  Whoever controls $W_repo_url can then run code in your lab."
  printf 'Type the first 7 characters of the commit (%s) to accept it anyway: ' "${1:0:7}"
  read -r a || a=""
  echo
  [ "$a" = "${1:0:7}" ] || { echo "Aborted (nothing changed)." >&2; return 1; }
}

pf_trust() {
  local out rc=0 head r rec
  export LAB_REQUIRE_TTY=$REQUIRE_TTY
  if ! trust_active; then
    pf_ok "Source trust check is off (source_trust: $L_source_trust; repo_url host '$(trust_host "$W_repo_url")' is not a public forge and no trusted commit is recorded; docs/concepts/source-trust.md)"
    if [ "$L_source_trust" = off ] && case " $TRUST_PUBLIC_HOSTS " in *" $(trust_host "$W_repo_url") "*) true ;; *) false ;; esac; then
      pf_warn "source_trust is off although repo_url is on a public forge: anyone who controls that account controls your lab."
    fi
    return 0
  fi
  case $W_repo_url in
    *example.org* | *YOUR-NAME*) return 0 ;; # placeholder: pf_git already reports it
    *) ;;
  esac
  [ -f "$W_deploy_key" ] || return 0 # pf_keys already reports it
  r=$(trust_fetch_head) || { pf_error "Source trust: cannot fetch main of $W_repo_url (network, deploy key, host key?)."; return 0; }
  TRUST_CHECKED=$r
  # github mode: the anchor only advances to a commit the Git server also has (a mirror ahead of or beside it is never recorded).
  rec=--record
  if [ "$L_source" = github ] && [ "$r" != "$(git rev-parse HEAD)" ]; then rec=; fi
  # shellcheck disable=SC2086 # $rec is empty or one flag
  out=$(bash "$REPO/scripts/lab-trust.sh" verify "$r" $rec 2>&1) || rc=$?
  case $rc in
    0)
      pf_ok "Source trust: ${r:0:7} at repo_url is trusted ($(printf '%s' "$out" | tail -n 1))"
      ;;
    3)
      pf_error "Source trust: $(printf '%s' "$out" | head -n 1) Run: bash scripts/lab.sh trust init COMMIT"
      ;;
    *)
      printf '%s\n' "$out" | sed 's/^/          /' >&2
      if [ "$TRUST_OVERRIDE" = 1 ] && trust_confirm_override "$r"; then
        TRUST_OVERRIDE_OK=$r
        if [ "$L_source" = github ] && [ "$r" != "$(git rev-parse HEAD)" ]; then
          # never record a commit the Git server (as last known here) does not have
          pf_warn "Source trust OVERRIDDEN for ${r:0:7} (typed confirmation); it is NOT recorded as the trusted commit (this PC has not seen it from the Git server)."
        else
          bash "$REPO/scripts/lab-trust.sh" record "$r" > /dev/null || { pf_error "Source trust: cannot record the override."; return 0; }
          pf_warn "Source trust OVERRIDDEN for ${r:0:7} (typed confirmation); it is now the trusted commit."
        fi
      else
        pf_error "Source trust FAILED for ${r:0:7} at $W_repo_url: it is not the trusted commit or a signed descendant. Nothing was changed. Check the commit on your private Git server; only if you are sure: --trust-override."
      fi
      ;;
  esac
  head=$(git rev-parse HEAD)
  if [ "$r" != "$head" ] && [ "$L_source" = github ]; then
    # head == origin/main here (pf_git): the last commit this checkout knows from the Git server
    # (with the Git server unreachable: local main, the last locally known state).
    if git merge-base --is-ancestor "$r" "$head" 2>/dev/null; then
      if [ "$GIT_SERVER_DOWN" = 1 ]; then
        pf_error "Source trust (github, Git server unreachable): the mirror is at ${r:0:7}, BEHIND the last locally known main ${head:0:7}: the push mirror has not synced yet (or local commits were never pushed). Wait for the sync once the Git server is up, then run again."
      else
        pf_error "Source trust (github): the mirror is at ${r:0:7}, BEHIND the Git server's ${head:0:7}: the push mirror has not synced yet. Wait for the sync (Gitea: repository settings, mirror, sync now), then run again."
      fi
    elif [ "$GIT_SERVER_DOWN" = 1 ]; then
      # GitHub is ahead of (or beside) what this PC knows. Only a typed override accepts it; the anchor is never moved to it.
      if [ "$TRUST_OVERRIDE" = 1 ] && { [ "$TRUST_OVERRIDE_OK" = "$r" ] || trust_confirm_override "$r" unseen; }; then
        pf_warn "Source trust (github, Git server unreachable): ${r:0:7} was never seen from the Git server and is accepted by the typed --trust-override. The trusted commit is NOT advanced."
        PIN_REV=$r
      else
        pf_error "Source trust (github, Git server unreachable): GitHub is at ${r:0:7}, which has commits this PC never saw from the Git server (last locally known main: ${head:0:7}; GitHub is ahead of it or diverged). Nothing was changed. Only after you inspected git log HEAD..${r:0:7}: --trust-override (typed confirmation).$([ "$ORIGIN_IS_MIRROR" != 1 ] || printf ' origin is the GitHub mirror itself: signed in (gh auth login), git pull --ff-only brings this clone to the same state and checks the signatures again.')"
      fi
    else
      pf_error "Source trust (github): the mirror is at ${r:0:7}, which is NOT the Git server's ${head:0:7} and not an ancestor of it: the mirror was changed behind the Git server's back (or the Git server was rolled back). Nothing was changed. Inspect git log ${head:0:7}..${r:0:7} and the GitHub account before going on."
    fi
  elif [ "$r" != "$head" ]; then
    pf_error "Source trust: Argo CD would read ${r:0:7} from repo_url, but your checkout is ${head:0:7}: wait for the mirror or push, or fetch the right checkout."
  else
    # The verified commit is also what the bootstrap reads (issue 71): no branch that moves can bring in more.
    PIN_REV=$r
    if [ "$GIT_SERVER_DOWN" = 1 ] && [ "$L_source" = github ]; then pf_ok "Source trust (github, Git server unreachable): the mirror equals the last locally known main ${head:0:7}"; fi
  fi
}

# End of up/rebuild: did repo_url move to an unverified commit while Argo CD was syncing? (detection, not prevention)
trust_recheck() {
  local r out rc=0
  export LAB_REQUIRE_TTY=$REQUIRE_TTY
  if [ -z "$TRUST_CHECKED" ]; then echo "SKIP: source trust was not checked in the preflight."; return 0; fi
  r=$(trust_fetch_head) || { echo "WARNING: repo_url could not be read again; cannot re-check the source trust."; return 0; }
  if [ "$r" = "$TRUST_CHECKED" ]; then
    echo "Source trust: repo_url is still at the verified commit ${r:0:7}."
    TRUST_RECHECKED=1
    return 0
  fi
  out=$(bash "$REPO/scripts/lab-trust.sh" verify "$r" --record 2>&1) || rc=$?
  printf '%s\n' "$out"
  if [ "$rc" = 0 ]; then
    echo "Source trust: repo_url moved from ${TRUST_CHECKED:0:7} to ${r:0:7} during the run; the new commit is signed and trusted."
    TRUST_RECHECKED=1
    return 0
  fi
  echo "ALERT: repo_url moved from the verified ${TRUST_CHECKED:0:7} to ${r:0:7} during the run, and ${r:0:7} FAILS the source trust check." >&2
  if [ -n "$PIN_REV" ]; then
    echo "ALERT: Argo CD is pinned to the verified ${PIN_REV:0:7} and did not read ${r:0:7}. The pin stays on. Inspect git log ${TRUST_CHECKED:0:7}..${r:0:7}; when you have checked it: bash scripts/lab.sh trust release" >&2
  else
    echo "ALERT: Argo CD may already have synced it. Pause auto-sync of root (kubectl -n argocd patch app root --type merge -p '{\"spec\":{\"syncPolicy\":{\"automated\":null}}}') and inspect git log ${TRUST_CHECKED:0:7}..${r:0:7}." >&2
  fi
  return 1
}

# End of up/rebuild, after a passed re-check: Argo CD follows the branch again (ansible/argocd-release-pin.yml).
trust_release() {
  if [ -z "$PIN_REV" ]; then echo "SKIP: Argo CD was not pinned (source trust off)."; return 0; fi
  if [ "$TRUST_RECHECKED" != 1 ]; then
    echo "WARNING: the source trust re-check could not run, so the pin to ${PIN_REV:0:7} stays on."
    echo "         Check the commits at repo_url, then: bash scripts/lab.sh trust release"
    return 0
  fi
  ans argocd-release-pin.yml || return 1
  echo "Argo CD follows the branch again (pin to ${PIN_REV:0:7} released)."
}

cmd_trust() {
  local usage_text="Usage: bash scripts/lab.sh trust status | init COMMIT | check | release" r rc=0
  [ "${#POS[@]}" -ge 1 ] || die "$usage_text"
  export LAB_REQUIRE_TTY=$REQUIRE_TTY
  case ${POS[0]} in
    status) [ "${#POS[@]}" = 1 ] || die "$usage_text"; bash "$REPO/scripts/lab-trust.sh" status ;;
    init)
      [ "${#POS[@]}" = 2 ] || die "$usage_text"
      bash "$REPO/scripts/lab-trust.sh" init "${POS[1]}"
      ;;
    check)
      [ "${#POS[@]}" = 1 ] || die "$usage_text"
      cfg_load
      load_values
      r=$(trust_fetch_head) || die "Cannot fetch main of $W_repo_url (network, deploy key, host key?)."
      echo "Commit at repo_url: $r"
      bash "$REPO/scripts/lab-trust.sh" verify "$r" --record || rc=$?
      [ "$rc" = 0 ] || exit "$rc"
      ;;
    release)
      # Takes the pin of a rebuild off (kept after a failed re-check). Needs a passed check first.
      [ "${#POS[@]}" = 1 ] || die "$usage_text"
      cfg_load
      load_values
      r=$(trust_fetch_head) || die "Cannot fetch main of $W_repo_url (network, deploy key, host key?)."
      echo "Commit at repo_url: $r"
      if ! bash "$REPO/scripts/lab-trust.sh" verify "$r" --record; then
        if [ "$TRUST_OVERRIDE" = 1 ] && trust_confirm_override "$r"; then
          bash "$REPO/scripts/lab-trust.sh" record "$r" > /dev/null || die "Cannot record the override."
        else
          die "Source trust FAILED for ${r:0:7}: the pin stays on. Check the commit on your private Git server; only if you are sure: --trust-override."
        fi
      fi
      ans argocd-release-pin.yml || die "argocd-release-pin.yml failed: the pin may still be on."
      echo "Argo CD follows the branch again."
      ;;
    *) die "$usage_text" ;;
  esac
}

preflight() {
  cfg_load
  load_values
  PF_ERRORS=0; PF_WARN=0
  echo "Preflight (all points, then abort on errors)"
  pf_tools
  pf_space
  pf_memory
  if command -v virsh >/dev/null; then pf_libvirt; fi
  pf_keys
  pf_git
  pf_trust
  pf_networks
  pf_repo_egress
  pf_rustfs
  if [ "$REQUIRE_TTY" = 1 ] && [ ! -t 0 ]; then pf_warn "no terminal: the sudo password cannot be asked for."; fi
  echo "Result: $PF_ERRORS errors, $PF_WARN warning(s)."
  [ "$PF_ERRORS" = 0 ] || return 1
}

# ------------------------------------------------------------------ Image
ensure_image() {
  local img="$L_image_cache_dir/$L_image_file" expected=$L_image_sha256 actual
  mkdir -p "$L_image_cache_dir" || return 1
  if [ -f "$img" ]; then
    actual=$(sha256sum "$img" | awk '{ print $1 }')
    if [ "$actual" = "$expected" ]; then echo "Image in cache, SHA-256 matches: $img"; return 0; fi
    echo "Image in cache has the wrong SHA-256 (is $actual), downloading again." >&2
    rm -f "$img"
  fi
  echo "Downloading $L_image_url ..."
  curl -fL --retry 3 --retry-delay 5 -o "$img.part" "$L_image_url" || { rm -f "$img.part"; die "Download failed: $L_image_url"; }
  actual=$(sha256sum "$img.part" | awk '{ print $1 }')
  if [ "$actual" != "$expected" ]; then
    rm -f "$img.part"
    die "SHA-256 of the image does not match (is $actual, expected $expected). Nothing used. Check the image pin in lab.yaml."
  fi
  mv "$img.part" "$img" || return 1
  chmod 0644 "$img" || return 1
  echo "Image downloaded and checked: $img"
}

# ------------------------------------------------------------------ Backups (S3)
rustfs_s3() { # rustfs_s3 SUBCOMMAND [args]
  local sub=$1
  shift
  python3 "$REPO/ansible/roles/backup_s3/files/rustfs-s3.py" "$sub" --endpoint "http://127.0.0.1:$W_rustfs_port" --wait 20 "$@"
}

bucket_content() { # prints "empty", "rustfs-off" or "occupied: <info>"
  local j info
  j=$(rustfs_s3 drop-bucket --root-env "$W_rustfs_root_env" --bucket "$1" --check) || { echo "Check of $1 failed: $j" >&2; return 1; }
  if json_value "$j" 'd["message"]' | grep -Fq 'not reachable'; then
    echo rustfs-off
    return 0
  fi
  info=$(json_value "$j" '(d["actions"] or ["-"])[0]')
  if [ "$(json_value "$j" 'd["changed"]')" = False ] || printf '%s' "$info" | grep -Fq ': 0 version(s)'; then
    echo empty
  else
    echo "occupied: $info"
  fi
}

empty_buckets() { # empty_buckets cnpg|all
  if ! rustfs_s3 health >/dev/null 2>&1; then
    notice "rustfs does not answer: nothing to empty (data in the rustfs data directory stays in case rustfs starts again later)."
    return 0
  fi
  ans lab-backups-empty.yml -e lab_empty_ok=yes -e "lab_empty_scope=$1"
}

# CNPG aborts with "Expected empty archive" if the bucket still holds WAL of an old cluster.
# BUCKET_MODE: none = do not check, check = abort on old WAL, empty = delete the old content.
BUCKET_MODE=none
BUCKET_AFTER=0
bucket_before() {
  local s
  s=$(bucket_content "$W_bucket_cnpg") || return 1
  case $s in
    empty) echo "Bucket $W_bucket_cnpg is empty: fresh Postgres clusters start cleanly." ;;
    rustfs-off)
      echo "rustfs is not running yet: the bucket is checked after backup-host.yml."
      BUCKET_AFTER=1
      ;;
    *)
      if [ "$BUCKET_MODE" = empty ]; then
        echo "Bucket $W_bucket_cnpg $s: is being emptied (old WAL of the old cluster)."
        empty_buckets cnpg || return 1
      else
        die "Bucket $W_bucket_cnpg $s. The VM is missing, but the bucket holds WAL of an old cluster ('Expected empty archive'). To rebuild from that backup: bash scripts/lab.sh rebuild --restore. A clean start that DELETES this backup: bash scripts/lab.sh rebuild."
      fi
      ;;
  esac
}
bucket_after() {
  local s
  s=$(bucket_content "$W_bucket_cnpg") || return 1
  case $s in
    empty) echo "Bucket $W_bucket_cnpg is empty." ;;
    rustfs-off) die "rustfs does not answer even after backup-host.yml (systemctl --user status rustfs)." ;;
    *)
      if [ "$BUCKET_MODE" = empty ]; then
        echo "Bucket $W_bucket_cnpg $s: is being emptied, backup-host.yml creates it again."
        empty_buckets cnpg || return 1
        ans_sudo backup-host.yml || return 1
      else
        die "Bucket $W_bucket_cnpg $s: old WAL ('Expected empty archive'). To rebuild from that backup: bash scripts/lab.sh rebuild --restore. A clean start that DELETES this backup: bash scripts/lab.sh rebuild."
      fi
      ;;
  esac
}

# ------------------------------------------------------------------ Export (parachute)
latest_export() { # path of the newest export disk or empty
  local f best=""
  for f in "$L_export_dir/$VM"-before-drill-*.qcow2 "$L_export_dir/$VM"-vor-drill-*.qcow2; do # lang-allow: legacy file name of old exports
    [ -f "$f" ] || continue
    if [ -z "$best" ] || [ "$f" -nt "$best" ]; then best=$f; fi
  done
  printf '%s\n' "$best"
}

export_check() { # ok if a fresh export with a checksum is there
  local f age_s
  f=$(latest_export)
  if [ -z "$f" ] || [ ! -f "$f.sha256" ] || [ ! -f "${f%.qcow2}.xml" ]; then
    echo "No complete export (qcow2 + .sha256 + .xml) found in $L_export_dir." >&2
    return 1
  fi
  age_s=$(( $(date +%s) - $(stat -c %Y "$f") ))
  if [ "$age_s" -gt $((L_export_max_age_h * 3600)) ]; then
    echo "Latest export is $((age_s / 3600)) h old (allowed: $L_export_max_age_h h): $f" >&2
    return 1
  fi
  echo "Fresh export present: $f ($((age_s / 60)) min old)"
}

export_guard() {
  [ "$NO_EXPORT" = 0 ] || { notice "without a fresh export (--no-export), the VM data would be gone."; return 0; }
  if [ "$(vm_state)" = missing ]; then echo "VM is missing, no export needed."; return 0; fi
  export_check || die "Run 'bash scripts/lab.sh export' first (parachute), or use --no-export."
}

# A completed CNPG backup is restorable only after its endWal segment is in the archive.
# No skip flag: stopping the VM earlier is what left matrix-db unrestorable on 2026-11-01.
# A cluster with no completed backup fails the check. Zero clusters stays success.
wal_ready() {
  python3 "$REPO/scripts/lab-wal-ready.py"
}

# New base backups and file backups before rebuild --restore destroys a running VM.
# --force-all creates them. --check only reports age. No skip flag.
backup_fresh() {
  local flag
  case ${1:-} in
    --force-all | --post-restore) import_state_save || return 1 ;;
  esac
  case ${1:-} in
    --force-all) flag=(--force-all) ;;
    --post-restore) flag=(--force-all --prefix post-restore) ;;
    --check | "") flag=(--check) ;;
    --guard) flag=(--guard --marker "${W_restore_state_file:-}") ;;
    *) die "backup_fresh: unknown mode ${1}" ;;
  esac
  [ -n "${W_backup_max_age_h:-}" ] || die "backup_max_age_h is missing from lab_values (ansible/inventory/group_vars/all/lab.yml)."
  python3 "$REPO/scripts/lab-backup-fresh.py" \
    --max-age-h "$W_backup_max_age_h" \
    --attempts "${LAB_FRESH_ATTEMPTS:-90}" \
    --interval "${LAB_FRESH_INTERVAL:-10}" \
    "${flag[@]}"
}

# Marker of an unfinished rebuild --restore (ansible/inventory/group_vars/all/restore.yml).
# Written before the VM is destroyed, removed by recover-files.yml --tags verify once the
# files are back and checked. While it exists, a running VM may be half restored:
# rebuild --restore then refuses to take "fresh backups" of it (a backup of empty
# volumes would become the newest one). Never a secret.
restore_marker_set() {
  local f=${W_restore_state_file:-}
  [ -n "$f" ] || die "restore_state_file is missing from lab_values (ansible/inventory/group_vars/all/restore.yml)."
  mkdir -p "$(dirname "$f")" && chmod 0700 "$(dirname "$f")" \
    && printf '{"started": "%s", "log": "%s", "command": "rebuild --restore"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${LOG:-}" > "$f.tmp.$$" \
    && mv -f "$f.tmp.$$" "$f" || die "Cannot write the restore marker $f. Nothing was destroyed."
  echo "Restore marker set: $f (removed by recover-files.yml --tags verify)."
}

restore_marker_clear() {
  local f=${W_restore_state_file:-}
  [ -n "$f" ] && [ -e "$f" ] || return 0
  rm -f "$f" && echo "Restore marker removed: $f"
}

# Refuses (exit 1) when the running VM looks half restored. Runs before anything is asked or destroyed.
restore_guard() {
  [ -n "${W_restore_state_file:-}" ] || die "restore_state_file is missing from lab_values (ansible/inventory/group_vars/all/restore.yml)."
  backup_fresh --guard
}

# After rebuild --restore the cluster is new: its Backup objects are gone, so
# CNPG shows "no completed backup" (lab-alert, wal-ready, verify-*) until the
# next ScheduledBackup. One on-demand backup per database and volume closes
# that gap. A failure here does not undo the restore, so it is a loud warning
# with the command to run again, not an abort.
post_restore_backups() {
  local rc=0
  backup_fresh --post-restore || rc=$?
  if [ "$rc" != 0 ]; then
    echo "WARNING: the lab is restored, but the first backups after the restore failed (exit code $rc)." >&2
    echo "  Until a base backup exists, alerts and wal_ready report 'no completed backup'." >&2
    echo "  Once the databases are healthy, run it again (kubectl pointed at the lab cluster):" >&2
    echo "    python3 scripts/lab-backup-fresh.py --force-all --prefix post-restore --max-age-h $W_backup_max_age_h" >&2
  fi
  return 0
}

qemu_img_convert() { # qemu_img_convert SOURCE TARGET [-U]
  local source=$1 target=$2 u=${3:-}
  if [ -r "$source" ]; then
    if [ -n "$u" ]; then qemu-img convert -U -O qcow2 "$source" "$target" || return 1; else qemu-img convert -O qcow2 "$source" "$target" || return 1; fi
  else
    echo "Disk $source is not readable for your user: using sudo for qemu-img."
    ask_sudo
    printf '%s\n' "$SUDO_PW" | "$W_sudo_exe" -S -p '' qemu-img convert ${u:+-U} -O qcow2 "$source" "$target" || return 1
    printf '%s\n' "$SUDO_PW" | "$W_sudo_exe" -S -p '' chown "$(id -u):$(id -g)" "$target" || return 1
  fi
}

cmd_export() {
  log_start export
  cfg_load
  load_values
  maintenance_begin export
  command -v qemu-img >/dev/null || die "qemu-img is missing."
  local z disk stamp target free_gib needed
  z=$(vm_state)
  [ "$z" != missing ] || die "VM $VM does not exist, nothing to export."
  disk=$("${VIRSH[@]}" domblklist "$VM" --details | awk '$1 == "file" && $2 == "disk" { print $4; exit }')
  [ -n "$disk" ] || die "Could not determine the system disk of the VM (virsh domblklist $VM --details)."
  mkdir -p "$L_export_dir"; chmod 0700 "$L_export_dir"
  free_gib=$(df -Pk "$L_export_dir" | awk 'NR == 2 { print int($4 / 1048576) }')
  needed=$("${VIRSH[@]}" vol-info --pool default "$(basename "$disk")" --bytes 2>/dev/null | awk '/^Allocation:/ { print int($2 / 1073741824) + 2 }' || true)
  needed=${needed:-$((L_disk_gb / 2))}
  [ "$free_gib" -ge "$needed" ] || die "Not enough space in $L_export_dir: ${free_gib} GiB free, about ${needed} GiB needed."
  stamp=$(date +%Y%m%d-%H%M%S)
  target="$L_export_dir/$VM-before-drill-$stamp.qcow2"
  echo "Source: $disk"
  echo "Target: $target (+ .xml, .sha256), free space ${free_gib} GiB, needed about ${needed} GiB"
  if [ "$z" = running ]; then
    phase "WAL archive covers the latest backup" wal_ready
  fi
  if [ "$z" = running ] && [ "$LIVE" = 0 ]; then
    echo "Shutting the VM down cleanly (consistent). It starts again afterwards."
    "${VIRSH[@]}" shutdown "$VM" >/dev/null
    VM_RESTART=1
    local deadline=$((SECONDS + 240))
    while [ "$(vm_state)" != "shut off" ]; do
      [ "$SECONDS" -lt "$deadline" ] || die "VM did not shut down within 240 s. Nothing exported, the VM keeps running."
      sleep 3
    done
  elif [ "$z" = running ]; then
    notice "--live: the disk is read while running (crash-consistent, not clean)."
  fi
  phase "Export: qemu-img convert (flattens the backing chain)" qemu_img_convert "$disk" "$target.part" "$([ "$LIVE" = 1 ] && echo -U || true)"
  mv "$target.part" "$target"
  "${VIRSH[@]}" dumpxml "$VM" > "${target%.qcow2}.xml"
  (cd "$L_export_dir" && sha256sum "$(basename "$target")" > "$(basename "$target").sha256")
  chmod 0600 "$target" "${target%.qcow2}.xml" "$target.sha256"
  qemu-img check "$target" >/dev/null 2>&1 || die "qemu-img check reports errors in the export $target."
  echo "Export done: $target ($(du -h "$target" | awk '{ print $1 }'))"
  echo "Restore: docs/how-to/export-and-restore-vm.md."
  if [ "$VM_RESTART" = 1 ]; then
    "${VIRSH[@]}" start "$VM" >/dev/null
    VM_RESTART=0
    echo "VM $VM started again."
    phase "Cluster ready after export" cluster_ready
  fi
}

# ------------------------------------------------------------------ tofu
tofu_plan_check() { # reads plan.json, aborts if existing parts would be destroyed
  python3 - "$1" "$DESTROY_OK" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
rc = d.get("resource_changes", [])
created = [r["address"] for r in rc if r["change"]["actions"] == ["create"]]
updated = [r["address"] for r in rc if r["change"]["actions"] == ["update"]]
destroyed = [r["address"] + " (" + "/".join(r["change"]["actions"]) + ")" for r in rc if "delete" in r["change"]["actions"]]
print("Plan: %d new, %d change, %d destroy" % (len(created), len(updated), len(destroyed)))
for a in destroyed:
    print("  destroyed: " + a)
if destroyed and sys.argv[2] != "1":
    print("ABORT: the plan would destroy or replace existing parts of the VM. 'up' never does that on its own.", file=sys.stderr)
    print("  Intended? Then first 'bash scripts/lab.sh export', afterwards 'rebuild' (clean) or 'up --destroy-ok'.", file=sys.stderr)
    sys.exit(3)
PY
}

tofu_up() {
  tofu_init || return 1
  local plan json
  plan=$(mktemp -u)
  json=$(mktemp)
  "${TF[@]}" plan -input=false -out="$plan" || { rm -f "$json"; return 1; }
  "${TF[@]}" show -json "$plan" > "$json" || { rm -f "$json"; return 1; }
  tofu_plan_check "$json" || { rm -f "$json" "$plan"; return 1; }
  rm -f "$json"
  "${TF[@]}" apply -input=false "$plan" || { rm -f "$plan"; return 1; }
  rm -f "$plan"
}

delete_snapshots() { # internal snapshots prevent tofu destroy: remove metadata (the disk dies with it)
  local s n=0
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    "${VIRSH[@]}" snapshot-delete "$VM" "$s" --metadata >/dev/null || return 1
    echo "Snapshot metadata removed: $s"
    n=$((n + 1))
  done < <("${VIRSH[@]}" snapshot-list "$VM" --name 2>/dev/null || true)
  echo "Snapshots: $n removed (snapshots die with the VM, the parachute is the export)."
}

tofu_down() {
  tofu_init || return 1
  "${TF[@]}" destroy -input=false -auto-approve || return 1
  if [ "$(vm_state)" != missing ]; then
    echo "The domain $VM still exists (not managed by tofu?). 'bash scripts/lab.sh purge' cleans up the leftovers." >&2
    return 1
  fi
}

local_traces() {
  local k
  for k in "$L_vm_ip" "$VM" "$VM.$L_domain"; do
    ssh-keygen -R "$k" >/dev/null 2>&1 || true
  done
  rm -f "$HOME"/.ansible/cp/* 2>/dev/null || true
  echo "known_hosts: entries for $L_vm_ip, $VM, $VM.$L_domain removed (new host key at the next up)."
  case $W_kubeconfig in
    "$HOME"/.kube/*.kubeconfig) rm -f "$W_kubeconfig"; echo "Kubeconfig removed: $W_kubeconfig" ;;
    *) notice "Kubeconfig $W_kubeconfig is not under ~/.kube, not touched." ;;
  esac
}

vm_teardown() {
  phase "Remove VM snapshots" delete_snapshots
  phase "Destroy VM (tofu destroy)" tofu_down
  phase "Traces on the PC (known_hosts, kubeconfig)" local_traces
}

# ------------------------------------------------------------------ VM reachable, Argo CD
wait_for_vm() {
  local deadline=$((SECONDS + L_wait_ssh)) st=""
  echo "Waiting for SSH $L_ssh_user@$L_vm_ip (up to $L_wait_ssh s) ..."
  until ssh "${SSH_OPT[@]}" "$L_ssh_user@$L_vm_ip" true 2>/dev/null; do
    [ "$SECONDS" -lt "$deadline" ] || { echo "SSH not reachable after $L_wait_ssh s. Console: virsh -c $URI console $VM" >&2; return 1; }
    sleep "$POLL"
  done
  echo "SSH answers. Waiting for cloud-init ..."
  st=$(ssh "${SSH_OPT[@]}" "$L_ssh_user@$L_vm_ip" 'cloud-init status --wait' 2>&1 || true)
  printf '%s\n' "$st"
  printf '%s\n' "$st" | grep -Eq 'status: (done|degraded)' || { echo "cloud-init not finished (log in the VM: /var/log/cloud-init-output.log)." >&2; return 1; }
}

argo_status() { # lines "name sync/health"; ARGO_SKIP hides names (recover pauses those apps)
  local s
  s=$(kubectl --request-timeout=10s -n argocd get applications.argoproj.io -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.sync.status}{"/"}{.status.health.status}{"\n"}{end}' 2>/dev/null || true)
  if [ -n "$ARGO_SKIP" ]; then
    printf '%s\n' "$s" | grep -Ev "$ARGO_SKIP" || true
  else
    printf '%s\n' "$s"
  fi
}

wait_for_argo() { # wait_for_argo SECONDS
  local deadline=$((SECONDS + $1)) s open_count n
  echo "Waiting until all Argo CD applications are Synced/Healthy (up to $1 s) ..."
  while :; do
    s=$(argo_status)
    local optional
    optional=$(printf '%s\n' "$s" | grep -E '^(docs|notes-[^ ]+) ' | grep -v ' Synced/Healthy$' || true)
    if [ -n "$optional" ]; then
      echo "WARNING: optional sites are not ready (not a recovery blocker):"
      printf '%s\n' "$optional"
    fi
    s=$(printf '%s\n' "$s" | grep -Ev '^(docs|notes-[^ ]+) ' || true)
    n=$(printf '%s\n' "$s" | grep -c . || true)
    open_count=$(printf '%s\n' "$s" | grep . | grep -vc ' Synced/Healthy$' || true)
    echo "  [$(date +%H:%M:%S)] Applications: $n, of which not yet Synced/Healthy: $open_count"
    if [ "$n" -gt 0 ] && [ "$open_count" = 0 ]; then break; fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      echo "Still open after $1 s:" >&2
      printf '%s\n' "$s" | grep -v ' Synced/Healthy$' >&2 || true
      return 1
    fi
    sleep "$POLL"
  done
  echo "All required applications Synced/Healthy (docs and notes-* are optional)."
}

wait_for_db() {
  local deadline=$((SECONDS + 600)) ph
  echo "Waiting for healthy Postgres clusters ..."
  while :; do
    ph=$(kubectl --request-timeout=10s get clusters.postgresql.cnpg.io -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}={.status.phase}{"\n"}{end}' 2>/dev/null || true)
    if [ -n "$ph" ] && ! printf '%s\n' "$ph" | grep -vq '=Cluster in healthy state$'; then
      printf '%s\n' "$ph"; return 0
    fi
    [ "$SECONDS" -lt "$deadline" ] || { echo "Cluster not healthy:" >&2; printf '%s\n' "$ph" >&2; return 1; }
    sleep "$POLL"
  done
}

# Bounded readiness after a VM restart; API failures are retried, not mistaken for an empty cluster.
cluster_ready() {
  local deadline=$((SECONDS + L_wait_argo))
  until kubectl --request-timeout=10s get nodes >/dev/null 2>&1; do
    [ "$SECONDS" -lt "$deadline" ] || { echo "API server not reachable after $L_wait_argo s." >&2; return 1; }
    sleep "$POLL"
  done
  kubectl --request-timeout="${L_wait_argo}s" wait --for=condition=Ready nodes --all --timeout="${L_wait_argo}s" || return 1
  wait_for_argo "$L_wait_argo" || return 1
  wait_for_db
}

# Keep the break-glass admin available: repair OIDC only after the core apps are ready.
gitea_sso_present() {
  sso_source_present_with kubectl -n gitea
}
ensure_gitea_sso() {
  kubectl -n gitea get secret gitea-oidc >/dev/null 2>&1 || return 0
  if gitea_sso_present; then echo "Gitea: keycloak login source is present; no restart needed."; return 0; fi
  echo "Gitea: repairing the missing keycloak login source with one restart."
  kubectl -n gitea rollout restart deploy/gitea || return 1
  kubectl -n gitea rollout status deploy/gitea --timeout=600s || return 1
  gitea_sso_present || { echo "Gitea: keycloak login source still missing; local admin remains available." >&2; return 1; }
  echo "Gitea: keycloak login source installed after one restart."
}

import_state_save() {
  local target
  for target in gitea matrix; do
    python3 "$REPO/scripts/import-state.py" save "$target" || return 1
  done
}
import_state_capture() {
  local target
  for target in gitea matrix; do
    python3 "$REPO/scripts/import-state.py" capture "$target" || return 1
  done
}
import_accept_restored() {
  local target rc
  for target in gitea matrix; do
    rc=0
    python3 "$REPO/scripts/import-state.py" restore "$target" || rc=$?
    case "$rc" in
      0) bash "$REPO/scripts/lab.sh" "${target}-import" accept || {
        echo "WARNING: $target import acceptance failed; restore is running but NOT accepted. Retry: bash scripts/lab.sh ${target}-import accept" >&2
      } ;;
      3) echo "SKIP: no saved $target import baseline; see docs/how-to/rebuild.md." ;;
      *) echo "WARNING: $target import evidence unavailable; restore is NOT accepted. Retry: bash scripts/lab.sh ${target}-import accept" >&2 ;;
    esac
  done
}

cmd_backup() {
  log_start backup
  cfg_load
  load_values
  phase "Cluster ready before backup" cluster_ready
  phase "Fresh backups (CNPG and K8up)" backup_fresh "$BACKUP_MODE"
  phase "WAL archive covers the latest backup" wal_ready
}

# ------------------------------------------------------------------ Commands
cmd_init() {
  log_start init
  cfg_load
  load_secrets || die "List of secrets not readable (cd ansible && ansible $INVENTORY_HOST -m ansible.builtin.debug -a 'msg={{ secrets_all }}')."
  local opt=() rc=0
  [ "$NEW_AGE" = 0 ] || opt+=(--new-age-key)
  [ "$BREAK_GLASS" = 0 ] || opt+=(--break-glass)
  [ "$BREAK_GLASS_DELETE" = 0 ] || opt+=(--break-glass-delete)
  [ "$DRY_RUN" = 0 ] || opt+=(--dry-run)
  [ "$YES" = 0 ] || opt+=(--yes)
  # Public clone without the private secrets repo (ADR 0022): seed secrets/ from the templates.
  # Never overwrites; with a secrets repo, use "lab.sh secrets-repo import DIR" first instead.
  if [ ! -e "$REPO/secrets" ] && [ -d "$REPO/secrets.example" ]; then
    if [ "$DRY_RUN" = 1 ]; then
      echo "init: secrets/ is missing, would seed it from secrets.example/ (dry-run, nothing written)"
    else
      cp -R "$REPO/secrets.example" "$REPO/secrets" || die "Could not seed secrets/ from secrets.example/."
      echo "init: secrets/ was missing, seeded from secrets.example/ (rebuild with a secrets repo: lab.sh secrets-repo import DIR)"
    fi
  fi
  python3 "$REPO/scripts/lab-secrets.py" init --json "$SECRETS_JSON" --repo "$REPO" ${opt[@]+"${opt[@]}"} || rc=$?
  echo
  print_map
  if [ "$rc" != 0 ]; then
    echo "init: see the ABORT messages above (exit code $rc)." >&2
    return "$rc"
  fi
  echo "init: done."
}

cmd_ca_rotation() {
  log_start ca-rotation
  cfg_load
  load_secrets || die "List of secrets not readable (cd ansible && ansible $INVENTORY_HOST -m ansible.builtin.debug -a 'msg={{ secrets_all }}')."
  local opt=() rc=0
  [ "$DRY_RUN" = 0 ] || opt+=(--dry-run)
  [ "$YES" = 0 ] || opt+=(--yes)
  python3 "$REPO/scripts/lab-secrets.py" ca-rotation --json "$SECRETS_JSON" --repo "$REPO" ${opt[@]+"${opt[@]}"} || rc=$?
  [ "$rc" = 0 ] || echo "ca-rotation: see the ABORT messages above (exit code $rc)." >&2
  return "$rc"
}

cmd_customize() {
  cfg_load
  if [ "$HOST_KEYS" = 1 ]; then
    local opt=()
    [ "$YES" = 0 ] || opt+=(--yes)
    [ "$L_source" = gitea ] || opt+=(--github)
    python3 "$REPO/scripts/lab-customize.py" --repo "$REPO" --fetch-host-keys --repo-url "$L_repo_url" --local-file "$REPO/infra/envs/local/lab.local.yaml" ${opt[@]+"${opt[@]}"}
    return $?
  fi
  local opt=()
  [ "$DRY_RUN" = 0 ] || opt+=(--dry-run)
  load_values
  customize_args
  python3 "$REPO/scripts/lab-customize.py" "${CUSTOM_ARGS[@]}" ${opt[@]+"${opt[@]}"}
}

cmd_repo_egress() {
  local opt=()
  if [ "$RESOLVE" = 1 ]; then
    python3 "$REPO/scripts/repo-egress.py" --repo "$REPO" --resolve || die "repo-egress --resolve did not write repo_egress_cidrs."
  fi
  [ "$DRY_RUN" = 0 ] || opt+=(--dry-run)
  python3 "$REPO/scripts/repo-egress.py" --repo "$REPO" ${opt[@]+"${opt[@]}"}
}

# Where Argo CD reads from (ADR 0024). The only state is the key source in lab.local.yaml; everything else follows
# from lab.yaml (github_*), via customize and repo-egress. No cluster, no commit: the diff is yours to review and sign.
cmd_source() {
  local usage_text="Usage: bash scripts/lab.sh source status | github | gitea"
  [ "${#POS[@]}" = 1 ] || die "$usage_text"
  local f=$REPO/infra/envs/local/lab.local.yaml
  cfg_load
  case ${POS[0]} in
    status)
      echo "source: $L_source"
      echo "Argo CD reads: $L_repo_url"
      if [ "$L_source" = github ]; then echo "Source trust: always on (anchor: $TRUST_STATE)"; fi
      load_values
      customize_args
      if python3 "$REPO/scripts/lab-customize.py" "${CUSTOM_ARGS[@]}" --check >/dev/null 2>&1 && python3 "$REPO/scripts/repo-egress.py" --repo "$REPO" --check >/dev/null 2>&1; then
        echo "gitops/: matches this source."
      else
        echo "gitops/: does NOT match this source yet (bash scripts/lab.sh customize; bash scripts/lab.sh repo-egress; then commit, sign and push)."
      fi
      return 0
      ;;
    github | gitea)
      local target=${POS[0]}
      load_values
      if [ "$target" = github ] && [ ! -f "$W_deploy_key.pub" ]; then
        die "The public deploy key $W_deploy_key.pub is missing (bash scripts/lab.sh init creates it). It must be added read-only to the GitHub repo first."
      fi
      if [ -f "$f" ] && grep -Eq '^source:' "$f"; then
        sed -i -E "s/^source:.*/source: $target/" "$f"
      else
        if [ -s "$f" ] && [ -n "$(tail -c1 "$f")" ]; then printf '\n' >> "$f"; fi
        (umask 077; printf 'source: %s\n' "$target" >> "$f")
      fi
      echo "EDIT: infra/envs/local/lab.local.yaml (source: $target)"
      bash "${BASH_SOURCE[0]}" customize || die "customize failed: lab.local.yaml now says source: $target; fix the cause and run: bash scripts/lab.sh customize"
      bash "${BASH_SOURCE[0]}" repo-egress || die "repo-egress failed: fix the cause and run: bash scripts/lab.sh repo-egress"
      echo
      echo "DONE: source is $target. gitops/ follows it. Argo CD reads only Git, so now:"
      echo "  git diff --stat   (review: repo URL, egress ranges and port, values-state.yaml)"
      echo "  commit on a branch, sign, push, merge into main (Gitea syncs the mirror), then: bash scripts/lab.sh rebuild --restore (keeps the data; plain rebuild starts empty)"
      if [ "$target" = github ]; then
        echo "  Deploy key on GitHub (read-only): $W_deploy_key.pub"
      fi
      echo "  Switching a RUNNING VM instead of rebuilding: the repo-server egress policy is deployed by Argo CD itself,"
      echo "  which cannot read the new source before that policy allows it. After the push, once:"
      echo "    kubectl apply -f gitops/workloads/argocd/networkpolicy.yaml"
      echo "    bash scripts/lab.sh sync-host   (AppProjects sourceRepos, repo secret, root app)"
      echo "  (docs/how-to/neuaufbau-github.md#laufende-vm-umstellen)"
      ;;
    *) die "$usage_text" ;;
  esac
}


# Private secrets repo (ADR 0022): ciphertext only, the script never decrypts. No cluster, no Ansible.
cmd_secrets_repo() {
  local usage_text="Usage: bash scripts/lab.sh secrets-repo export DIR [--dry-run] [--prune] | import DIR [--dry-run]"
  [ "${#POS[@]}" = 2 ] || die "$usage_text"
  local opt=()
  [ "$DRY_RUN" = 0 ] || opt+=(--dry-run)
  case ${POS[0]} in
    export)
      [ "$PRUNE" = 0 ] || opt+=(--prune)
      python3 "$REPO/scripts/lab-secrets-repo.py" export --repo "$REPO" --target "${POS[1]}" ${opt[@]+"${opt[@]}"}
      ;;
    import)
      [ "$PRUNE" = 0 ] || die "--prune only applies to secrets-repo export."
      python3 "$REPO/scripts/lab-secrets-repo.py" import --repo "$REPO" --source "${POS[1]}" ${opt[@]+"${opt[@]}"}
      ;;
    *) die "$usage_text" ;;
  esac
}

cmd_secrets() {
  load_secrets || die "List of secrets not readable (cd ansible && ansible $INVENTORY_HOST -m ansible.builtin.debug -a 'msg={{ secrets_all }}')."
  python3 "$REPO/scripts/lab-secrets.py" map --json "$SECRETS_JSON"
}

cmd_preflight() {
  log_start preflight
  phase "Preflight" preflight
}

build_phases() {
  phase "Base image (pinned, SHA-256)" ensure_image
  if [ "$BUCKET_MODE" != none ]; then phase "Postgres bucket (old WAL?)" bucket_before; fi
  phase "Build VM (tofu plan + apply)" tofu_up
  phase "VM reachable (SSH, cloud-init)" wait_for_vm
  phase "Set up the PC (backup-host.yml: rustfs, buckets, /etc/hosts)" ans_sudo backup-host.yml
  if [ "$BUCKET_AFTER" = 1 ]; then phase "Re-check the Postgres bucket" bucket_after; fi
  phase "Set up the VM (site.yml: hardening, k3s)" ans site.yml
  if [ "$RESTORE" = 1 ]; then
    phase "Argo CD (argocd.yml: bootstrap, SOPS, CA, docs)" ans argocd.yml -e lab_cnpg_restore=true ${PIN_REV:+-e "argocd_pin_revision=$PIN_REV"}
    phase "Apply CNPG recovery specs" ans restore-clusters.yml
  else
    phase "Argo CD (argocd.yml: bootstrap, SOPS, CA, docs)" ans argocd.yml ${PIN_REV:+-e "argocd_pin_revision=$PIN_REV"}
  fi
  if [ "$RECOVER_FILES" = 1 ]; then
    # root (app of apps) is paused too: its self-heal would otherwise revert the paused child apps.
    ROOT_PAUSED=1
    RECOVER_NEXT=pause,restore,resume,verify
    phase "Pause root, Gitea and Matrix" ans recover-files.yml --tags pause
    RECOVER_NEXT=restore,resume,verify
    ARGO_SKIP='^(root|gitea|matrix) '
  fi
  phase "Cluster ready (Node, Argo CD, databases)" cluster_ready
  if [ "${W_acme_active:-False}" = True ]; then
    phase "Public probe (public.yml: ClusterIssuer lab-acme, probe certificate)" ans public.yml
  else
    echo "SKIP: public probe off (acme_* in lab.local.yaml not set, docs/how-to/public-certificate.md)."
  fi
  if [ "$RECOVER_FILES" = 1 ]; then
    phase "Restore Gitea and Matrix files" ans recover-files.yml --tags restore
    RECOVER_NEXT=resume,verify
    phase "Resume Gitea, Matrix and root" ans recover-files.yml --tags resume
    ROOT_PAUSED=0
    ARGO_SKIP=
    phase "Argo CD syncs root, Gitea and Matrix" wait_for_argo "$L_wait_argo"
    phase "Gitea hooks and doctor" ans recover-files.yml --tags verify
    phase "First backups after the restore (CNPG and K8up)" post_restore_backups
  fi
  phase "Gitea Keycloak login source" ensure_gitea_sso
  if [ "$RECOVER_FILES" = 1 ]; then
    phase "Restored import acceptance" import_accept_restored
  fi
  phase "Source trust re-check (repo_url unchanged while Argo CD synced?)" trust_recheck
  phase "Release the pin (Argo CD follows the branch again)" trust_release
  echo
  echo "Ansible runs (target at the second 'up': changed=0):"
  printf '%s' "$CHANGED_TEXT"
  echo "  Total changed=$CHANGED_TOTAL"
  echo "DONE: lab is running. Next step: bash scripts/lab.sh acceptance"
}

up_flow() {
  phase "Preflight" preflight
  ask_sudo
  local z
  z=$(vm_state)
  echo "VM $VM: $z"
  if [ "$z" = missing ] && [ "$(tofu_count)" = 0 ]; then BUCKET_MODE=check; fi
  build_phases
}

cmd_up() {
  log_start up
  cfg_load
  load_values
  maintenance_begin up
  up_flow
}

down_flow() {
  phase "Export guard" export_guard
  echo
  echo "About to tear down: VM $VM ($L_vm_ip), its disk, all data in the cluster (Gitea, pg-lab, ...)."
  echo "Stays: backups in rustfs, age/SSH/deploy keys, rustfs itself, image cache, exports, /etc/hosts."
  ask_yes "Destroy VM $VM now?" || { echo "Aborted (nothing changed)."; exit 0; }
  if [ "$(vm_state)" = running ]; then
    phase "WAL archive covers the latest backup" wal_ready
  else
    notice "VM is not running, the WAL archive was not checked."
  fi
  vm_teardown
}

cmd_down() {
  log_start down
  cfg_load
  load_values
  maintenance_begin down
  if [ "$(vm_state)" = missing ] && [ "$(tofu_count)" = 0 ]; then
    echo "VM $VM does not exist and tofu has nothing in its state: nothing to do."
    local_traces
    return 0
  fi
  down_flow
  echo "DONE: VM torn down. Backups in rustfs stayed."
  echo "Empty Postgres bucket: bash scripts/lab.sh up"
  echo "Bucket still holds this cluster's WAL: bash scripts/lab.sh rebuild --restore"
  echo "Clean start that DELETES the Postgres backup: bash scripts/lab.sh rebuild"
}

# Render once before anything is destroyed. The playbook renders again on the new VM.
restore_plan() {
  local out rc=0
  out=$(mktemp -d)
  python3 "$REPO/scripts/lab-restore-render.py" --repo "$REPO" --data-dir "$W_backup_data_dir" --out "$out" || rc=$?
  rm -rf "$out"
  return "$rc"
}

# Idle databases leave the end WAL segment of their newest base backup open, so the planner finds no
# sealed generation (#111). Seal it first: lab-wal-ready.py writes a tiny WAL record, switches WAL and
# waits until the segment is archived. Best effort here: the planner below stays the strict check.
restore_seal_wal() {
  [ "$(vm_state)" = running ] || return 0
  echo "Seal the WAL of the newest base backups (#111: idle databases leave the end segment open)."
  if ! wal_ready; then
    notice "Could not seal the WAL of every cluster before planning. The planner decides (strict)."
  fi
  return 0
}

# After the pre-destroy backups the planner must see their end WAL in the archive (rustfs).
# Bounded retry: LAB_RESTORE_PLAN_ATTEMPTS (default 12) x LAB_RESTORE_PLAN_INTERVAL seconds (default 5).
restore_plan_wait() {
  local i attempts=${LAB_RESTORE_PLAN_ATTEMPTS:-12} interval=${LAB_RESTORE_PLAN_INTERVAL:-5}
  for ((i = 1; i <= attempts; i++)); do
    restore_plan && return 0
    [ "$i" -lt "$attempts" ] && sleep "$interval"
  done
  echo "FAIL the end WAL of the fresh base backups is not in the archive after $attempts attempts." >&2
  echo "  The VM was NOT destroyed. Check the archiver: bash scripts/lab.sh status, then run rebuild --restore again." >&2
  return 1
}

restore_git_clean() {
  local dirty
  dirty=$(git status --porcelain --untracked-files=all)
  [ -z "$dirty" ] || die "Worktree is not clean. Commit or stash, then run rebuild --restore again. Nothing was changed."
  [ "$(git branch --show-current)" = main ] || die "rebuild --restore runs only on branch main (Argo CD reads main)."
}

rebuild_restore() {
  local s
  echo "REBUILD --restore rebuilds the VM from the backups. The VM disk is destroyed. rustfs is not emptied."
  echo "  - Git stays on bootstrap.initdb. The recovery spec is applied only in the cluster."
  echo "  - A running VM gets a new base backup and a new K8up backup before the disk is destroyed."
  echo "  - Gitea and Matrix files come back from the newest K8up snapshot of that PVC."
  echo "  - A missing snapshot or an empty restored volume stops the restore. Empty snapshots are skipped."
  echo "  - A running VM that looks half restored (marker of an unfinished restore, missing databases or empty volumes) is refused: no backup of empty volumes."
  echo "  - At the end, new CNPG and K8up backups of the restored lab are taken (CNPG has no Backup objects after a restore)."
  echo "  - plain rebuild still empties the Postgres bucket. up still refuses a full bucket."
  [ -n "${W_backup_data_dir:-}" ] || die "backup_data_dir is missing from lab_values (ansible/inventory/group_vars/all/lab.yml)."
  [ -n "${W_backup_max_age_h:-}" ] || die "backup_max_age_h is missing from lab_values (ansible/inventory/group_vars/all/lab.yml)."
  restore_git_clean
  export_check || die "Run 'bash scripts/lab.sh export' first (parachute). rebuild --restore does not run without a fresh export."
  s=$(bucket_content "$W_bucket_cnpg") || die "Could not read bucket $W_bucket_cnpg."
  case $s in
    empty) die "Bucket $W_bucket_cnpg is empty. There is no archive to restore. Use: bash scripts/lab.sh up" ;;
    rustfs-off) die "rustfs does not answer, so the archive cannot be checked. Start rustfs and run rebuild --restore again." ;;
    *) echo "Bucket $W_bucket_cnpg $s" ;;
  esac
  restore_seal_wal
  restore_plan || die "No sealed archive to read. Nothing was changed."
  phase "Preflight" preflight
  # A running VM that looks half restored is never backed up (the backup would be empty volumes).
  # LAB_RESTORE_START_OVER=1: destroy it and restore again from the backups that exist, without new ones.
  local fresh=1
  if [ "$(vm_state)" = running ]; then
    if [ "${LAB_RESTORE_START_OVER:-}" = 1 ]; then
      notice "LAB_RESTORE_START_OVER=1: the running VM is NOT backed up. The newest backups that exist are restored."
      fresh=0
    else
      phase "Restore guard (is the running VM complete?)" restore_guard
    fi
  fi
  ask_double restore || exit 0
  ask_sudo
  if [ "$(vm_state)" = running ] && [ "$fresh" = 1 ]; then
    phase "Capture pre-destroy import counts" import_state_capture
    phase "Fresh backups before the VM is destroyed" backup_fresh --force-all
    phase "WAL archive covers the latest backup" wal_ready
    phase "Restore plan reads the fresh backups" restore_plan_wait
  elif [ "$(vm_state)" = running ]; then
    notice "No fresh backups and no WAL check (start over from the existing backups)."
  elif [ "$(vm_state)" = missing ] && [ "$(tofu_count)" = 0 ]; then
    notice "VM is already missing. Nothing to tear down."
  else
    notice "VM is not running. It will be removed without a WAL check."
  fi
  restore_marker_set
  if [ "$(vm_state)" != missing ] || [ "$(tofu_count)" != 0 ]; then
    vm_teardown
  fi
  RECOVER_FILES=1
  BUCKET_MODE=none
  build_phases
  print_map
  echo "DONE: lab restored from the backups. Git was not changed. Compare a row you know before you delete the export."
}

cmd_rebuild() {
  log_start rebuild
  cfg_load
  load_values
  maintenance_begin rebuild
  if [ "$RESTORE" = 1 ]; then
    rebuild_restore
    return
  fi
  phase "Preflight" preflight
  ask_sudo
  if [ "$(vm_state)" != missing ] || [ "$(tofu_count)" != 0 ]; then
    down_flow
  fi
  # A plain rebuild empties the Postgres bucket and starts an empty lab on purpose: nothing is left to protect.
  restore_marker_clear
  BUCKET_MODE=empty
  build_phases
  print_map
}

host_cleanup() {
  local f n=0
  # libvirt leftovers (domain without tofu state, volumes of the VM)
  if [ "$(vm_state)" != missing ]; then
    "${VIRSH[@]}" destroy "$VM" >/dev/null 2>&1 || true
    "${VIRSH[@]}" undefine "$VM" --nvram --snapshots-metadata >/dev/null 2>&1 || "${VIRSH[@]}" undefine "$VM" --nvram >/dev/null 2>&1 || true
    echo "libvirt domain $VM removed."
  fi
  for f in "$VM.qcow2" "$VM-cloudinit.iso" "$VM-cloudinit"; do
    if "${VIRSH[@]}" vol-info --pool default "$f" >/dev/null 2>&1; then
      "${VIRSH[@]}" vol-delete --pool default "$f" >/dev/null 2>&1 && echo "Volume removed: $f"
    fi
  done
  if [ "$INCLUDE_IMAGE" = 1 ]; then
    rm -f "$L_image_cache_dir/$L_image_file"
    "${VIRSH[@]}" vol-delete --pool default ubuntu-24.04-noble-base.qcow2 >/dev/null 2>&1 && echo "Base volume ubuntu-24.04-noble-base.qcow2 removed."
    echo "Image cache emptied ($L_image_file)."
  fi
  # tofu state and provider directory (the lock file stays, it pins the provider)
  rm -f "$REPO"/infra/envs/local/terraform.tfstate "$REPO"/infra/envs/local/terraform.tfstate.backup
  rm -rf "$REPO/infra/envs/local/.terraform"
  echo "tofu state and .terraform/ removed (.terraform.lock.hcl stays)."
  # old exports: only the two newest stay
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    rm -f "$f" "$f.sha256" "${f%.qcow2}.xml"
    echo "old export removed: $(basename "$f")"
    n=$((n + 1))
  done < <({ printf '%s\n' "$L_export_dir/$VM"-before-drill-*.qcow2 | sort -r | tail -n +3; printf '%s\n' "$L_export_dir/$VM"-vor-drill-*.qcow2 | sort -r | tail -n +3; }) # lang-allow: legacy file name of old exports
  # old logs (30 days)
  find "$L_log_dir" -maxdepth 1 -name 'lab-*.log' -mtime +30 -delete 2>/dev/null || true
  # Ansible cache
  rm -rf "$HOME"/.ansible/tmp/* "$HOME"/.ansible/cp/* 2>/dev/null || true
  echo "Ansible cache emptied; logs older than 30 days deleted."
  "${VIRSH[@]}" pool-refresh default >/dev/null 2>&1 || true
  echo "$n old export(s) removed."
}

cmd_purge() {
  log_start purge
  cfg_load
  load_values
  maintenance_begin purge
  echo "PURGE cleans up thoroughly. What happens:"
  echo "  - VM $VM with its disk and snapshots gone, libvirt leftovers gone"
  echo "  - ALL backups in rustfs gone: buckets $W_bucket_cnpg and $W_bucket_k8up are emptied and deleted"
  echo "  - /etc/hosts block (Ansible), kubeconfig, known_hosts entries destroyed"
  echo "  - tofu state and .terraform/ gone, old exports (except the 2 newest), old logs"
  echo "  - with --include-image: image cache and libvirt base volume"
  echo "  STAYS: rustfs service and data directory, age key, SSH and deploy keys,"
  echo "          secret files, lab CA, notes passwords, the 2 newest exports, the repo."
  phase "Preflight (tools)" preflight_min
  ask_sudo
  export_guard
  ask_double || exit 0
  if [ "$(vm_state)" != missing ] || [ "$(tofu_count)" != 0 ]; then vm_teardown; fi
  phase "Empty backups in rustfs and delete buckets" empty_buckets all
  phase "Remove host entries (purge-host.yml)" ans_sudo purge-host.yml -e lab_purge_ok=yes
  phase "libvirt, tofu and cache leftovers" host_cleanup
  echo "DONE: host cleaned up. Build again: bash scripts/lab.sh up"
}

cmd_status() {
  cfg_load
  load_values
  local z
  z=$(vm_state)
  echo "VM $VM ($L_vm_ip): $z"
  echo "tofu state: $(tofu_count) resources"
  echo "Image in cache: $([ -f "$L_image_cache_dir/$L_image_file" ] && echo yes || echo no)"
  echo "Latest export: $(latest_export | sed 's#^$#none#')"
  export_check || true
  if [ "$z" = running ] && [ -f "$W_kubeconfig" ]; then
    kubectl get nodes 2>&1 | head -n 5 || true
    echo "Argo CD:"
    argo_status | sed 's/^/  /'
  fi
  if rustfs_s3 buckets --root-env "$W_rustfs_root_env" 2>/dev/null; then :; else echo "rustfs: not reachable"; fi
  echo "Logs: $L_log_dir"
}

# ------------------------------------------------------------------ Acceptance
ACC_EVIDENCE=()
acc_phase() { # acc_phase TITLE command... (continues on error)
  phase "$@" || true
}
collect_evidence() {
  local l
  while IFS= read -r l; do ACC_EVIDENCE+=("$l"); done < <(grep -hE 'Restore ok: |PITR until |Restore test|RESTORE-DRILL RESULT' "$LOG" 2>/dev/null | sed 's/^[[:space:]]*//' | sort -u | head -n 12 || true)
}

# Without acme_* in lab.local.yaml a clear SKIP (does not count as proof of having passed).
acc_public() {
  if [ "${W_acme_active:-False}" != True ]; then
    echo "SKIP: public certificate NOT checked: acme_* is missing in lab.local.yaml (docs/how-to/public-certificate.md)."
    return 0
  fi
  ans verify-public.yml
}

# Replica and alerts: a clear SKIP while they are not installed or switched off (does not count as proof of having passed).
acc_replica() {
  if [ "${W_replica_enabled:-False}" != True ]; then
    echo "SKIP: backup replica NOT checked: backup_replica_enabled is false."
    return 0
  fi
  if [ ! -f "$W_replica_config" ]; then
    echo "SKIP: backup replica NOT checked: not installed yet (bash scripts/lab.sh replica install, docs/how-to/backup-replica.md)."
    return 0
  fi
  python3 "$W_replica_script" verify --config "$W_replica_config"
}
acc_alert() {
  if [ "${W_alert_enabled:-False}" != True ]; then
    echo "SKIP: alerts NOT checked: backup_alert_enabled is false."
    return 0
  fi
  if [ ! -f "$W_alert_config" ]; then
    echo "SKIP: alerts NOT checked: not installed yet (bash scripts/lab.sh alert install, docs/how-to/alerts.md)."
    return 0
  fi
  ans verify-alerts.yml
}

# Samples `kubectl top` in the background for the whole acceptance: the peaks decide the limits (issue #9).
sampler_start() {
  [ -f "$REPO/scripts/memory-budget.py" ] || return 0
  SAMPLER_STOP=$(mktemp -u "$(dirname "$LOG")/.sampler-stop.XXXXXX")
  python3 "$REPO/scripts/memory-budget.py" sample --out "$(dirname "$LOG")/memory-peaks.json" --duration 7200 --interval 10 \
    --stop-file "$SAMPLER_STOP" >> "$LOG" 2>&1 &
  SAMPLER_PID=$!
}
sampler_stop() {
  [ -n "$SAMPLER_PID" ] || return 0
  : > "$SAMPLER_STOP"
  wait "$SAMPLER_PID" 2> /dev/null || true
  rm -f "$SAMPLER_STOP"
  SAMPLER_PID=""
}
# Display only, never fails the acceptance.
budget_report() {
  local peaks
  peaks="$(dirname "$LOG")/memory-peaks.json"
  [ -f "$peaks" ] || return 0
  echo "Memory peaks measured during this acceptance run (limit vs peak):"
  python3 "$REPO/scripts/memory-budget.py" report --peaks "$peaks" --repo "$REPO" || notice "Memory report not readable."
  return 0
}

acc_cluster() {
  kubectl get nodes >/dev/null || return 1
  kubectl wait --for=condition=Ready nodes --all --timeout=600s || return 1
  wait_for_argo 600 || return 1
  wait_for_db
}

acc_optional_site() {
  local app=$1 status
  shift
  status=$(argo_status | grep -E "^${app}([^ ]*) " || true)
  if [ -z "$status" ] || printf '%s\n' "$status" | grep -vq ' Synced/Healthy$'; then
    echo "WARNING: optional $app site not ready; its verification was not run (not a PASS)."
    return 0
  fi
  if ! "$@"; then
    echo "WARNING: optional $app verification failed; core acceptance continues. Run its playbook separately to diagnose."
  fi
}

cmd_acceptance() {
  log_start acceptance
  cfg_load
  load_values
  [ "$(vm_state)" = running ] || die "VM $VM is not running (check status, then up)."
  [ -f "$W_kubeconfig" ] || die "Kubeconfig is missing: $W_kubeconfig (run up first)."
  ask_sudo
  sampler_start
  acc_phase "Cluster ready (nodes, Argo CD, databases)" acc_cluster
  acc_phase "VM hardening (verify.yml)" ans verify.yml
  acc_phase "Argo CD (verify-argocd.yml)" ans verify-argocd.yml
  acc_phase "SOPS/KSOPS (verify-ksops.yml)" ans verify-ksops.yml
  acc_phase "Traefik (verify-traefik.yml)" ans verify-traefik.yml
  acc_phase "cert-manager (verify-certmanager.yml)" ans verify-certmanager.yml
  acc_phase "Public certificate (verify-public.yml, optional)" acc_public
  acc_phase "Docs site (verify-docs.yml, optional)" acc_optional_site docs ans verify-docs.yml
  acc_phase "Notes sites (verify-notes.yml, optional)" acc_optional_site notes ans verify-notes.yml
  acc_phase "Backup target rustfs (verify-backup-s3.yml)" ans_sudo verify-backup-s3.yml
  acc_phase "Gitea: back up a dummy repo, delete it, restore it (verify-gitea.yml)" ans verify-gitea.yml
  acc_phase "Postgres: back up a dummy table, restore it into a new cluster (verify-cnpg.yml)" ans verify-cnpg.yml
  acc_phase "Egress policies (verify-egress.yml)" ans verify-egress.yml
  acc_phase "gitops/ equals lab.yaml and group_vars (verify-consistency.yml)" ans verify-consistency.yml
  acc_phase "Memory budget: limits fit into the VM, no node pressure (verify-budget.yml)" ans verify-budget.yml
  acc_phase "Backup replica: fresh and identical (lab.sh replica verify, optional)" acc_replica
  acc_phase "Alerts: checks pass, fault injection alarms once (verify-alerts.yml, optional)" acc_alert
  acc_phase "Matrix: federation off, admin login, backup and restore (verify-matrix.yml)" ans verify-matrix.yml
  acc_phase "Keycloak: realm, OIDC discovery, admin console closed, backup (verify-keycloak.yml)" ans verify-keycloak.yml
  sampler_stop
  sleep 1
  collect_evidence
  local i failures=0
  for i in "${!ZR[@]}"; do [ "${ZR[$i]}" = 0 ] || failures=$((failures + 1)); done
  echo
  if [ "${#ACC_EVIDENCE[@]}" -gt 0 ]; then
    echo "Evidence from the checks:"
    printf '  %s\n' "${ACC_EVIDENCE[@]}"
  fi
  budget_report
  print_map
  if [ "$failures" = 0 ]; then
    echo "ACCEPTANCE PASSED: all ${#ZR[@]} checks ok."
  else
    echo "ACCEPTANCE NOT PASSED: $failures of ${#ZR[@]} checks failed (details in the log)." >&2
    exit 1
  fi
}

cmd_replica() {
  local action=${POS[0]:-status}
  log_start replica
  cfg_load
  load_values
  [ "$W_replica_enabled" = True ] || die "The replica is switched off (backup_replica_enabled in ansible/inventory/group_vars/all/backup_replica.yml)."
  case $action in
    config) ans backup-replica.yml --tags config ;;
    install) ans backup-replica.yml ;;
    status | verify | mirror | hostkey | authline | preflight)
      [ -f "$W_replica_config" ] || die "Replica config missing ($W_replica_config). Run: bash scripts/lab.sh replica config"
      python3 "$W_replica_script" "$action" --config "$W_replica_config" ;;
    restore)
      [ -n "${POS[1]:-}" ] || die "Usage: bash scripts/lab.sh replica restore DIR (a NEW or empty directory, never the live data dir)"
      [ -f "$W_replica_config" ] || die "Replica config missing ($W_replica_config). Run: bash scripts/lab.sh replica config"
      python3 "$W_replica_script" restore --config "$W_replica_config" --target "${POS[1]}" ;;
    *) die "Usage: bash scripts/lab.sh replica config|hostkey|install|status|verify|mirror|preflight|restore DIR" ;;
  esac
}

cmd_alert() {
  local action=${POS[0]:-status}
  [ "${#POS[@]}" -le 1 ] || die "Usage: bash scripts/lab.sh alert install|status|run|test|verify|heartbeat"
  log_start alert
  cfg_load
  load_values
  [ "$W_alert_enabled" = True ] || die "Alerts are switched off (backup_alert_enabled in ansible/inventory/group_vars/all/alert.yml)."
  case $action in
    install) ans backup-alert.yml ;;
    verify) ans verify-alerts.yml ;;
    status | run | test | heartbeat)
      [ -f "$W_alert_config" ] || die "Alert config missing ($W_alert_config). Run: bash scripts/lab.sh alert install"
      python3 "$W_alert_script" "$action" --config "$W_alert_config" ;;
    *) die "Usage: bash scripts/lab.sh alert install|status|run|test|verify|heartbeat" ;;
  esac
}

cmd_restore_drill() {
  log_start restore-drill
  cfg_load
  load_values
  maintenance_begin restore-drill
  echo "RESTORE-DRILL proves that Gitea and Matrix come back from the backups alone. What happens:"
  echo "  - one more backup each (files, database base backup), then the live state is fingerprinted"
  echo "  - a THROWAWAY namespace with fresh volumes: database recovery from the real archive (read only) and"
  echo "    file restore from the snapshot; both are timed, then compared with the live state"
  echo "  - Matrix is started from those restored volumes and must log in; the signing key is compared, never printed"
  echo "  - the throwaway namespace is deleted again. Nothing real is deleted, the live archive is never written."
  [ "$(vm_state)" = running ] || die "VM $VM is not running (check status, then up)."
  [ -f "$W_kubeconfig" ] || die "Kubeconfig is missing: $W_kubeconfig (run up first)."
  [ "$NO_EXPORT" = 0 ] || die "--no-export does not apply: the drill needs a fresh export (parachute) as a precondition."
  phase "Preflight (tools)" preflight_min
  export_check || die "Run 'bash scripts/lab.sh export' first (parachute). The drill does not run without a fresh export."
  ask_double restore-drill || exit 0
  phase "Restore drill (restore-drill.yml)" ans restore-drill.yml
  grep -h 'RESTORE-DRILL RESULT' "$LOG" | sed 's/^[[:space:]]*//' || true
  echo "DONE: restore drill passed. Note the line above in docs/how-to/restore-drill.md (live record)."
}

cmd_sync_host() {
  log_start sync-host
  cfg_load
  load_values
  echo "SYNC-HOST brings the PC and Argo CD in line with git on a RUNNING VM (a new service, a new notes site, a new host name):"
  echo "  - argocd.yml: Argo CD AppProject destinations (new namespaces), bootstrap, SOPS key, CA, docs"
  echo "  - backup-host.yml: rustfs, buckets and the managed /etc/hosts block (role lab_hosts); needs sudo"
  echo "  Both are idempotent (changed=0 when nothing is new). The VM is not touched, nothing is pushed."
  [ "$(vm_state)" = running ] || die "VM $VM is not running (check status, then up)."
  [ -f "$W_kubeconfig" ] || die "Kubeconfig is missing: $W_kubeconfig (run up first)."
  ask_sudo
  phase "Argo CD (argocd.yml: AppProject destinations, bootstrap, SOPS, CA, docs)" ans argocd.yml
  phase "Set up the PC (backup-host.yml: rustfs, buckets, /etc/hosts)" ans_sudo backup-host.yml
  echo
  echo "Ansible runs (second run: changed=0):"
  printf '%s' "$CHANGED_TEXT"
  echo "  Total changed=$CHANGED_TOTAL"
  echo "DONE: Argo CD and /etc/hosts follow git. Next: let Argo CD sync, then the verify playbook of the new service."
}

cmd_budget() {
  log_start budget
  cfg_load
  local peaks="$L_log_dir/memory-peaks.json"
  [ -f "$peaks" ] || die "No memory measurement yet ($peaks). Run: bash scripts/lab.sh acceptance (it samples kubectl top)."
  python3 "$REPO/scripts/memory-budget.py" report --peaks "$peaks" --repo "$REPO"
  if [ "$APPLY" = 1 ]; then
    python3 "$REPO/scripts/memory-budget.py" apply --peaks "$peaks" --repo "$REPO"
    echo "Next: review 'git diff', commit and push, then: cd ansible && ansible-playbook argocd.yml (Argo CD limits) and let Argo CD sync."
  else
    echo "Dry look only. To write the proposed limits into git: bash scripts/lab.sh budget --apply"
  fi
}
# Prints a one-line note to stderr when a legacy German name is used.
deprecated() {
  echo "NOTE: '$1' is deprecated, use '$2'. The German name still works for now, it will be removed before December 2026." >&2
}

usage() {
  awk 'NR > 1 { if ($0 !~ /^#/ || $0 ~ /^# shellcheck/) exit; print }' "${BASH_SOURCE[0]}" | grep -vE 'PRIVATE-|^# SPDX-' | sed 's/^# \{0,1\}//'
}

# gitea-import: all arguments belong to scripts/gitea-import.sh (its own options), so lab.sh does not parse them.
# `recipients` and --help need no cluster; everything else needs the lab kubeconfig.
cmd_gitea_import() {
  local a needs_cluster=1
  for a in "$@"; do
    case $a in recipients | -h | --help | help) needs_cluster=0 ;; *) ;; esac
  done
  if [ "$needs_cluster" = 1 ]; then
    cfg_load
    load_values
    [ -f "$W_kubeconfig" ] || die "Kubeconfig is missing: $W_kubeconfig (run up first)."
  fi
  exec bash "$REPO/scripts/gitea-import.sh" "$@"
}

# kit: all arguments belong to scripts/emergency-kit.sh. It needs no configuration, so lab.sh only runs it from the
# directory you called lab.sh in (a relative DIR such as ./usb then means what you typed).
cmd_kit() {
  cd "$LAB_CALLER_PWD"
  exec bash "$REPO/scripts/emergency-kit.sh" "$@"
}

# matrix-import: all arguments belong to scripts/matrix-import.sh (its own options), so lab.sh does not parse them.
# `recipients` and --help need no cluster, `prepare` only the configuration; everything else needs the lab kubeconfig.
cmd_matrix_import() {
  local a needs_cluster=1 needs_values=1
  for a in "$@"; do
    case $a in
      recipients | -h | --help | help) needs_cluster=0; needs_values=0 ;;
      prepare) needs_cluster=0 ;;
      *) ;;
    esac
  done
  if [ "$needs_values" = 1 ]; then
    cfg_load
    load_values
    if [ "$needs_cluster" = 1 ]; then
      [ -f "$W_kubeconfig" ] || die "Kubeconfig is missing: $W_kubeconfig (run up first)."
    fi
    export MATRIX_IMPORT_SIGNING_KEY_FILE=$W_matrix_signing_key_file
    export MATRIX_IMPORT_REPO=$REPO
    export MATRIX_IMPORT_BASE_URL=${MATRIX_IMPORT_BASE_URL:-https://matrix.$L_domain}
  fi
  exec bash "$REPO/scripts/matrix-import.sh" "$@"
}

main() {
  local subcommand=${1:-}
  [ -n "$subcommand" ] || { usage; exit 2; }
  shift || true
  case $subcommand in
    abnahme) deprecated abnahme acceptance; subcommand=acceptance ;;
    geheimnisse) deprecated geheimnisse secrets; subcommand=secrets ;;
    anpassen) deprecated anpassen customize; subcommand=customize ;;
  esac
  if [ "$subcommand" = backup ]; then
    BACKUP_MODE=--force-all
    case "$*" in "") ;; --check) BACKUP_MODE=--check ;; *) die "Usage: bash scripts/lab.sh backup [--check]" ;; esac
    cmd_backup
    return
  fi
  [ "$subcommand" != gitea-import ] || cmd_gitea_import "$@"
  [ "$subcommand" != matrix-import ] || cmd_matrix_import "$@"
  [ "$subcommand" != kit ] || cmd_kit "$@"
  if [ "$subcommand" = tools ]; then
    local action=${1:-}
    [ $# -eq 0 ] || shift
    case "$action" in
      install) exec bash "$REPO/scripts/install-tools.sh" "$@" ;;
      check) exec bash "$REPO/scripts/install-tools.sh" --check "$@" ;;
      *) die "Usage: bash scripts/lab.sh tools install|check [OPTIONS]" ;;
    esac
  fi
  local a
  for a in "$@"; do
    case $a in
      --yes) YES=1 ;;
      --ja) deprecated --ja --yes; YES=1 ;;
      --no-export) NO_EXPORT=1 ;;
      --live) LIVE=1 ;;
      --destroy-ok) DESTROY_OK=1 ;;
      --zerstoeren-ok) deprecated --zerstoeren-ok --destroy-ok; DESTROY_OK=1 ;;
      --include-image) INCLUDE_IMAGE=1 ;;
      --auch-image) deprecated --auch-image --include-image; INCLUDE_IMAGE=1 ;;
      --new-age-key) NEW_AGE=1 ;;
      --neuer-age-schluessel) deprecated --neuer-age-schluessel --new-age-key; NEW_AGE=1 ;;
      --break-glass) BREAK_GLASS=1 ;;
      --break-glass-delete) BREAK_GLASS_DELETE=1 ;;
      --dry-run) DRY_RUN=1 ;;
      --trocken) deprecated --trocken --dry-run; DRY_RUN=1 ;;
      --fetch-host-keys) HOST_KEYS=1 ;;
      --host-keys-holen) deprecated --host-keys-holen --fetch-host-keys; HOST_KEYS=1 ;;
      --resolve) RESOLVE=1 ;;
      --prune) PRUNE=1 ;;
      --ohne-export) deprecated --ohne-export --no-export; NO_EXPORT=1 ;;
      --apply) APPLY=1 ;;
      --restore) RESTORE=1 ;;
      --trust-override) TRUST_OVERRIDE=1 ;;
      -*) die "Unknown option: $a" ;;
      *) POS+=("$a") ;;
    esac
  done
  case $subcommand in
    replica | alert | secrets-repo | trust | source) ;;
    *) [ "${#POS[@]}" = 0 ] || die "Unexpected argument: ${POS[0]}" ;;
  esac
  if [ "$subcommand" != init ] && { [ "$BREAK_GLASS" = 1 ] || [ "$BREAK_GLASS_DELETE" = 1 ]; }; then
    die "--break-glass and --break-glass-delete only apply to init."
  fi
  if [ "$BREAK_GLASS" = 1 ] && [ "$BREAK_GLASS_DELETE" = 1 ]; then
    die "--break-glass and --break-glass-delete exclude each other."
  fi
  if [ "$subcommand" != init ] && [ "$NEW_AGE" = 1 ]; then
    die "--new-age-key only applies to init."
  fi
  local dry_run_allowed=0 dry_run_extra=""
  case $subcommand in
    init | customize | ca-rotation | repo-egress | secrets-repo) dry_run_allowed=1 ;;
  esac
  if [ "$dry_run_allowed" = 0 ] && [ "$DRY_RUN" = 1 ]; then
    die "--dry-run only applies to init, customize, ca-rotation and repo-egress (and secrets-repo$dry_run_extra)."
  fi
  if [ "$subcommand" != secrets-repo ] && [ "$PRUNE" = 1 ]; then
    die "--prune only applies to secrets-repo export."
  fi
  if [ "$subcommand" != repo-egress ] && [ "$RESOLVE" = 1 ]; then
    die "--resolve only applies to repo-egress."
  fi
  if [ "$RESOLVE" = 1 ] && [ "$DRY_RUN" = 1 ]; then
    die "--resolve and --dry-run exclude each other (--resolve writes lab.local.yaml)."
  fi
  if [ "$subcommand" = restore-drill ] && [ "$NO_EXPORT" = 1 ]; then
    die "--no-export does not apply to restore-drill: it needs a fresh export (parachute)."
  fi
  if [ "$RESTORE" = 1 ] && [ "$subcommand" != rebuild ]; then
    die "--restore only applies to rebuild."
  fi
  if [ "$RESTORE" = 1 ] && [ "$NO_EXPORT" = 1 ]; then
    die "--no-export does not apply to rebuild --restore: it needs a fresh export (parachute)."
  fi
  case $subcommand in
    up | rebuild | preflight | trust) ;;
    *) [ "$TRUST_OVERRIDE" = 0 ] || die "--trust-override only applies to up, rebuild, preflight and trust release." ;;
  esac
  if [ "$subcommand" != budget ] && [ "$APPLY" = 1 ]; then
    die "--apply only applies to budget."
  fi
  if [ "$subcommand" != customize ] && [ "$HOST_KEYS" = 1 ]; then
    die "--fetch-host-keys only applies to customize."
  fi
  case $subcommand in
    up) cmd_up ;;
    down) cmd_down ;;
    rebuild) cmd_rebuild ;;
    purge) cmd_purge ;;
    status) cmd_status ;;
    acceptance) cmd_acceptance ;;
    budget) cmd_budget ;;
    replica) cmd_replica ;;
    alert) cmd_alert ;;
    restore-drill) cmd_restore_drill ;;
    export) cmd_export ;;
    backup) cmd_backup ;;
    preflight) cmd_preflight ;;
    init) cmd_init ;;
    secrets) cmd_secrets ;;
    secrets-repo) cmd_secrets_repo ;;
    trust) cmd_trust ;;
    source) cmd_source ;;
    customize) cmd_customize ;;
    repo-egress) cmd_repo_egress ;;
    sync-host) cmd_sync_host ;;
    gitea-import) ;;
    matrix-import) ;;
    kit) ;;
    ca-rotation) cmd_ca_rotation ;;
    -h | --help | help) usage ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
