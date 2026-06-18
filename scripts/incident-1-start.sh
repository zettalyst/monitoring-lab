set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/incident-common.sh"

BASE_URL="${BASE_URL:-http://localhost:8080}"
BASELINE_COUNT="${BASELINE_COUNT:-20}"
INCIDENT_COUNT="${INCIDENT_COUNT:-45}"
INCIDENT_SLEEP_SECONDS="${INCIDENT_SLEEP_SECONDS:-0.05}"
INCIDENT_CONCURRENCY="${INCIDENT_CONCURRENCY:-2}"
DB_POOL_PROBE_CONCURRENCY="${DB_POOL_PROBE_CONCURRENCY:-2}"
INCIDENT_MAX_CONCURRENCY="${INCIDENT_MAX_CONCURRENCY:-8}"
DB_POOL_PROBE_WAVES="${DB_POOL_PROBE_WAVES:-12}"
DB_POOL_PROBE_SLEEP_SECONDS="${DB_POOL_PROBE_SLEEP_SECONDS:-0.2}"

API_TOTAL_QUERY='sum(http_server_requests_seconds_count{job="setlog", uri=~"/api/.*"}) or vector(0)'
API_5XX_QUERY='sum(http_server_requests_seconds_count{job="setlog", uri=~"/api/.*", status=~"5.."}) or vector(0)'
API_P95_QUERY="max(histogram_quantile(0.95, sum(rate(http_server_requests_seconds_bucket{job=\"setlog\", uri=~\"/api/.*\", status!~\"5..\"}[$INCIDENT_VALIDATION_WINDOW])) by (le, method, uri)))"
DB_PENDING_MAX_QUERY="max_over_time(hikaricp_connections_pending{job=\"setlog\"}[$INCIDENT_VALIDATION_WINDOW])"

run_concurrent_incident_traffic() {
  pids=""
  failures=0
  worker=1
  while [ "$worker" -le "$INCIDENT_CONCURRENCY" ]; do
    COUNT="$INCIDENT_COUNT" SLEEP_SECONDS="$INCIDENT_SLEEP_SECONDS" sh "$SCRIPT_DIR/baseline-traffic.sh" &
    pids="$pids $!"
    worker=$((worker + 1))
  done

  for pid in $pids; do
    if ! wait "$pid"; then
      failures=1
    fi
  done

  return "$failures"
}

run_db_pool_probe_traffic() {
  probe_concurrency="$1"
  wave=1
  failures=0
  while [ "$wave" -le "$DB_POOL_PROBE_WAVES" ]; do
    pids=""
    request=1
    while [ "$request" -le "$probe_concurrency" ]; do
      curl -fsS "$BASE_URL/api/feed" >/dev/null &
      pids="$pids $!"
      request=$((request + 1))
    done

    for pid in $pids; do
      if ! wait "$pid"; then
        failures=1
      fi
    done

    sleep "$DB_POOL_PROBE_SLEEP_SECONDS"
    wave=$((wave + 1))
  done

  return "$failures"
}

collect_incident_1_metrics() {
  api_total_after="$(incident_query_number api_total "$API_TOTAL_QUERY")"
  api_5xx_after="$(incident_query_number api_5xx "$API_5XX_QUERY")"
  api_total_delta="$(incident_math_max_zero "$(incident_math_subtract "$api_total_after" "$api_total_before")")"
  api_5xx_delta="$(incident_math_max_zero "$(incident_math_subtract "$api_5xx_after" "$api_5xx_before")")"
  error_ratio="$(incident_math_divide "$api_5xx_delta" "$api_total_delta")"
  api_p95="$(incident_query_number api_p95 "$API_P95_QUERY")"
  db_pending_max="$(incident_query_number db_pending_max "$DB_PENDING_MAX_QUERY")"
}

validate_incident_1() {
  chosen_concurrency="$1"
  collect_incident_1_metrics

  incident_assert_ge apiP95 "$api_p95" 0.8
  incident_assert_ge dbPendingMax "$db_pending_max" 1
  incident_assert_le errorRatio "$error_ratio" 0.01

  printf '{"incident":1,"passed":true,"apiP95":%s,"dbPendingMax":%s,"errorRatio":%s,"chosenConcurrency":%s}\n' \
    "$api_p95" "$db_pending_max" "$error_ratio" "$chosen_concurrency"
}

run_adaptive_db_pool_probe() {
  if ! incident_auto_tune_enabled; then
    printf 'INCIDENT_AUTO_TUNE is disabled; using DB pool probe concurrency %s\n' "$DB_POOL_PROBE_CONCURRENCY" >&2
    if ! run_db_pool_probe_traffic "$DB_POOL_PROBE_CONCURRENCY"; then
      printf 'DB pool probe too aggressive at concurrency %s: one or more requests returned an error\n' "$DB_POOL_PROBE_CONCURRENCY" >&2
      return 1
    fi
    incident_wait_for_scrape
    printf '%s\n' "$DB_POOL_PROBE_CONCURRENCY"
    return 0
  fi

  concurrency="$DB_POOL_PROBE_CONCURRENCY"
  while [ "$concurrency" -le "$INCIDENT_MAX_CONCURRENCY" ]; do
    printf 'probing DB pool contention with concurrency %s\n' "$concurrency" >&2
    if ! run_db_pool_probe_traffic "$concurrency"; then
      printf 'DB pool probe too aggressive at concurrency %s: one or more requests returned an error\n' "$concurrency" >&2
      return 1
    fi

    incident_wait_for_scrape
    collect_incident_1_metrics
    printf 'observed dbPendingMax=%s apiP95=%s errorRatio=%s at DB probe concurrency %s\n' \
      "$db_pending_max" "$api_p95" "$error_ratio" "$concurrency" >&2

    if incident_number_gt "$error_ratio" 0.01; then
      printf 'DB pool probe too aggressive at concurrency %s: errorRatio=%s exceeded 0.01\n' "$concurrency" "$error_ratio" >&2
      return 1
    fi

    if incident_number_ge "$db_pending_max" 1; then
      printf '%s\n' "$concurrency"
      return 0
    fi

    concurrency=$((concurrency + 1))
  done

  printf 'DB pool pending did not reach 1 up to INCIDENT_MAX_CONCURRENCY=%s; try increasing DB_POOL_HOLDERS or INCIDENT_MAX_CONCURRENCY\n' "$INCIDENT_MAX_CONCURRENCY" >&2
  return 1
}

printf 'preparing Incident 1 with baseline SetLog traffic\n'
COUNT="$BASELINE_COUNT" sh "$SCRIPT_DIR/baseline-traffic.sh"

if incident_validation_enabled || incident_auto_tune_enabled; then
  api_total_before="$(incident_query_number api_total_before "$API_TOTAL_QUERY")"
  api_5xx_before="$(incident_query_number api_5xx_before "$API_5XX_QUERY")"
else
  api_total_before=0
  api_5xx_before=0
fi

printf 'starting Incident 1: DB pool latency drill\n'
sh "$SCRIPT_DIR/fault-latency.sh"

printf 'generating bounded concurrent traffic while Incident 1 is active\n'
run_concurrent_incident_traffic

printf 'generating DB pool diagnostic probe traffic while Incident 1 is active\n'
chosen_concurrency="$(run_adaptive_db_pool_probe)"

printf 'Incident 1 is active. Open Grafana and complete the incident table.\n'
if incident_validation_enabled; then
  validate_incident_1 "$chosen_concurrency"
else
  printf '{"incident":1,"passed":true,"validationSkipped":true,"chosenConcurrency":%s}\n' "$chosen_concurrency"
fi
