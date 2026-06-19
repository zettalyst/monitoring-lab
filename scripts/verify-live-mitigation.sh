set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
BASE_URL="${BASE_URL:-http://localhost:8080}"
PROMETHEUS_URL="${PROMETHEUS_URL:-http://localhost:9090}"
WAIT_ATTEMPTS="${WAIT_ATTEMPTS:-90}"
WAIT_SLEEP_SECONDS="${WAIT_SLEEP_SECONDS:-2}"

fail() {
  printf '%s\n' "$*" >&2
  exit 1
}

wait_http() {
  name="$1"
  url="$2"
  attempt=1
  while [ "$attempt" -le "$WAIT_ATTEMPTS" ]; do
    if curl -fsS "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep "$WAIT_SLEEP_SECONDS"
    attempt=$((attempt + 1))
  done

  fail "timed out waiting for $name at $url"
}

wait_stack() {
  wait_http setlog "$BASE_URL/actuator/health"
  wait_http prometheus "$PROMETHEUS_URL/-/ready"
}

reset_lab() {
  sh "$SCRIPT_DIR/fault-clear.sh"
  wait_stack
}

fault_status() {
  curl -fsS "$BASE_URL/internal/faults"
}

assert_fault_field() {
  field="$1"
  expected="$2"
  status="$(fault_status)"
  printf '%s\n' "$status" | grep "\"$field\":$expected" >/dev/null || {
    printf 'unexpected fault status while checking %s=%s:\n%s\n' "$field" "$expected" "$status" >&2
    return 1
  }
}

wait_fault_field() {
  field="$1"
  expected="$2"
  attempt=1
  while [ "$attempt" -le "$WAIT_ATTEMPTS" ]; do
    if assert_fault_field "$field" "$expected" >/dev/null 2>&1; then
      return 0
    fi
    sleep "$WAIT_SLEEP_SECONDS"
    attempt=$((attempt + 1))
  done
  assert_fault_field "$field" "$expected"
}

mysql_holder_ids() {
  docker compose exec -T mysql mysql -N -uroot -proot -e \
    "SELECT ID FROM information_schema.PROCESSLIST WHERE ID <> CONNECTION_ID() AND INFO LIKE '%SRE301_I1_DB_POOL_HOLDER%';"
}

kill_mysql_holders() {
  ids="$(mysql_holder_ids)"
  if [ -z "$ids" ]; then
    docker compose exec -T mysql mysql -uroot -proot -e "SHOW FULL PROCESSLIST;" >&2 || true
    fail "no SRE301_I1_DB_POOL_HOLDER sessions found"
  fi

  for id in $ids; do
    docker compose exec -T mysql mysql -uroot -proot -e "KILL $id;"
  done
}

verify_baseline_restart_preserves_faults() {
  printf 'checking baseline-traffic restart preserves app faults by default\n'
  reset_lab
  sh "$SCRIPT_DIR/fault-latency.sh" >/dev/null
  wait_fault_field dbPoolActive true

  docker compose restart baseline-traffic >/dev/null
  sleep 5
  assert_fault_field dbPoolActive true

  printf 'checking baseline-traffic opt-in clear still clears app faults\n'
  BASELINE_CLEAR_FAULTS_ON_START=1 docker compose up -d --force-recreate baseline-traffic >/dev/null
  wait_fault_field dbPoolActive false
  docker compose up -d --force-recreate baseline-traffic >/dev/null
  reset_lab
}

verify_incident_1() {
  printf 'checking Incident 1 SQL KILL mitigation\n'
  reset_lab
  sh "$SCRIPT_DIR/incident-1-start.sh"
  wait_fault_field dbPoolActive true
  kill_mysql_holders
  wait_fault_field dbPoolActive false
  reset_lab
}

verify_incident_2() {
  printf 'checking Incident 2 dependency restart mitigation\n'
  reset_lab
  sh "$SCRIPT_DIR/incident-2-start.sh"
  docker compose up -d mysql mysqld-exporter >/dev/null
  wait_http setlog "$BASE_URL/actuator/health"
  reset_lab
}

verify_incident_3() {
  printf 'checking Incident 3 debug log removal mitigation\n'
  reset_lab
  sh "$SCRIPT_DIR/incident-3-start.sh"
  docker compose exec -T setlog sh -c 'test -e /tmp/sre301-render-debug.log'
  docker compose exec -T setlog rm -f /tmp/sre301-render-debug.log
  docker compose exec -T setlog sh -c 'test ! -e /tmp/sre301-render-debug.log'
  reset_lab
}

verify_incident_4() {
  printf 'checking Incident 4 setlog restart mitigation\n'
  reset_lab
  sh "$SCRIPT_DIR/incident-4-start.sh"
  assert_fault_field cpuActive true
  docker compose restart setlog >/dev/null
  docker compose restart setlog-netem >/dev/null
  wait_http setlog "$BASE_URL/actuator/health"
  wait_fault_field cpuActive false
  reset_lab
}

cd "$REPO_ROOT"

printf 'starting SRE301 stack for live mitigation verification\n'
docker compose up --build -d
wait_stack

verify_baseline_restart_preserves_faults
verify_incident_1
verify_incident_2
verify_incident_3
verify_incident_4

printf 'live mitigation verification complete\n'
