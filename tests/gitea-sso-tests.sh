#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export SSO_STATE="$T/state" SSO_LOG="$T/log"
mkdir "$T/bin"
cat > "$T/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
set -eu
echo "$*" >> "$SSO_LOG"
case "$*" in
  *'get secret'*) [ "$SSO_MODE" != disabled ] ;;
  *'auth list'*)
    if [ "$SSO_MODE" = exec-fails ]; then echo '1 | keycloak | OAuth2'; exit 1; fi
    if [ "$SSO_MODE" = present ] || { [ "$SSO_MODE" = repair ] && [ -f "$SSO_STATE" ]; }; then
      echo '1 | keycloak | OAuth2'
    else echo '1 | not-keycloak | OAuth2'; fi ;;
  *'rollout restart'*) touch "$SSO_STATE" ;;
  *'rollout status'*) [ "$SSO_MODE" != rollout-fails ] ;;
  *) exit 2 ;;
esac
STUB
chmod +x "$T/bin/kubectl"
export PATH="$T/bin:$PATH"
# Extract only the lifecycle functions; never run the operator entry point.
python3 - "$R" "$T/functions" <<'PY'
from pathlib import Path
import re
import sys
r = Path(sys.argv[1])
s = (r / 'scripts/lab.sh').read_text()
Path(sys.argv[2]).write_text('\n'.join(re.search(r'^' + n + r'\(\).*?^}', s, re.M | re.S).group() for n in ('gitea_sso_present', 'ensure_gitea_sso')))
def fn(n):
    return re.search(r'^' + n + r'\(\).*?^}', s, re.M | re.S).group()
f = fn('build_phases')
assert f.index('wait_for_argo') < f.index('ensure_gitea_sso')
assert f.index('--tags resume') < f.index('ensure_gitea_sso')
assert f.index('ensure_gitea_sso') < f.index('import_accept_restored')
assert all('build_phases' in fn(n) for n in ('up_flow', 'cmd_rebuild', 'rebuild_restore'))
print('OK   up, rebuild and restore repair after Argo/resume, before import acceptance')
PY
source "$R/scripts/gitea-sso.sh"
source "$T/functions"
for mode in present repair missing disabled exec-fails rollout-fails; do
  export SSO_MODE=$mode
  rm -f "$SSO_STATE"
  : > "$SSO_LOG"
  rc=0
  (set -e; ensure_gitea_sso) > "$T/out" 2>&1 || rc=$?
  expected=0
  case "$mode" in missing|exec-fails|rollout-fails) expected=1 ;; esac
  [ "$rc" = "$expected" ] || { echo "FAIL $mode exit $rc"; exit 1; }
  restarts=$(grep -c 'rollout restart' "$SSO_LOG" || true)
  case "$mode" in present|disabled) [ "$restarts" = 0 ] ;; *) [ "$restarts" = 1 ] ;; esac
  echo "OK   $mode: bounded repair, expected status, no unnecessary restart"
done
