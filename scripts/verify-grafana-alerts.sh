set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
BASE_URL="${BASE_URL:-http://localhost:8080}"
GRAFANA_URL="${GRAFANA_URL:-http://localhost:3000}"
GRAFANA_AUTH="${GRAFANA_AUTH:-admin:admin}"
WAIT_ATTEMPTS="${WAIT_ATTEMPTS:-90}"
WAIT_SLEEP_SECONDS="${WAIT_SLEEP_SECONDS:-2}"
ALERT_FIRE_ATTEMPTS="${ALERT_FIRE_ATTEMPTS:-90}"
ALERT_RECOVER_ATTEMPTS="${ALERT_RECOVER_ATTEMPTS:-150}"
ALERT_NORMAL_CONSECUTIVE_ATTEMPTS="${ALERT_NORMAL_CONSECUTIVE_ATTEMPTS:-2}"
POST_MITIGATION_SCRAPE_SLEEP_SECONDS="${POST_MITIGATION_SCRAPE_SLEEP_SECONDS:-15}"

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

reload_grafana_alerting() {
  curl -fsS -u "$GRAFANA_AUTH" -X POST "$GRAFANA_URL/api/admin/provisioning/alerting/reload" >/dev/null
}

fetch_alerts() {
  curl -fsS -u "$GRAFANA_AUTH" "$GRAFANA_URL/api/prometheus/grafana/api/v1/alerts"
}

assert_provisioned_alerts() {
  alerts_json="$(mktemp /tmp/sre301-grafana-alerts.XXXXXX.json)"
  fetch_alerts >"$alerts_json"
  if python3 - "$alerts_json" "$@" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
expected = set(sys.argv[2:])
actual = {
    alert["labels"].get("alertname")
    for alert in payload.get("data", {}).get("alerts", [])
}
missing = sorted(expected - actual)
if missing:
    raise SystemExit(f"missing Grafana alerts: {', '.join(missing)}")
PY
  then
    rm -f "$alerts_json"
  else
    status="$?"
    rm -f "$alerts_json"
    return "$status"
  fi
}

alert_state_matches() {
  alert_name="$1"
  expected="$2"
  alerts_json="$(mktemp /tmp/sre301-grafana-alerts.XXXXXX.json)"
  fetch_alerts >"$alerts_json"
  if python3 - "$alerts_json" "$alert_name" "$expected" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
alert_name, expected = sys.argv[2], sys.argv[3]
states = [
    alert.get("state")
    for alert in payload.get("data", {}).get("alerts", [])
    if alert.get("labels", {}).get("alertname") == alert_name
]
if not states:
    raise SystemExit(1)
if expected == "Alerting":
    raise SystemExit(0 if "Alerting" in states else 1)
if expected == "Normal":
    raise SystemExit(0 if all(state == "Normal" for state in states) else 1)
raise SystemExit(f"unsupported expected state: {expected}")
PY
  then
    rm -f "$alerts_json"
  else
    status="$?"
    rm -f "$alerts_json"
    return "$status"
  fi
}

print_alert_states() {
  alerts_json="$(mktemp /tmp/sre301-grafana-alerts.XXXXXX.json)"
  fetch_alerts >"$alerts_json"
  if python3 - "$alerts_json" "$@" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
names = set(sys.argv[2:])
for alert in payload.get("data", {}).get("alerts", []):
    name = alert.get("labels", {}).get("alertname")
    if name in names:
        print(f"{name}: {alert.get('state')}")
PY
  then
    rm -f "$alerts_json"
  else
    status="$?"
    rm -f "$alerts_json"
    return "$status"
  fi
}

wait_alert_state() {
  alert_name="$1"
  expected="$2"
  attempts="$3"
  attempt=1
  consecutive_matches=0
  while [ "$attempt" -le "$attempts" ]; do
    if alert_state_matches "$alert_name" "$expected"; then
      if [ "$expected" = "Normal" ]; then
        consecutive_matches=$((consecutive_matches + 1))
        if [ "$consecutive_matches" -ge "$ALERT_NORMAL_CONSECUTIVE_ATTEMPTS" ]; then
          printf '%s reached %s for %s consecutive checks\n' "$alert_name" "$expected" "$consecutive_matches"
          return 0
        fi
      else
        printf '%s reached %s\n' "$alert_name" "$expected"
        return 0
      fi
    else
      consecutive_matches=0
    fi
    sleep "$WAIT_SLEEP_SECONDS"
    attempt=$((attempt + 1))
  done

  printf 'timed out waiting for %s to reach %s\n' "$alert_name" "$expected" >&2
  print_alert_states "$alert_name" >&2
  return 1
}

wait_all_normal() {
  for alert_name in "$@"; do
    wait_alert_state "$alert_name" Normal "$ALERT_RECOVER_ATTEMPTS"
  done
}

wait_all_alerting() {
  for alert_name in "$@"; do
    wait_alert_state "$alert_name" Alerting "$ALERT_FIRE_ATTEMPTS"
  done
}

reset_facilitator_state() {
  sh "$SCRIPT_DIR/fault-clear.sh"
  wait_http setlog "$BASE_URL/actuator/health"
}

wait_for_post_mitigation_scrape() {
  sleep "$POST_MITIGATION_SCRAPE_SLEEP_SECONDS"
}

mysql_holder_ids() {
  docker compose exec -T mysql mysql -N -uroot -proot -e \
    "SELECT ID FROM information_schema.PROCESSLIST WHERE ID <> CONNECTION_ID() AND INFO LIKE '%SRE301_I1_DB_POOL_HOLDER%';"
}

kill_mysql_holders() {
  ids="$(mysql_holder_ids)"
  if [ -z "$ids" ]; then
    docker compose exec -T mysql mysql -uroot -proot -e "SHOW FULL PROCESSLIST;" >&2 || true
    printf 'no SRE301_I1_DB_POOL_HOLDER sessions found\n' >&2
    return 1
  fi

  for id in $ids; do
    docker compose exec -T mysql mysql -uroot -proot -e "KILL $id;"
  done
}

mitigate_incident_1() {
  kill_mysql_holders
  wait_for_post_mitigation_scrape
}

mitigate_incident_2() {
  docker compose up -d mysql mysqld-exporter
  wait_http setlog "$BASE_URL/actuator/health"
  wait_for_post_mitigation_scrape
}

mitigate_incident_3() {
  docker compose exec -T setlog rm -f /tmp/sre301-render-debug.log
  wait_for_post_mitigation_scrape
}

mitigate_incident_4() {
  docker compose restart setlog
  docker compose restart setlog-netem
  wait_http setlog "$BASE_URL/actuator/health"
  wait_for_post_mitigation_scrape
}

cd "$REPO_ROOT"

wait_http grafana "$GRAFANA_URL/api/health"
reload_grafana_alerting
assert_provisioned_alerts I1\ HighLatency I2\ TooMany5xx I3\ RenderFailuresHigh I4\ RenderLatencyHigh I4\ RenderBacklog
reset_facilitator_state
wait_for_post_mitigation_scrape
wait_all_normal I1\ HighLatency I2\ TooMany5xx I3\ RenderFailuresHigh I4\ RenderLatencyHigh I4\ RenderBacklog

printf 'checking Incident 1 Grafana alert firing and recovery\n'
reset_facilitator_state
sh "$SCRIPT_DIR/incident-1-start.sh"
wait_all_alerting I1\ HighLatency
mitigate_incident_1
wait_all_normal I1\ HighLatency

printf 'checking Incident 2 Grafana alert firing and recovery\n'
reset_facilitator_state
sh "$SCRIPT_DIR/incident-2-start.sh"
wait_all_alerting I2\ TooMany5xx
mitigate_incident_2
wait_all_normal I2\ TooMany5xx

printf 'checking Incident 3 Grafana alert firing and recovery\n'
reset_facilitator_state
sh "$SCRIPT_DIR/incident-3-start.sh"
wait_all_alerting I3\ RenderFailuresHigh
mitigate_incident_3
wait_all_normal I3\ RenderFailuresHigh

printf 'checking Incident 4 Grafana alert firing and recovery\n'
reset_facilitator_state
sh "$SCRIPT_DIR/incident-4-start.sh"
wait_all_alerting I4\ RenderLatencyHigh I4\ RenderBacklog
mitigate_incident_4
wait_all_normal I4\ RenderLatencyHigh I4\ RenderBacklog

reset_facilitator_state
printf 'Grafana alert smoke verification complete\n'
