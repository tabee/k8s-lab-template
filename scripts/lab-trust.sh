#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
# Source trust for rebuilds (ADR 0023): is the commit that Argo CD is about to read the
# one you trust? Argo CD cannot verify SSH commit signatures (only GnuPG), so this script
# does it BEFORE the cluster reads the repo, with the same allowed_signers file the
# CI check uses.
#
# Usage:
#   bash scripts/lab-trust.sh status
#   bash scripts/lab-trust.sh init COMMIT       record the first trusted commit (typed confirmation)
#   bash scripts/lab-trust.sh verify COMMIT [--record]
#   bash scripts/lab-trust.sh record COMMIT     record without verifying (lab.sh does this after an override)
#   Options: --repo DIR (default: the repo of this script), --signers-path PATH
#   (default .gitea/allowed_signers), env LAB_TRUST_DIR (state directory, default
#   ~/.config/k8s-lab), LAB_REQUIRE_TTY=0 (tests: answers come from stdin).
#
# State: LAB_TRUST_DIR/trusted-head (mode 0600, OUTSIDE Git): "<sha> <UTC time> <note>".
# verify passes only if COMMIT is the trusted commit or a descendant of it, and every
# commit between them carries a valid SSH signature of a key that is listed in
# allowed_signers of ITS OWN PARENT (a commit cannot approve its own key).
# A rewritten history, a rollback to an older commit and an unsigned commit all fail.
#
# Exit codes: 0 verified, 1 not verified, 2 misuse, 3 no trusted commit recorded yet.
set -u

SIGNERS_PATH=.gitea/allowed_signers
REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
STATE_DIR=${LAB_TRUST_DIR:-$HOME/.config/k8s-lab}
STATE=$STATE_DIR/trusted-head

usage() { sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; }
die() { echo "ABORT $*" >&2; exit 2; }
g() { git -C "$REPO_DIR" "$@"; }

cmd=${1:-}
[ -n "$cmd" ] || { usage; exit 2; }
case $cmd in -h | --help) usage; exit 0 ;; *) ;; esac
shift
commit=
record=0
while [ $# -gt 0 ]; do
  case $1 in
    --repo) REPO_DIR=${2:-}; shift 2 ;;
    --signers-path) SIGNERS_PATH=${2:-}; shift 2 ;;
    --record) record=1; shift ;;
    -h | --help) usage; exit 0 ;;
    -*) die "unknown argument: $1" ;;
    *) [ -z "$commit" ] || die "unexpected argument: $1"; commit=$1; shift ;;
  esac
done

state_sha() { [ -f "$STATE" ] && awk 'NR == 1 { print $1 }' "$STATE"; }

write_state() { # write_state SHA NOTE
  mkdir -p "$STATE_DIR" && chmod 0700 "$STATE_DIR" || die "cannot create $STATE_DIR"
  local t
  t=$(mktemp "$STATE_DIR/.trusted-head.XXXXXX") || die "cannot write in $STATE_DIR"
  printf '%s %s %s\n' "$1" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$2" > "$t" && chmod 0600 "$t" && mv "$t" "$STATE" \
    || { rm -f "$t"; die "cannot write $STATE"; }
}

resolve() { g rev-parse --verify --quiet "$1^{commit}" 2> /dev/null; }

case $cmd in
  status)
    if [ -f "$STATE" ]; then
      echo "Trusted commit: $(awk 'NR == 1 { print $1 }' "$STATE")"
      echo "Recorded:       $(awk 'NR == 1 { print $2 }' "$STATE") ($(cut -d' ' -f3- "$STATE" | head -n 1))"
      echo "State file:     $STATE"
    else
      echo "No trusted commit recorded ($STATE)."
      echo "First time: check the commit id on your private Git server, then run: bash scripts/lab.sh trust init COMMIT"
    fi
    ;;

  init | record)
    [ -n "$commit" ] || die "$cmd needs a commit id"
    full=$(resolve "$commit") || die "commit $commit is not in $REPO_DIR (git fetch first)"
    if [ "$cmd" = init ]; then
      if [ "${LAB_REQUIRE_TTY:-1}" = 1 ] && [ ! -t 0 ]; then die "init needs a terminal (typed confirmation)."; fi
      echo "You are about to declare this commit as the trust anchor for rebuilds:"
      g log -1 --format='  %H%n  %an, %ad%n  %s' --date=iso "$full"
      if [ -f "$STATE" ]; then echo "  (replaces the recorded $(state_sha))"; fi
      read -r -p "Compare the id with your private Git server. Type the first 7 characters (${full:0:7}) to confirm: " a || a=""
      [ "$a" = "${full:0:7}" ] || { echo "Aborted (nothing changed)."; exit 1; }
      write_state "$full" "init by hand"
    else
      write_state "$full" "recorded by lab.sh"
    fi
    echo "Recorded trusted commit ${full:0:7} in $STATE"
    ;;

  verify)
    [ -n "$commit" ] || die "verify needs a commit id"
    command -v ssh-keygen > /dev/null 2>&1 || die "ssh-keygen (OpenSSH 8.0 or newer) is missing"
    target=$(resolve "$commit") || die "commit $commit is not in $REPO_DIR (git fetch first)"
    anchor=$(state_sha) || anchor=
    if [ -z "$anchor" ]; then
      echo "NO TRUST ANCHOR: no trusted commit is recorded ($STATE)." >&2
      echo "Check the commit id on your private Git server, then run: bash scripts/lab.sh trust init COMMIT" >&2
      exit 3
    fi
    base=$(resolve "$anchor") || {
      echo "MISMATCH: the trusted commit ${anchor:0:7} is not in this clone: the history was rewritten, this is another repository, or you need git fetch." >&2
      exit 1
    }
    if [ "$target" = "$base" ]; then
      echo "OK   ${target:0:7} is the trusted commit"
      exit 0
    fi
    if ! g merge-base --is-ancestor "$base" "$target"; then
      if g merge-base --is-ancestor "$target" "$base"; then
        echo "MISMATCH: ${target:0:7} is OLDER than the trusted commit ${base:0:7} (rollback)." >&2
      else
        echo "MISMATCH: ${target:0:7} is not a descendant of the trusted commit ${base:0:7}: history was rewritten or diverged." >&2
      fi
      exit 1
    fi
    tmp=$(mktemp -d) || die "mktemp failed"
    trap 'rm -rf "$tmp"' EXIT
    total=0
    failed=0
    while read -r c; do
      [ -n "$c" ] || continue
      total=$((total + 1))
      short=$(g rev-parse --short "$c")
      subject=$(g log -1 --format=%s "$c")
      parent=$(g rev-parse --verify --quiet "$c^1") || parent=
      why=
      if [ -z "$parent" ]; then
        why="root commit"
      else
        blob=$(g rev-parse --verify --quiet "$parent:$SIGNERS_PATH") || blob=
        if [ -z "$blob" ]; then
          why="no $SIGNERS_PATH in its parent"
        else
          [ -f "$tmp/$blob" ] || g cat-file blob "$blob" > "$tmp/$blob"
          if [ "$(grep -cvE '^[[:space:]]*(#|$)' "$tmp/$blob")" -eq 0 ]; then
            why="no allowed signer in its parent"
          elif g -c gpg.format=ssh -c "gpg.ssh.allowedSignersFile=$tmp/$blob" verify-commit "$c" > /dev/null 2>&1; then
            echo "OK   $short $subject"
            continue
          else
            why="unsigned, or not signed by an allowed signer of its parent"
          fi
        fi
      fi
      echo "FAIL $short $subject ($why)" >&2
      failed=$((failed + 1))
    done < <(g rev-list --reverse "$base..$target")
    echo "Checked $total commit(s) after the trusted ${base:0:7}, $failed failed."
    [ "$failed" -eq 0 ] || exit 1
    if [ "$record" = 1 ]; then
      write_state "$target" "verified by lab.sh"
      echo "Trusted commit advanced to ${target:0:7}."
    fi
    ;;

  *) usage; exit 2 ;;
esac
