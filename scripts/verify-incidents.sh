set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
BASE_URL="${BASE_URL:-http://localhost:8080}"
PROMETHEUS_URL="${PROMETHEUS_URL:-http://localhost:9090}"
WAIT_ATTEMPTS="${WAIT_ATTEMPTS:-60}"
WAIT_SLEEP_SECONDS="${WAIT_SLEEP_SECONDS:-2}"

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

  printf 'timed out waiting for %s at %s\n' "$name" "$url" >&2
  return 1
}

wait_stack() {
  wait_http setlog "$BASE_URL/actuator/health"
  wait_http prometheus "$PROMETHEUS_URL/-/ready"
  sleep 10
}

reset_lab() {
  sh "$SCRIPT_DIR/fault-clear.sh"
  wait_stack
}

cd "$REPO_ROOT"

printf 'starting SRE301 stack\n'
docker compose up --build -d
wait_stack

printf 'running Incident 1 smoke\n'
INCIDENT_VALIDATE=1 sh "$SCRIPT_DIR/incident-1-start.sh"
reset_lab

printf 'running Incident 2 smoke\n'
INCIDENT_VALIDATE=1 sh "$SCRIPT_DIR/incident-2-start.sh"
reset_lab

printf 'running Incident 3 smoke\n'
INCIDENT_VALIDATE=1 sh "$SCRIPT_DIR/incident-3-start.sh"
reset_lab

printf 'running Incident 4 smoke\n'
INCIDENT_VALIDATE=1 sh "$SCRIPT_DIR/incident-4-start.sh"
reset_lab

printf 'incident smoke verification complete\n'
