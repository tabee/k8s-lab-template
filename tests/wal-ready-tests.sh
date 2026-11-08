#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
# Offline tests for scripts/lab-wal-ready.py. No cluster: kubectl is a stub.
#   1. comparison self-test
#   2. already archived: no WAL switch
#   3. endWal still open: one switch, then success
#   4. archive never catches up: exit 1, VM must not be stopped for this
#   5. no completed backup: fail (the VM must not be stopped)
#   6. lab.sh down and export call the check with no skip flag
#   7. idle cluster: a tiny WAL record is written before the switch (otherwise the empty segment is never archived)
# Usage: bash tests/wal-ready-tests.sh [repo root]
set -u
export PYTHONDONTWRITEBYTECODE=1
R=$(cd "${1:-$(dirname "${BASH_SOURCE[0]}")/..}" && pwd -P)
mkdir -p "$HOME/.cache/lab-sh-tests"
T=$(mktemp -d -p "$HOME/.cache/lab-sh-tests")
cleanup() { rm -rf "$T"; }
trap cleanup EXIT
fail=0
n=0
ok() { n=$((n + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else echo "FAIL $1 (is '$2', want '$3')"; fail=$((fail + 1)); fi; }
has() { grep -Fq -- "$2" "$3"; local r=$?; ok "$1" "$r" 0; }
hasnot() { if grep -Fq -- "$2" "$3"; then ok "$1" 1 0; else ok "$1" 0 0; fi; }
S="$R/scripts/lab-wal-ready.py"
ENDWAL="000000010000000000000005"
OLDWAL="000000010000000000000004"

mkdir -p "$T/bin" "$T/fake"
cat > "$T/bin/kubectl" << 'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_DIR/calls"
mode=$(cat "$FAKE_DIR/mode")
if [ "$mode" = "fail-get" ]; then
  echo "connection refused" >&2
  exit 1
fi
case "$*" in
  *clusters.postgresql.cnpg.io*) cat "$FAKE_DIR/clusters.json"; exit 0 ;;
  *backups.postgresql.cnpg.io*) cat "$FAKE_DIR/backups.json"; exit 0 ;;
esac
case "$*" in
  *pg_logical_emit_message*)
    if [ "$mode" = "emit-fail" ]; then echo "ERROR: permission denied" >&2; exit 1; fi
    echo 1 >> "$FAKE_DIR/emits"
    echo "0/5000028"
    exit 0
    ;;
  *pg_switch_wal*)
    echo 1 >> "$FAKE_DIR/switches"
    if [ "$mode" = "catch-up" ]; then cp "$FAKE_DIR/switch_to" "$FAKE_DIR/archived"; fi
    # idle cluster: the switch of an empty segment does nothing, the archive only moves after a WAL record
    if [ "$mode" = "idle" ] && [ -s "$FAKE_DIR/emits" ]; then cp "$FAKE_DIR/switch_to" "$FAKE_DIR/archived"; fi
    cat "$FAKE_DIR/switch_to"
    exit 0
    ;;
  *last_archived_wal*)
    cat "$FAKE_DIR/archived"
    exit 0
    ;;
esac
echo "unexpected kubectl: $*" >&2
exit 1
SH
chmod +x "$T/bin/kubectl"

cat > "$T/fake/clusters.json" << 'JSON'
{"items":[
  {"metadata":{"namespace":"matrix","name":"matrix-db"},"status":{"currentPrimary":"matrix-db-1"}},
  {"metadata":{"namespace":"db-lab","name":"pg-lab"},"status":{"currentPrimary":"pg-lab-1"}},
  {"metadata":{"namespace":"keycloak","name":"keycloak-db"},"status":{"currentPrimary":"keycloak-db-1"}}
]}
JSON
printf '%s\n' "$ENDWAL" > "$T/fake/switch_to"
: > "$T/fake/switches"
: > "$T/fake/emits"

write_backups() { # write_backups ENDWAL_OR_EMPTY [NAMESPACE[,NAMESPACE]]
  python3 - "$T/fake/backups.json" "$1" "${2:-}" << 'PY'
import json, sys
path, end, only = sys.argv[1], sys.argv[2], sys.argv[3]
items = []
for ns, name in (("matrix", "matrix-db"), ("db-lab", "pg-lab"), ("keycloak", "keycloak-db")):
    if only and ns not in only.split(','):
        continue
    status = {"phase": "completed", "stoppedAt": "2026-11-01T14:45:34Z"}
    if end:
        status["endWal"] = end
    items.append({
        "metadata": {"namespace": ns, "name": "daily"},
        "spec": {"cluster": {"name": name}},
        "status": status,
    })
json.dump({"items": items}, open(path, "w"))
PY
}

run_py() {
  FAKE_DIR="$T/fake" PATH="$T/bin:$PATH" python3 "$S" --attempts 2 --interval 0 "$@" > "$T/out" 2> "$T/err"
}

python3 "$S" --self-test > "$T/out" 2> "$T/err"
ok "self-test exit 0" "$?" 0
has "self-test says OK" "OK   self-test" "$T/out"

echo already > "$T/fake/mode"
printf '%s\n' "000000010000000000000008" > "$T/fake/archived"
write_backups "$ENDWAL"
: > "$T/fake/switches"
: > "$T/fake/calls"
run_py
ok "already archived: exit 0" "$?" 0
has "already archived: OK line" "OK   matrix/matrix-db" "$T/out"
ok "already archived: no switch" "$(wc -l < "$T/fake/switches" | tr -d ' ')" 0
ok "already archived: no WAL record written" "$(wc -l < "$T/fake/emits" | tr -d ' ')" 0

echo catch-up > "$T/fake/mode"
printf '%s\n' "$OLDWAL" > "$T/fake/archived"
: > "$T/fake/switches"
run_py
ok "switch then archived: exit 0" "$?" 0
has "switch then archived: OK line" "endWal=$ENDWAL" "$T/out"
ok "switch then archived: one switch" "$(wc -l < "$T/fake/switches" | tr -d ' ')" 1

echo idle > "$T/fake/mode"
printf '%s\n' "$OLDWAL" > "$T/fake/archived"
: > "$T/fake/switches"
: > "$T/fake/emits"
: > "$T/fake/calls"
run_py
ok "idle cluster: exit 0 (the switch alone would not archive)" "$?" 0
has "idle cluster: OK line" "OK   matrix/matrix-db endWal=$ENDWAL archived=$ENDWAL" "$T/out"
# the stub shares one archive position: after the first cluster the others are already archived
ok "idle cluster: the first cluster got exactly one WAL record" "$(wc -l < "$T/fake/emits" | tr -d ' ')" 1
first=$(grep -n -m1 -e 'pg_logical_emit_message' "$T/fake/calls" | cut -d: -f1)
sw=$(grep -n -m1 -e 'pg_switch_wal' "$T/fake/calls" | cut -d: -f1)
ok "idle cluster: the record is written before the switch" "$([ -n "$first" ] && [ -n "$sw" ] && [ "$first" -lt "$sw" ] && echo yes || echo no)" yes
has "the record is a logical message, no table" "pg_logical_emit_message(false" "$T/fake/calls"
hasnot "no table is created for it" "CREATE TABLE" "$T/fake/calls"

echo emit-fail > "$T/fake/mode"
printf '%s\n' "$OLDWAL" > "$T/fake/archived"
: > "$T/fake/switches"
run_py
ok "WAL record cannot be written: exit 1" "$?" 1
has "WAL record failure is named" "FAIL matrix/matrix-db cannot write the WAL marker" "$T/out"
ok "WAL record failure: no switch" "$(wc -l < "$T/fake/switches" | tr -d ' ')" 0

echo stuck > "$T/fake/mode"
printf '%s\n' "$OLDWAL" > "$T/fake/archived"
: > "$T/fake/switches"
run_py
ok "archive stays behind: exit 1" "$?" 1
has "archive stays behind: FAIL line" "FAIL matrix/matrix-db" "$T/out"

echo already > "$T/fake/mode"
python3 - "$T/fake/backups.json" << 'PY'
import json, sys
json.dump({"items": []}, open(sys.argv[1], "w"))
PY
run_py
ok "no completed backup: exit 1" "$?" 1
has "no completed backup: FAIL" "FAIL matrix/matrix-db no completed backup" "$T/out"
has "no completed backup names pg-lab too" "FAIL db-lab/pg-lab no completed backup" "$T/out"
has "no completed backup names keycloak-db too" "FAIL keycloak/keycloak-db no completed backup" "$T/out"

echo already > "$T/fake/mode"
printf '%s\n' "$ENDWAL" > "$T/fake/archived"
write_backups "$ENDWAL" matrix,db-lab
run_py
ok "only keycloak-db lacks a backup: exit 1" "$?" 1
has "keycloak-db without a backup is named" "FAIL keycloak/keycloak-db no completed backup" "$T/out"
hasnot "the other clusters stay OK" "FAIL matrix" "$T/out"
write_backups "$ENDWAL"
run_py
ok "keycloak-db with a covered backup: exit 0" "$?" 0
has "keycloak-db is checked like the others" "OK   keycloak/keycloak-db" "$T/out"

echo fail-get > "$T/fake/mode"
run_py
ok "kubectl down: exit 1" "$?" 1
has "kubectl down: FAIL" "FAIL kubectl" "$T/err"

echo already > "$T/fake/mode"
printf '%s\n' "000000010000000000000008" > "$T/fake/archived"
write_backups "$ENDWAL" matrix
run_py --cluster db-lab/pg-lab
ok "filter without a backup: exit 1" "$?" 1
has "filter names the missing backup" "FAIL db-lab/pg-lab no completed backup" "$T/out"
write_backups "$ENDWAL"
run_py --cluster db-lab/pg-lab
ok "filter with a backup: exit 0" "$?" 0
has "filter ok names pg-lab" "OK   db-lab/pg-lab" "$T/out"

run_py --cluster missing/nope
ok "unknown cluster: exit 1" "$?" 1
has "unknown cluster is named" "FAIL missing cluster missing/nope" "$T/out"

ok "down, export, backup and rebuild --restore call the check" "$(grep -c 'phase "WAL archive covers the latest backup" wal_ready' "$R/scripts/lab.sh")" 4
has "no skip switch in the helper" 'wal_ready() {' "$R/scripts/lab.sh"
if grep -n 'wal_ready' "$R/scripts/lab.sh" | grep -E -q -- '--skip|SKIP_WAL|no-wal'; then
  ok "lab.sh has no skip flag for the check" 1 0
else
  ok "lab.sh has no skip flag for the check" 0 0
fi
has "import snapshot waits for the end WAL" 'lab-wal-ready.py' "$R/scripts/gitea-import.sh"
has "docs name the check" 'lab-wal-ready.py' "$R/docs/concepts/backup-and-restore.md"

echo
echo "$n checks, $fail failures"
[ "$fail" = 0 ]
