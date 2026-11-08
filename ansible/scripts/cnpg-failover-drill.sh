#!/usr/bin/env bash
# Failover drill for the CNPG cluster pg-lab (stage 8b), only with kubectl.
#
# Flow: create test table, a writer pod writes one row every 0.2 s
# via the pooler (like an app), after DRILL_KILL_AFTER seconds
# the primary pod is deleted. Afterwards: downtime (last OK before the first
# error to first OK after the last error), longest gap between two
# OK (the pooler holds requests during the switch: then there are no
# errors, but a long gap), number of failed attempts, new primary and
# "confirmed but lost" (asynchronous replication: what the old primary
# had confirmed but not yet passed on).
# Cleanup (also on abort): writer pod and test table gone.
#
# Call from the repo (kubeconfig as usual for kubectl):
#   ansible/scripts/cnpg-failover-drill.sh
# Optional: DRILL_SECONDS=60 (length of the write loop),
#           DRILL_KILL_AFTER=15 (seconds until the primary is deleted),
#           DRILL_HARD=1 (kill the primary at once instead of stopping it gracefully,
#           like a crash; without: CNPG does a graceful switchover).
# The script reads the names (namespace, cluster, pooler, database) from
# gitops/workloads/db-lab/ (single place). It never sees passwords: the
# writer pod reads them itself from the secret <cluster>-app.
set -euo pipefail

DRILL_SECONDS=${DRILL_SECONDS:-60}
DRILL_KILL_AFTER=${DRILL_KILL_AFTER:-15}
DRILL_HARD=${DRILL_HARD:-0}
case "$DRILL_SECONDS$DRILL_KILL_AFTER$DRILL_HARD" in
  *[!0-9]*) echo "ABORT: DRILL_SECONDS, DRILL_KILL_AFTER and DRILL_HARD must be numbers" >&2; exit 1 ;;
esac
if [ "$DRILL_KILL_AFTER" -ge "$DRILL_SECONDS" ]; then
  echo "ABORT: DRILL_KILL_AFTER must be smaller than DRILL_SECONDS" >&2
  exit 1
fi

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
repo=$(git -C "$here" rev-parse --show-toplevel)
wl=$repo/gitops/workloads/db-lab

# Value of a key under metadata: (indented by 2 spaces).
meta() {
  awk -v k="$2" '/^metadata:/ {m = 1; next} /^[^ #]/ {m = 0} m && $1 == k ":" {print $2; exit}' "$1"
}
NS=$(meta "$wl/cluster.yaml" namespace)
CL=$(meta "$wl/cluster.yaml" name)
POOLER=$(meta "$wl/pooler.yaml" name)
DB=$(awk '$1 == "database:" {print $2; exit}' "$wl/cluster.yaml")
OWNER=$(awk '$1 == "owner:" {print $2; exit}' "$wl/cluster.yaml")
for v in NS CL POOLER DB OWNER; do
  if [ -z "${!v}" ]; then
    echo "ABORT: $v not read from $wl" >&2
    exit 1
  fi
done

POD=cnpg-drill
TABLE=drill_failover
K=(kubectl -n "$NS")
tmp=$(mktemp -d)

primary() { "${K[@]}" get cluster "$CL" -o jsonpath='{.status.currentPrimary}'; }
psql_primary() {
  "${K[@]}" exec "$(primary)" -c postgres -- psql -XAtq -v ON_ERROR_STOP=1 -d "$DB" -c "$1"
}
healthy() {
  [ "$("${K[@]}" get cluster "$CL" -o jsonpath='{.status.phase}')" = "Cluster in healthy state" ] &&
    [ "$("${K[@]}" get cluster "$CL" -o jsonpath='{.status.readyInstances}')" = "$("${K[@]}" get cluster "$CL" -o jsonpath='{.spec.instances}')" ]
}
wait_healthy() {
  local _
  for _ in $(seq 1 60); do
    if healthy; then return 0; fi
    sleep 5
  done
  return 1
}
cleanup() {
  set +e
  "${K[@]}" delete pod "$POD" --ignore-not-found --wait=false >/dev/null 2>&1
  if wait_healthy; then
    psql_primary "DROP TABLE IF EXISTS $TABLE" >/dev/null 2>&1
  else
    echo "WARNING: cluster not healthy, table $TABLE stays (later: DROP TABLE $TABLE)" >&2
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT

echo "== Failover drill: cluster $NS/$CL, Pooler $POOLER, ${DRILL_SECONDS}s, primary killed after ${DRILL_KILL_AFTER}s"
if ! healthy; then
  echo "ABORT: cluster $NS/$CL is not healthy (kubectl -n $NS get cluster $CL)" >&2
  exit 1
fi
IMG=$("${K[@]}" get cluster "$CL" -o jsonpath='{.spec.imageName}')
OLD=$(primary)
echo "Primary before: $OLD"

psql_primary "DROP TABLE IF EXISTS $TABLE; CREATE TABLE $TABLE (id bigserial PRIMARY KEY, tag text NOT NULL UNIQUE, ts timestamptz NOT NULL DEFAULT clock_timestamp()); ALTER TABLE $TABLE OWNER TO $OWNER" >/dev/null

"${K[@]}" delete pod "$POD" --ignore-not-found --wait=true >/dev/null
subst=(-e "s|__POD__|$POD|" -e "s|__NS__|$NS|" -e "s|__IMG__|$IMG|" -e "s|__POOLER__|$POOLER|")
subst+=(-e "s|__SECRET__|$CL-app|g" -e "s|__SECS__|$DRILL_SECONDS|" -e "s|__TABLE__|$TABLE|")
sed "${subst[@]}" > "$tmp/pod.yaml" <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: __POD__
  namespace: __NS__
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 26
    runAsGroup: 26
    seccompProfile:
      type: RuntimeDefault
  # New pod: kube-router does not know it yet in the first second,
  # default-deny rejects. So first wait for the pooler,
  # otherwise the measurement counts false errors.
  initContainers:
    - name: wait
      image: __IMG__
      env:
        - {name: PGHOST, value: __POOLER__}
      command: [sh, -c, "for i in $(seq 1 30); do pg_isready -q -t 2 && exit 0; sleep 2; done; exit 1"]
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: [ALL]
      resources:
        requests: {cpu: 10m, memory: 32Mi}
        limits: {memory: 128Mi}
  containers:
    - name: writer
      image: __IMG__
      env:
        - {name: PGHOST, value: __POOLER__}
        - {name: PGSSLMODE, value: require}
        - {name: PGCONNECT_TIMEOUT, value: "2"}
        - {name: SECS, value: "__SECS__"}
        - {name: TABLE, value: __TABLE__}
        - name: PGDATABASE
          valueFrom: {secretKeyRef: {name: __SECRET__, key: dbname}}
        - name: PGUSER
          valueFrom: {secretKeyRef: {name: __SECRET__, key: username}}
        - name: PGPASSWORD
          valueFrom: {secretKeyRef: {name: __SECRET__, key: password}}
      command: [bash, -c]
      args:
        - |
          end=$(( $(date +%s) + SECS ))
          i=0
          while [ "$(date +%s)" -lt "$end" ]; do
            i=$((i + 1))
            if timeout 3 psql -XAtq -v ON_ERROR_STOP=1 -c "INSERT INTO $TABLE (tag) VALUES ('w$i')" >/dev/null 2>&1; then
              echo "OK $(date +%s%3N) w$i"
            else
              echo "FAIL $(date +%s%3N) w$i"
            fi
            sleep 0.2
          done
          echo END
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: [ALL]
      resources:
        requests: {cpu: 10m, memory: 32Mi}
        limits: {memory: 128Mi}
YAML
"${K[@]}" apply -f "$tmp/pod.yaml" >/dev/null
"${K[@]}" wait --for=condition=Ready "pod/$POD" --timeout=120s >/dev/null
echo "Writer pod running, waiting ${DRILL_KILL_AFTER}s ..."
sleep "$DRILL_KILL_AFTER"

KILL_MS=$(date +%s%3N)
if [ "$DRILL_HARD" = 1 ]; then
  echo "$(date '+%H:%M:%S') Primary $OLD is deleted hard (like a crash)"
  "${K[@]}" delete pod "$OLD" --grace-period=0 --force --wait=false >/dev/null 2>&1
else
  echo "$(date '+%H:%M:%S') Primary $OLD is deleted (graceful)"
  "${K[@]}" delete pod "$OLD" --wait=false >/dev/null
fi

"${K[@]}" wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$POD" --timeout="$((DRILL_SECONDS + 120))s" >/dev/null
"${K[@]}" logs "$POD" > "$tmp/log"
if ! grep -qx END "$tmp/log"; then
  echo "ABORT: writer pod without END (log incomplete)" >&2
  exit 1
fi

echo "Waiting until the cluster is healthy again (old primary comes back as replica) ..."
if ! wait_healthy; then
  echo "ERROR: cluster not healthy after 5 minutes" >&2
  exit 1
fi
NEW=$(primary)

ok=$(grep -c '^OK ' "$tmp/log" || true)
fail=$(grep -c '^FAIL ' "$tmp/log" || true)
# Downtime: last OK before the first FAIL to first OK after the last FAIL.
read -r down first_fail last_fail < <(awk -v kill="$KILL_MS" '
  {st[NR] = $1; t[NR] = $2}
  $1 == "FAIL" {if (!ff) ff = $2; lf = $2}
  END {
    if (!ff) {print 0, "-", "-"; exit}
    lastok = kill; back = lf
    for (i = 1; i <= NR; i++) if (st[i] == "OK" && t[i] < ff) lastok = t[i]
    for (i = NR; i >= 1; i--) if (st[i] == "OK" && t[i] > lf) back = t[i]
    print back - lastok, ff, lf
  }' "$tmp/log")

# Longest gap between two consecutive OK (ms).
gap=$(awk '$1 == "OK" {if (prev) {d = $2 - prev; if (d > m) m = d} prev = $2} END {print m + 0}' "$tmp/log")

# Confirmed (OK in the log), but not in the table of the new primary.
grep '^OK ' "$tmp/log" | awk '{print $3}' | sort > "$tmp/acked"
psql_primary "SELECT tag FROM $TABLE" | sort > "$tmp/rows"
lost=$(comm -23 "$tmp/acked" "$tmp/rows" | wc -l)
rows=$(wc -l < "$tmp/rows")

echo
echo "== Result"
echo "Primary before/after  : $OLD -> $NEW"
echo "Write attempts          : $((ok + fail)) (OK $ok, FAIL $fail)"
echo "Downtime              : ${down} ms (last OK before the outage to first OK after)"
echo "Longest gap          : ${gap} ms between two OK (normal ~250 ms; also shows wait time in the pooler)"
echo "Rows in the table     : $rows"
echo "Confirmed but lost   : $lost (asynchronous replication; mostly 0 in the lab)"
if [ "$OLD" = "$NEW" ]; then
  echo "NOTE: primary unchanged (pod came back faster than the failover?)"
fi
if [ "$first_fail" != "-" ]; then
  echo "Errors from/to (ms)  : $first_fail .. $last_fail, kill at $KILL_MS"
fi
