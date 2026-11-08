#!/usr/bin/env bash
# Trust the lab CA on the Linux PC (or remove it again).
# Takes ONLY the public certificate (lab_ca_cert_path from
# inventory/group_vars/all/lab_ca.yml, creates argocd.yml), never the secret.
#
#   ansible/scripts/lab-ca-trust.sh add    ~/.config/k8s-lab/lab-ca.crt
#   ansible/scripts/lab-ca-trust.sh remove ~/.config/k8s-lab/lab-ca.crt
#
# add:    system store (sudo) + NSS databases of Chromium and Firefox
#         (existing profiles only; close Firefox and Chromium first).
# remove: the same backwards.
# Overwrites nothing: if a different file with the same name already
# lies in the system store, the script aborts.
set -euo pipefail

NAME="lab-ca"   # file name in the system store and NSS nickname

usage() { echo "Usage: $0 add|remove <path/to/lab-ca.crt>" >&2; exit 2; }
[ $# -eq 2 ] || usage
ACTION="$1"; CRT="$2"
case "$ACTION" in add|remove) ;; *) usage ;; esac

# Debian/Ubuntu: update-ca-certificates is in /usr/sbin, which is often missing from the
# PATH of normal users.
PATH="$PATH:/usr/local/sbin:/usr/sbin:/sbin"
command -v openssl >/dev/null || { echo "openssl missing" >&2; exit 1; }
[ -f "$CRT" ] || { echo "File missing: $CRT" >&2; exit 1; }
# Safety net: never copy a private key into trust stores.
if grep -q 'PRIVATE KEY' "$CRT"; then
  echo "ABORT: $CRT contains a private key. Use only the public certificate." >&2
  exit 1
fi
openssl x509 -in "$CRT" -noout >/dev/null 2>&1 || { echo "Not a PEM certificate: $CRT" >&2; exit 1; }
openssl x509 -in "$CRT" -noout -ext basicConstraints 2>/dev/null | grep -q 'CA:TRUE' \
  || { echo "ABORT: $CRT is not a CA certificate (basicConstraints CA:TRUE missing)" >&2; exit 1; }

echo "Certificate:"
openssl x509 -in "$CRT" -noout -subject -enddate -fingerprint -sha256 | sed 's/^/  /'

# ---------- System-Store ----------
if command -v update-ca-certificates >/dev/null; then      # Debian/Ubuntu
  TARGET="/usr/local/share/ca-certificates/${NAME}.crt"; REFRESH=(update-ca-certificates)
elif command -v update-ca-trust >/dev/null; then           # Fedora/RHEL/Arch
  TARGET="/etc/pki/ca-trust/source/anchors/${NAME}.crt"; REFRESH=(update-ca-trust extract)
else
  echo "Neither update-ca-certificates nor update-ca-trust found" >&2; exit 1
fi

if [ "$ACTION" = add ]; then
  if sudo test -e "$TARGET"; then
    if sudo cmp -s "$CRT" "$TARGET"; then
      echo "System store: already present ($TARGET)"
    else
      echo "ABORT: $TARGET exists with different content. First run '$0 remove' with the old file." >&2
      exit 1
    fi
  else
    sudo install -m 0644 -o root -g root "$CRT" "$TARGET"
    sudo "${REFRESH[@]}"
    echo "System store: added ($TARGET)"
  fi
else
  if sudo test -e "$TARGET"; then
    sudo rm -f -- "$TARGET"
    sudo "${REFRESH[@]}" --fresh 2>/dev/null || sudo "${REFRESH[@]}"
    echo "System store: removed ($TARGET)"
  else
    echo "System store: not present"
  fi
fi

# ---------- NSS (Chromium/Chrome, Firefox) ----------
if ! command -v certutil >/dev/null; then
  echo "certutil missing (Debian/Ubuntu: libnss3-tools, Fedora: nss-tools). Browser part skipped." >&2
  exit 0
fi
shopt -s nullglob
DBS=()
[ -f "$HOME/.pki/nssdb/cert9.db" ] && DBS+=("$HOME/.pki/nssdb")
for d in "$HOME"/.mozilla/firefox/*/ "$HOME"/snap/firefox/common/.mozilla/firefox/*/ \
         "$HOME"/.var/app/org.mozilla.firefox/.mozilla/firefox/*/; do
  [ -f "${d}cert9.db" ] && DBS+=("${d%/}")
done
[ ${#DBS[@]} -gt 0 ] || echo "No NSS database found (start the browser once, then again)."
for db in "${DBS[@]}"; do
  if [ "$ACTION" = add ]; then
    if certutil -d "sql:$db" -L -n "$NAME" >/dev/null 2>&1; then
      echo "NSS: already present in $db"
    else
      # C,, = trusted for TLS servers, not for e-mail/code.
      certutil -d "sql:$db" -A -t "C,," -n "$NAME" -i "$CRT"
      echo "NSS: added to $db"
    fi
  else
    if certutil -d "sql:$db" -L -n "$NAME" >/dev/null 2>&1; then
      certutil -d "sql:$db" -D -n "$NAME"
      echo "NSS: removed from $db"
    fi
  fi
done
