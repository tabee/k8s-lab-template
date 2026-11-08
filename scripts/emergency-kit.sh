#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
# Emergency kit (ADR 0025): every key and password that exists only on your PC, in ONE encrypted archive
# on a USB stick, so the lab can be rebuilt from GitHub after the PC lost everything.
#
#   bash scripts/lab.sh kit export DIR [--must-only] [--allow-missing]
#   bash scripts/lab.sh kit verify DIR
#   bash scripts/lab.sh kit import DIR [--force] [--dry-run] [--repo CLONE]
#   (or directly: bash scripts/emergency-kit.sh export|verify|import ...)
#
# export  copies the files of the table below (kit_table) into ONE archive DIR/k8s-lab-kit.tar.age, encrypted with
#         `age -p` (you type the passphrase twice, it is never stored). Next to it, unencrypted: k8s-lab-kit.manifest
#         (paths, modes, sizes, sha256 of the plaintext files, trust anchor, GitHub URL; no content) and
#         README-NOTFALL.txt (restore steps). A missing required file aborts, nothing incomplete is written
#         (--allow-missing: write it anyway and say so in the manifest). DIR must not be inside a Git work tree.
# verify  decrypts to a 0700 tmpfs directory only (never to disk), compares every file with the manifest and
#         removes the plaintext again. Exit 0 = every file OK.
# import  verifies the same way, then puts every file back at its original path (keys 0600, secret directories
#         0700). A file that exists and differs stops everything unless --force; nothing is changed in that case.
#
# The script never prints the content of a file or the passphrase. Paths are the default locations under $HOME
# (the same ones docs/reference/secrets-map.md lists); only the VM key follows ssh_key from lab.yaml. Extra files of
# your own (for example the key to an old server): one relative path per line in ~/.config/k8s-lab/kit-extra.list.
# Environment: LAB_KIT_REPO = repo root (tests; for import use --repo). $HOME is always the home directory used.
set -euo pipefail
umask 077

REPO=${LAB_KIT_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}
ARCHIVE=k8s-lab-kit.tar.age
MANIFEST=k8s-lab-kit.manifest
README='README-NOTFALL.txt'
RAM=""

say() { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() { printf 'ABORT: %s\n' "$*" >&2; exit 1; }
usage() { awk 'NR > 1 { if ($0 !~ /^#/) exit; print }' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

cleanup() {
  if [ -n "$RAM" ] && [ -d "$RAM" ]; then
    # Plaintext only ever lives in this tmpfs directory. Shred what is there, then remove the tree
    # (symlinks of the export staging are removed, never followed).
    find "$RAM" -type f -exec shred -u -- {} + 2> /dev/null || true
    rm -rf "$RAM"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# The kit table: name | class | required | root | path.
#   class     must = cannot be regenerated (or only by breaking the chain of trust); nice = regenerable, but it saves time
#   required  yes = a missing file is an error; no = included if present (optional by design)
#   root      home = under $HOME, repo = under the repo root; "@ssh_key" = ssh_key of lab.yaml (VM key)
#   path      a glob is allowed (nothing found is fine)
# One place per value: tests/kit-tests.sh checks every name against ansible/inventory/group_vars/all/secrets.yml.
kit_table() {
  cat << 'EOF'
age-key|must|yes|home|.config/sops/age/keys.txt
break-glass-key|must|no|home|.config/k8s-lab/break-glass-age.txt
trust-anchor|must|yes|home|.config/k8s-lab/trusted-head
lab-local|must|yes|repo|infra/envs/local/lab.local.yaml
rustfs-root|must|yes|home|.config/rustfs/rustfs.env
s3-cnpg|must|yes|home|.config/k8s-lab/s3-cnpg-k3s-lab.env
s3-k8up|must|yes|home|.config/k8s-lab/s3-k8up-k3s-lab.env
k8up-repo-pw|must|yes|home|.config/k8s-lab/k8up-k3s-lab-repo.pw
gitea-db-pw|must|yes|home|.config/k8s-lab/gitea-k3s-lab-db.pw
gitea-admin-user|must|yes|home|.config/k8s-lab/gitea-k3s-lab-admin.user
gitea-admin-pw|must|yes|home|.config/k8s-lab/gitea-k3s-lab-admin.pw
matrix-db-pw|must|yes|home|.config/k8s-lab/matrix-k3s-lab-db.pw
matrix-admin-user|must|yes|home|.config/k8s-lab/matrix-k3s-lab-admin.user
matrix-admin-pw|must|yes|home|.config/k8s-lab/matrix-k3s-lab-admin.pw
matrix-registration-secret|must|yes|home|.config/k8s-lab/matrix-k3s-lab-registration.secret
matrix-signing-key|must|no|home|.config/k8s-lab/matrix-k3s-lab-signing.key
keycloak-db-pw|must|yes|home|.config/k8s-lab/keycloak-k3s-lab-db.pw
keycloak-admin-user|must|yes|home|.config/k8s-lab/keycloak-k3s-lab-admin.user
keycloak-admin-pw|must|yes|home|.config/k8s-lab/keycloak-k3s-lab-admin.pw
keycloak-gitea-client-secret|must|yes|home|.config/k8s-lab/keycloak-k3s-lab-gitea-client.secret
keycloak-synapse-client-secret|must|yes|home|.config/k8s-lab/keycloak-k3s-lab-synapse-client.secret
keycloak-notes-client-secret|must|yes|home|.config/k8s-lab/keycloak-k3s-lab-notes-client.secret
lab-ca|must|no|home|.config/k8s-lab/lab-ca-secret.yaml
signing-key|must|no|home|.ssh/k8s-lab-signing
replica-install-key|must|no|home|.ssh/id_ed25519
signing-key-pub|nice|no|home|.ssh/k8s-lab-signing.pub
replica-install-key-pub|nice|no|home|.ssh/id_ed25519.pub
lab-ca-cert|nice|no|home|.config/k8s-lab/lab-ca.crt
argocd-deploy-key|nice|no|home|.ssh/argocd-k8s-lab
argocd-deploy-key-pub|nice|no|home|.ssh/argocd-k8s-lab.pub
argocd-secrets-deploy-key|nice|no|home|.ssh/argocd-k8s-lab-secrets
argocd-secrets-deploy-key-pub|nice|no|home|.ssh/argocd-k8s-lab-secrets.pub
replica-ssh-key|nice|no|home|.ssh/k8s-lab-replica
replica-ssh-key-pub|nice|no|home|.ssh/k8s-lab-replica.pub
vm-ssh-key|nice|no|@ssh_key|
vm-ssh-key-pub|nice|no|@ssh_key.pub|
replica-known-hosts|nice|no|home|.config/k8s-lab/replica_known_hosts
replica-config|nice|no|home|.config/k8s-lab/replica.json
alert-config|nice|no|home|.config/k8s-lab/alert.json
alert-matrix-token|nice|no|home|.config/k8s-lab/alert-matrix.sops.yaml
alert-heartbeat-url|nice|no|home|.config/k8s-lab/alert-heartbeat.sops.yaml
wireguard-server-key|must|no|home|.config/k8s-lab/wireguard-server.key
wireguard-client-key|must|no|home|.config/k8s-lab/wireguard-client.key
acme-token|nice|no|home|.config/k8s-lab/acme-dns01.token
gitea-runner-token|nice|no|home|.config/k8s-lab/gitea-k3s-lab-runner.token
notes-deploy-keys|nice|no|home|.ssh/notes-*-deploy*
notes-passwords|nice|no|home|.config/k8s-lab/notes-*.passwort
notes-cookies|nice|no|home|.config/k8s-lab/notes-*.cookie
kit-extra-list|nice|no|home|.config/k8s-lab/kit-extra.list
EOF
}

# kit_extras: the user's own additions (access to other machines that this repo does not know about, for example the
# keys to reach an old server). ~/.config/k8s-lab/kit-extra.list: one path per line, relative to $HOME, a * glob is
# allowed, # starts a comment. They count as nice-to-have: a missing file is never an error.
kit_extras() {
  local f=$HOME/.config/k8s-lab/kit-extra.list line
  [ -f "$f" ] && [ -r "$f" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    [ -n "$line" ] || continue
    if safe_rel "${line//\*/x}"; then
      printf 'extra|nice|no|home|%s\n' "$line"
    else
      warn "kit-extra.list: ignored (only plain paths relative to \$HOME): $line"
    fi
  done < "$f"
}

need_tools() {
  local t missing=""
  for t in age tar sha256sum stat find mktemp install cmp; do
    command -v "$t" > /dev/null 2>&1 || missing="$missing $t"
  done
  [ -z "$missing" ] || die "missing tools:$missing (age: sudo apt install age, or your package manager)."
  tar --version 2> /dev/null | grep -q 'GNU tar' || die "GNU tar is required."
}

# A 0700 directory on a tmpfs: the only place where plaintext may exist.
make_ram_dir() {
  local base t
  for base in "${XDG_RUNTIME_DIR:-}" /dev/shm "/run/user/$(id -u)"; do
    [ -n "$base" ] && [ -d "$base" ] && [ -w "$base" ] || continue
    t=$(stat -f -c %T "$base" 2> /dev/null || true)
    case $t in tmpfs | ramfs) ;; *) continue ;; esac
    RAM=$(mktemp -d -p "$base" k8s-lab-kit.XXXXXX) || continue
    chmod 700 "$RAM"
    return 0
  done
  die "no tmpfs directory found (XDG_RUNTIME_DIR, /dev/shm): refusing to write plaintext to disk."
}

# cfg_get KEY: a flat "key: value" line of lab.local.yaml (wins) or lab.yaml; empty if absent.
cfg_get() {
  local k=$1 f v
  for f in "$REPO/infra/envs/local/lab.local.yaml" "$REPO/infra/envs/local/lab.yaml"; do
    [ -f "$f" ] || continue
    v=$(sed -n "s/^$k:[[:space:]]*//p" "$f" 2> /dev/null | head -n 1 || true)
    v=$(printf '%s' "$v" | sed -e 's/[[:space:]]\{1,\}#.*$//' -e 's/[[:space:]]*$//' -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/")
    [ -z "$v" ] || { printf '%s' "$v"; return 0; }
  done
  return 0
}

github_https_url() {
  local u
  u=$(cfg_get github_repo_url)
  [ -n "$u" ] || { printf 'none'; return 0; }
  printf '%s' "$u" | sed -e 's#^ssh://git@github.com/#https://github.com/#' -e 's#^git@github.com:#https://github.com/#'
}

anchor_hash() {
  local f="$HOME/.config/k8s-lab/trusted-head"
  if [ -f "$f" ] && [ -r "$f" ]; then
    awk 'NR == 1 { print $1 }' "$f"
  else
    printf 'none'
  fi
}

safe_rel() { # safe_rel PATH: a plain relative path without .. components
  local p=$1
  [[ $p =~ ^[A-Za-z0-9._@+-][A-Za-z0-9._@+/-]*$ ]] || return 1
  case "/$p/" in */../* | *//*) return 1 ;; *) return 0 ;; esac
}

# resolve_entries OUTFILE MUST_ONLY: one line per file: STATUS CLASS REQUIRED ROOT RELPATH (tab separated);
# STATUS is ok or missing. Nothing is read here, only tested for existence.
resolve_entries() {
  local out=$1 must_only=$2 name class req root path rel base abs found
  : > "$out"
  while IFS='|' read -r name class req root path; do
    [ -n "$name" ] || continue
    if [ "$class" != must ] && [ "$must_only" = 1 ]; then continue; fi
    case $root in
      @ssh_key | @ssh_key.pub)
        abs=$(cfg_get ssh_key)
        [ -n "$abs" ] || continue
        abs=${abs/#\~\//$HOME/}
        [ "$root" = @ssh_key ] || abs=$abs.pub
        case $abs in
          "$HOME"/*) root=home; path=${abs#"$HOME"/} ;;
          *) warn "ssh_key of lab.yaml is outside \$HOME ($abs): not part of the kit."; continue ;;
        esac
        ;;
      *) ;;
    esac
    if [ "$root" = repo ]; then base=$REPO; else base=$HOME; fi
    if [[ $path == *'*'* ]]; then
      # shellcheck disable=SC2086 # the glob in $path is meant to expand
      found=$(cd "$base" 2> /dev/null && shopt -s nullglob && printf '%s\n' $path) || true
      while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        safe_rel "$rel" || { warn "skipped (unusual file name): $rel"; continue; }
        if [ -f "$base/$rel" ] && [ -r "$base/$rel" ]; then
          printf 'ok\t%s\t%s\t%s\t%s\n' "$class" "$req" "$root" "$rel" >> "$out"
        fi
      done <<< "$found"
      continue
    fi
    safe_rel "$path" || die "internal: unsafe path in the kit table: $path"
    if [ -f "$base/$path" ] && [ -r "$base/$path" ]; then
      printf 'ok\t%s\t%s\t%s\t%s\n' "$class" "$req" "$root" "$path" >> "$out"
    else
      printf 'missing\t%s\t%s\t%s\t%s\n' "$class" "$req" "$root" "$path" >> "$out"
    fi
  done < <(kit_table; kit_extras)
  awk -F'\t' '!seen[$4 FS $5]++' "$out" > "$out.u" && mv "$out.u" "$out"
}

root_dir() { if [ "$1" = repo ]; then printf '%s' "$REPO"; else printf '%s' "$HOME"; fi; }

write_readme() { # write_readme FILE ANCHOR URL
  local f=$1 anchor=$2 url=$3
  # lang-allow-begin (German text of the product: the README on the stick)
  cat > "$f" << 'EOF'
NOTFALL-KIT FÜR DAS K8S-LAB
===========================

WAS ist das?
  k8s-lab-kit.tar.age enthält alle Schlüssel und Passwörter, die nur auf dem PC lagen (verschlüsselt mit age,
  Passphrase). Ohne die Passphrase ist der Stick wertlos. Ohne den Stick sind die Backups und die Secrets
  unlesbar. Die Passphrase steht NICHT auf dem Stick: sie gehört in den Passwort-Manager.

Inhalt des Sticks:
  k8s-lab-kit.tar.age       das verschlüsselte Archiv
  k8s-lab-kit.manifest      Liste der Dateien (Pfad, Grösse, sha256), ohne Inhalt
  README-NOTFALL.txt        diese Anleitung

NEUAUFBAU (Kurzfassung, Details: docs/how-to/notfall-neuaufbau.md im Repo)
  1. Werkzeuge installieren: git, age, gh (GitHub CLI), danach die Pakete, die `lab.sh preflight` nennt.
  2. Bei GitHub anmelden (Browser, Passkey) und das Repo holen:
       gh auth login --web
       gh repo clone @REPO_PATH@ k8s-lab
       cd k8s-lab
  3. Stick einstecken und die Schlüssel zurücklegen (fragt die Passphrase):
       bash scripts/lab.sh kit verify /PFAD/ZUM/STICK
       bash scripts/lab.sh kit import /PFAD/ZUM/STICK
  4. Vertrauensanker prüfen (kommt aus dem Kit, sonst von Hand setzen):
       bash scripts/lab.sh trust status
       bash scripts/lab.sh trust init @ANCHOR@
  5. Lab bauen:
       bash scripts/lab.sh preflight
       bash scripts/lab.sh up

Eselsbrücke: Stick = Schlüsselbund, GitHub = Haus, Passphrase = der Kopf, der den Bund öffnet.

GitHub-Repo: @REPO_URL@
Vertrauensanker (Commit): @ANCHOR@
EOF
  # lang-allow-end
  local path
  path=${url#https://github.com/}
  path=${path%.git}
  sed -i -e "s#@REPO_URL@#$url#g" -e "s#@REPO_PATH@#$path#g" -e "s#@ANCHOR@#$anchor#g" "$f"
}

cmd_export() {
  local dir="" must_only=0 allow_missing=0 a
  for a in "$@"; do
    case $a in
      --must-only) must_only=1 ;;
      --allow-missing) allow_missing=1 ;;
      -h | --help) usage; exit 0 ;;
      -*) die "unknown option $a (see --help)." ;;
      *) [ -z "$dir" ] || die "one DIR only."; dir=$a ;;
    esac
  done
  [ -n "$dir" ] || { usage; exit 2; }
  need_tools
  [ -d "$dir" ] || die "$dir is not a directory (mount the USB stick first)."
  [ -w "$dir" ] || die "$dir is not writable."
  local real
  real=$(cd "$dir" && pwd -P)
  case "$real/" in
    "$REPO"/*) die "DIR is inside the repo ($REPO): the kit holds secrets and must never be committed." ;;
    *) ;;
  esac
  if git -C "$real" rev-parse --is-inside-work-tree > /dev/null 2>&1; then
    die "DIR is inside a Git work tree: the kit holds secrets and must never be committed."
  fi
  { : < /dev/tty; } 2> /dev/null || die "no terminal: age -p asks for the passphrase on the terminal."
  if [ "$(stat -c %d "$real")" = "$(stat -c %d "$HOME")" ]; then
    warn "DIR is on the same filesystem as your home directory. This is NOT a separate medium: if the PC is lost, the kit is lost with it."
  fi

  make_ram_dir
  local ent="$RAM/entries.tsv"
  resolve_entries "$ent" "$must_only"
  local miss
  miss=$(awk -F'\t' '$1 == "missing" && $3 == "yes" { print "  " $5 }' "$ent")
  if [ -n "$miss" ]; then
    printf 'Required files are missing:\n%s\n' "$miss" >&2
    if [ "$allow_missing" = 1 ]; then
      warn "writing an INCOMPLETE kit (--allow-missing); the manifest says so."
    else
      die "nothing was written. Create them (bash scripts/lab.sh init) or restore them, or use --allow-missing."
    fi
  fi

  local url anchor st class req root rel base sha size mode
  url=$(github_https_url)
  anchor=$(anchor_hash)
  mkdir -p "$RAM/stage/kit"
  : > "$RAM/members.txt"
  echo kit/manifest >> "$RAM/members.txt"
  {
    echo "# k8s-lab emergency kit manifest: paths, modes, sizes, sha256 of the plaintext files. No secret content."
    echo "# F = file inside the archive, M = file that was not there at export time."
    echo "# F/M<TAB>class<TAB>required<TAB>root<TAB>mode<TAB>size<TAB>sha256<TAB>path"
    echo "format: 1"
    echo "created: $(date -Iseconds)"
    echo "archive: $ARCHIVE"
    echo "github-repo: $url"
    echo "trust-anchor: $anchor"
    while IFS=$'\t' read -r st class req root rel; do
      if [ "$st" = ok ]; then
        base=$(root_dir "$root")
        sha=$(sha256sum -- "$base/$rel" | cut -d' ' -f1)
        size=$(stat -c %s -- "$base/$rel")
        mode=$(stat -c %a -- "$base/$rel")
        printf 'F\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$class" "$req" "$root" "$mode" "$size" "$sha" "$rel"
        mkdir -p "$RAM/stage/$root/$(dirname "$rel")"
        ln -s "$base/$rel" "$RAM/stage/$root/$rel"
        echo "$root/$rel" >> "$RAM/members.txt"
      else
        printf 'M\t%s\t%s\t%s\t-\t-\t-\t%s\n' "$class" "$req" "$root" "$rel"
      fi
    done < "$ent"
  } > "$RAM/stage/kit/manifest"

  say "Encrypting with age: type the passphrase twice (it is never stored)."
  rm -f "$real/$ARCHIVE.part"
  if ! tar -c -h -f - -C "$RAM/stage" --numeric-owner --owner=0 --group=0 -T "$RAM/members.txt" | age -p -o "$real/$ARCHIVE.part"; then
    rm -f "$real/$ARCHIVE.part"
    die "encryption failed or was aborted; nothing was written."
  fi
  [ -s "$real/$ARCHIVE.part" ] || { rm -f "$real/$ARCHIVE.part"; die "the archive is empty; nothing was written."; }
  { cat "$RAM/stage/kit/manifest"; echo "archive-sha256: $(sha256sum "$real/$ARCHIVE.part" | cut -d' ' -f1)"; } > "$real/$MANIFEST.part"
  write_readme "$real/$README.part" "$anchor" "$url"
  mv -f "$real/$ARCHIVE.part" "$real/$ARCHIVE"
  mv -f "$real/$MANIFEST.part" "$real/$MANIFEST"
  mv -f "$real/$README.part" "$real/$README"
  chmod 644 "$real/$ARCHIVE" "$real/$MANIFEST" "$real/$README" 2> /dev/null || true
  sync

  local n_ok n_miss
  n_ok=$(awk -F'\t' '$1 == "ok"' "$ent" | wc -l)
  n_miss=$(awk -F'\t' '$1 == "missing"' "$ent" | wc -l)
  say ""
  say "Kit written to $real:"
  awk -F'\t' '$1 == "ok" { printf "  %-5s %s/%s\n", $2, $4, $5 }' "$ent"
  [ "$n_miss" = 0 ] || awk -F'\t' '$1 == "missing" { printf "  ABSENT %-5s %s/%s%s\n", $2, $4, $5, ($3 == "yes" ? "  (REQUIRED)" : "  (optional)") }' "$ent"
  say "$n_ok files in $ARCHIVE, $n_miss not present. Trust anchor: $anchor. GitHub: $url"
  say "Next: bash scripts/lab.sh kit verify $real   (proves the passphrase and the content)"
  say "The passphrase is NOT on the stick: put it in your password manager."
}

# extract_kit DIR: check the archive hash, decrypt into $RAM/x (tmpfs), check the structure and the manifest.
extract_kit() {
  local dir=$1 want got
  [ -d "$dir" ] || die "$dir is not a directory."
  [ -f "$dir/$ARCHIVE" ] || die "$dir/$ARCHIVE not found."
  [ -f "$dir/$MANIFEST" ] || die "$dir/$MANIFEST not found."
  want=$(sed -n 's/^archive-sha256: //p' "$dir/$MANIFEST" | head -n 1)
  got=$(sha256sum "$dir/$ARCHIVE" | cut -d' ' -f1)
  [ -n "$want" ] && [ "$want" = "$got" ] || die "the archive does not match the sha256 in the manifest: it is damaged or was replaced."
  { : < /dev/tty; } 2> /dev/null || die "no terminal: age asks for the passphrase on the terminal."
  make_ram_dir
  mkdir "$RAM/x"
  say "Decrypting into a tmpfs directory (nothing is written to disk): type the passphrase."
  if ! age -d "$dir/$ARCHIVE" | tar -x -p --no-same-owner -C "$RAM/x"; then
    die "decryption failed (wrong passphrase or damaged archive)."
  fi
  if [ -n "$(find "$RAM/x" -mindepth 1 ! -type f ! -type d -print -quit)" ]; then
    die "the archive holds something that is not a plain file: refusing."
  fi
  [ -f "$RAM/x/kit/manifest" ] || die "the archive has no manifest inside: refusing."
  grep -v '^archive-sha256:' "$dir/$MANIFEST" | cmp -s - "$RAM/x/kit/manifest" ||
    die "the manifest on the stick differs from the one inside the encrypted archive: the plaintext copy was changed."
}

# check_files: compare $RAM/x with the manifest inside; prints one line per entry, sets N_OK N_BAD N_ABSENT_REQ.
N_OK=0
N_BAD=0
N_ABSENT_REQ=0
check_files() {
  local kind class req root mode size sha rel f gsize gsha gmode listed
  listed="$RAM/listed.txt"
  : > "$listed"
  while IFS=$'\t' read -r kind class req root mode size sha rel; do
    case $kind in
      F)
        safe_rel "$rel" || { say "BAD      unsafe path in the manifest: $rel"; N_BAD=$((N_BAD + 1)); continue; }
        f="$RAM/x/$root/$rel"
        echo "$root/$rel" >> "$listed"
        if [ ! -f "$f" ]; then
          say "MISSING  $class $root/$rel"
          N_BAD=$((N_BAD + 1))
          continue
        fi
        gsize=$(stat -c %s -- "$f")
        gsha=$(sha256sum -- "$f" | cut -d' ' -f1)
        gmode=$(stat -c %a -- "$f")
        if [ "$gsize" != "$size" ] || [ "$gsha" != "$sha" ]; then
          say "DIFFERS  $class $root/$rel (size or sha256 does not match the manifest)"
          N_BAD=$((N_BAD + 1))
        elif [ "$gmode" != "$mode" ]; then
          say "DIFFERS  $class $root/$rel (mode $gmode, manifest says $mode)"
          N_BAD=$((N_BAD + 1))
        else
          say "OK       $class $root/$rel"
          N_OK=$((N_OK + 1))
        fi
        ;;
      M)
        say "ABSENT   $class $root/$rel (was not there at export$([ "$req" = yes ] && echo ', REQUIRED'))"
        [ "$req" != yes ] || N_ABSENT_REQ=$((N_ABSENT_REQ + 1))
        ;;
      *) ;;
    esac
  done < <(grep -E '^[FM]'$'\t' "$RAM/x/kit/manifest")
  while IFS= read -r f; do
    f=${f#"$RAM/x/"}
    [ "$f" != kit/manifest ] || continue
    grep -qxF -- "$f" "$listed" || { say "UNLISTED $f (in the archive, not in the manifest)"; N_BAD=$((N_BAD + 1)); }
  done < <(find "$RAM/x" -type f | sort)
  # The anchor in the manifest header must be the one in the archived trusted-head.
  local ma ga
  ma=$(sed -n 's/^trust-anchor: //p' "$RAM/x/kit/manifest" | head -n 1)
  if [ -f "$RAM/x/home/.config/k8s-lab/trusted-head" ]; then
    ga=$(awk 'NR == 1 { print $1 }' "$RAM/x/home/.config/k8s-lab/trusted-head")
    if [ "$ma" != "$ga" ]; then
      say "DIFFERS  trust anchor in the manifest header does not match the archived trusted-head"
      N_BAD=$((N_BAD + 1))
    fi
  fi
}

cmd_verify() {
  local dir=""
  local a
  for a in "$@"; do
    case $a in
      -h | --help) usage; exit 0 ;;
      -*) die "unknown option $a (see --help)." ;;
      *) [ -z "$dir" ] || die "one DIR only."; dir=$a ;;
    esac
  done
  [ -n "$dir" ] || { usage; exit 2; }
  need_tools
  extract_kit "$dir"
  check_files
  say ""
  if [ "$N_BAD" != 0 ]; then
    say "VERIFY FAILED: $N_BAD problem(s), $N_OK file(s) OK."
    exit 1
  fi
  [ "$N_ABSENT_REQ" = 0 ] || warn "INCOMPLETE KIT: $N_ABSENT_REQ required file(s) were absent when the kit was exported."
  say "VERIFY OK: $N_OK file(s) match the manifest. Trust anchor: $(sed -n 's/^trust-anchor: //p' "$RAM/x/kit/manifest" | head -n 1)"
}

install_dir() { # install_dir ROOT_PATH DIR_ABS: create missing parents below the root (0700 under $HOME)
  local rootp=$1 d=$2 mode=0755
  [ "$rootp" != "$HOME" ] || mode=0700
  [ -d "$d" ] && return 0
  install_dir "$rootp" "$(dirname "$d")"
  install -d -m "$mode" -- "$d"
}

file_mode() { # file_mode PATH MANIFEST_MODE: 0600 for everything private, the manifest mode for public files
  case $(basename "$1") in
    *.pub | *.crt | known_hosts | replica_known_hosts | lab.local.yaml | replica.json | alert.json) printf '%s' "$2" ;;
    *) printf '600' ;;
  esac
}

# pin_github_host_keys: append GitHub's published host keys (github_known_hosts in lab.yaml, fingerprints checked by
# tests/trust-tests.sh against GitHub's list) to ~/.ssh/known_hosts, so the first clone or push after a total loss
# asks no fingerprint question. Lines already present are skipped; without the setting nothing happens.
pin_github_host_keys() {
  local raw line kh="$HOME/.ssh/known_hosts" added=0
  raw=$(cfg_get github_known_hosts)
  [ -n "$raw" ] || { say "GitHub host keys: github_known_hosts not set, ~/.ssh/known_hosts unchanged."; return 0; }
  install_dir "$HOME" "$HOME/.ssh"
  [ -f "$kh" ] || (umask 077; : > "$kh")
  while IFS= read -r line || [ -n "$line" ]; do
    case $line in github.com\ ssh-* | github.com\ ecdsa-*) ;; *) continue ;; esac
    if ! grep -qxF -- "$line" "$kh"; then
      printf '%s\n' "$line" >> "$kh"
      added=$((added + 1))
    fi
  done < <(printf '%s' "$raw" | tr -d '[]' | sed 's/", *"/\n/g' | tr -d '"')
  say "GitHub host keys: $added added to ~/.ssh/known_hosts (expected fingerprints: docs/how-to/neuaufbau-github.md)."
}

cmd_import() {
  local dir="" force=0 dry=0 a
  while [ "$#" -gt 0 ]; do
    a=$1
    shift
    case $a in
      --force) force=1 ;;
      --dry-run) dry=1 ;;
      --repo) [ "$#" -gt 0 ] || die "--repo needs a directory."; REPO=$(cd "$1" && pwd -P) || die "repo directory not found: $1"; shift ;;
      -h | --help) usage; exit 0 ;;
      -*) die "unknown option $a (see --help)." ;;
      *) [ -z "$dir" ] || die "one DIR only."; dir=$a ;;
    esac
  done
  [ -n "$dir" ] || { usage; exit 2; }
  need_tools
  extract_kit "$dir"
  check_files
  say ""
  [ "$N_BAD" = 0 ] || die "refusing to import a kit that does not verify ($N_BAD problem(s)); nothing was changed."
  [ "$N_ABSENT_REQ" = 0 ] || warn "INCOMPLETE KIT: $N_ABSENT_REQ required file(s) were absent when it was exported."

  local kind class req root mode size sha rel src dest conflicts=0 plan="$RAM/plan.tsv"
  : > "$plan"
  while IFS=$'\t' read -r kind class req root mode size sha rel; do
    [ "$kind" = F ] || continue
    src="$RAM/x/$root/$rel"
    dest="$(root_dir "$root")/$rel"
    if [ -L "$dest" ] || [ -e "$dest" ]; then
      if [ -f "$dest" ] && [ ! -L "$dest" ] && cmp -s -- "$src" "$dest"; then
        printf 'SAME\t%s\t%s\t%s\n' "$root" "$rel" "$mode" >> "$plan"
      else
        printf 'DIFFERS\t%s\t%s\t%s\n' "$root" "$rel" "$mode" >> "$plan"
        conflicts=$((conflicts + 1))
      fi
    else
      printf 'NEW\t%s\t%s\t%s\n' "$root" "$rel" "$mode" >> "$plan"
    fi
  done < "$RAM/x/kit/manifest"

  awk -F'\t' '{ printf "  %-8s %s/%s\n", $1, $2, $3 }' "$plan"
  if [ "$conflicts" != 0 ] && [ "$force" = 0 ]; then
    die "$conflicts file(s) exist and differ from the kit; nothing was changed. Compare them, then use --force (the old file is kept as <file>.before-kit-<time>)."
  fi
  if [ "$dry" = 1 ]; then
    say "DRY RUN: nothing was written."
    return 0
  fi

  local st stamp tmode done_new=0 done_same=0 done_over=0
  stamp=$(date +%Y%m%d-%H%M%S)
  while IFS=$'\t' read -r st root rel mode; do
    src="$RAM/x/$root/$rel"
    dest="$(root_dir "$root")/$rel"
    case $st in
      SAME) done_same=$((done_same + 1)); continue ;;
      DIFFERS)
        mv -f -- "$dest" "$dest.before-kit-$stamp"
        done_over=$((done_over + 1))
        ;;
      *) done_new=$((done_new + 1)) ;;
    esac
    install_dir "$(root_dir "$root")" "$(dirname "$dest")"
    tmode=$(file_mode "$dest" "$mode")
    install -m "$tmode" -- "$src" "$dest"
  done < "$plan"
  # Secret directories hold keys: 0700, also when they existed before.
  local d
  for d in .ssh .config/k8s-lab .config/sops/age .config/rustfs; do
    [ -d "$HOME/$d" ] && chmod 700 "$HOME/$d" 2> /dev/null || true
  done

  pin_github_host_keys

  local anchor
  anchor=$(sed -n 's/^trust-anchor: //p' "$RAM/x/kit/manifest" | head -n 1)
  say ""
  say "IMPORT DONE: $done_new new, $done_over replaced, $done_same already identical."
  [ "$done_over" = 0 ] || say "The replaced files were kept as <file>.before-kit-$stamp (delete them when you are sure)."
  say "Next steps:"
  say "  1. bash scripts/lab.sh trust status      (the kit carries the trust anchor; if none is shown: bash scripts/lab.sh trust init ${anchor})"
  say "  2. bash scripts/lab.sh preflight         (checks tools, keys, Git state and the source trust)"
  say "  3. follow docs/how-to/notfall-neuaufbau.md from section C (rebuild from the GitHub clone)."
}

main() {
  local sub=${1:-}
  [ -n "$sub" ] || { usage; exit 2; }
  shift || true
  case $sub in
    export) cmd_export "$@" ;;
    verify) cmd_verify "$@" ;;
    import) cmd_import "$@" ;;
    -h | --help | help) usage ;;
    *) usage; exit 2 ;;
  esac
}
main "$@"
