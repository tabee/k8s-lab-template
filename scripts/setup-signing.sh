#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
# Sets up SSH commit signing for THIS clone, using a key you already have.
# It never creates a key and never reads or touches the private key (only the .pub).
#
# Usage:
#   bash scripts/setup-signing.sh [KEY] [--global] [--dry-run] [--skip-allowed-signers]
#
#   KEY             the signing key: path of the private key or of the .pub file
#                   (default: ~/.ssh/k8s-lab-signing, a key used ONLY for signing)
#                   --key KEY does the same
#   --global        write the git settings to ~/.gitconfig instead of this clone
#   --dry-run       only show what would change
#   --skip-allowed-signers  do not add the key to .gitea/allowed_signers
#
# What it does, each step only when it is not already so (safe to run twice):
#   1. git config gpg.format ssh, user.signingkey <KEY.pub>, commit.gpgsign true
#      (for this clone also gpg.ssh.allowedSignersFile .gitea/allowed_signers, so that
#      git log --show-signature works; relative, so the clone can move)
#   2. adds the key to .gitea/allowed_signers (the list the CI check trusts)
# It does not ask: it only writes the git config and one line to .gitea/allowed_signers
# (both are plain text and easy to undo). --dry-run shows the steps without writing.
# Afterwards: ssh-add the private key (git signs through ssh-agent), and add the .pub to your
# Gitea account (Settings, SSH keys), because Gitea verifies "signed commits" with the account keys.
set -u

key=${HOME}/.ssh/k8s-lab-signing
scope=--local
dry_run=0
skip_signers=0

usage() { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; }
die() { echo "ABORT $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case $1 in
    --key) key=${2:-}; shift 2 ;;
    --global) scope=--global; shift ;;
    --dry-run) dry_run=1; shift ;;
    --skip-allowed-signers) skip_signers=1; shift ;;
    -h | --help) usage; exit 0 ;;
    -*) die "unknown argument: $1" ;;
    *) key=$1; shift ;;
  esac
done

key=${key/#\~\//$HOME/}
case $key in
  *.pub) ;;
  *) # the private key was named: only its .pub is read
    [ -f "$key.pub" ] || die "no public key $key.pub next to $key (create the key yourself: ssh-keygen -t ed25519 -f $key; this script never does)"
    key=$key.pub
    ;;
esac
[ -f "$key" ] || die "public key not found: $key (create one yourself with ssh-keygen, this script never does)"
read -r key_type key_blob key_comment < "$key"
case $key_type in
  ssh-ed25519 | sk-ssh-ed25519@openssh.com | ecdsa-sha2-* | sk-ecdsa-sha2-* | ssh-rsa) ;;
  *) die "not an SSH public key: $key" ;;
esac
[ -n "${key_blob:-}" ] || die "not an SSH public key: $key"

top=$(git rev-parse --show-toplevel 2> /dev/null) || die "run this inside the k8s-lab clone"
signers_file=$top/.gitea/allowed_signers

# ---------- 1. git config
want_keys="gpg.format user.signingkey commit.gpgsign"
want_vals="ssh|$key|true"
if [ "$scope" = --local ]; then
  want_keys="$want_keys gpg.ssh.allowedSignersFile"
  want_vals="$want_vals|.gitea/allowed_signers"
fi
todo=0
i=0
IFS='|' read -r -a vals <<< "$want_vals"
for k in $want_keys; do
  cur=$(git config "$scope" --get "$k" 2> /dev/null || true)
  if [ "$cur" != "${vals[$i]}" ]; then
    echo "WILL SET   $k = ${vals[$i]}${cur:+   (now: $cur)}"
    todo=1
  fi
  i=$((i + 1))
done
if [ "$todo" = 0 ]; then
  echo "SKIP git config: signing is already set up ($scope)"
elif [ "$dry_run" = 0 ]; then
  i=0
  for k in $want_keys; do
    git config "$scope" "$k" "${vals[$i]}"
    i=$((i + 1))
  done
  echo "DONE git config written ($scope)"
else
  echo "SKIP git config: --dry-run, not changed"
fi

# ---------- 2. allowed signers
if [ "$skip_signers" = 1 ]; then
  echo "SKIP allowed signers: --skip-allowed-signers"
elif [ -f "$signers_file" ] && grep -Fq -- " $key_blob" "$signers_file"; then
  echo "SKIP allowed signers: the key is already in .gitea/allowed_signers"
else
  line="* namespaces=\"git\" $key_type $key_blob${key_comment:+ $key_comment}"
  echo "WILL ADD   to .gitea/allowed_signers: * namespaces=\"git\" $key_type ${key_blob:0:16}...${key_comment:+ $key_comment}"
  if [ "$dry_run" = 0 ]; then
    mkdir -p "$top/.gitea"
    printf '%s\n' "$line" >> "$signers_file"
    echo "DONE allowed signers: key added. Commit and push this file with a signed commit."
  else
    echo "SKIP allowed signers: --dry-run, not changed"
  fi
fi

# ---------- 3. what is still up to you (hints only, nothing is changed)
priv=${key%.pub}
case $(basename "$priv") in
  id_ed25519 | id_rsa | id_ecdsa)
    echo "NOTE $(basename "$priv") is your general login key. A key used ONLY for signing is safer: ssh-keygen -t ed25519 -f ~/.ssh/k8s-lab-signing -C k8s-lab-signing"
    ;;
  *) ;;
esac
if command -v ssh-add > /dev/null 2>&1 && ssh-add -L 2> /dev/null | grep -Fq -- " $key_blob"; then
  echo "OK   the key is loaded in ssh-agent"
else
  echo "TODO git signs through ssh-agent: ssh-add $priv"
fi
echo "TODO Gitea verifies 'signed commits' with the keys of your account: add $key under Settings, SSH keys (once)."
