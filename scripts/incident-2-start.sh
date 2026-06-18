set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/incident-common.sh"

BASELINE_COUNT="${BASELINE_COUNT:-20}"
INCIDENT_COUNT="${INCIDENT_COUNT:-30}"
INCIDENT_SLEEP_SECONDS="${INCIDENT_SLEEP_SECONDS:-0.2}"

API_TOTAL_QUERY='sum(http_server_requests_seconds_count{job="setlog", uri=~"/api/.*"}) or vector(0)'
API_5XX_QUERY='sum(http_server_requests_seconds_count{job="setlog", uri=~"/api/.*", status=~"5.."}) or vector(0)'
CLIP_FAILURE_QUERY='sum(setlog_clip_uploads_total{job="setlog", result="failure"}) or vector(0)'
MYSQL_EXPORTER_UP_MIN_QUERY="min_over_time(up{job=\"mysqld-exporter\"}[$INCIDENT_VALIDATION_WINDOW])"
SETLOG_UP_QUERY='min(up{job="setlog"})'

validate_incident_2() {
  incident_wait_for_scrape

  api_total_after="$(incident_query_number api_total "$API_TOTAL_QUERY")"
  api_5xx_after="$(incident_query_number api_5xx "$API_5XX_QUERY")"
  clip_failure_after="$(incident_query_number clip_failure_total "$CLIP_FAILURE_QUERY")"
  api_total_delta="$(incident_math_max_zero "$(incident_math_subtract "$api_total_after" "$api_total_before")")"
  api_5xx_delta="$(incident_math_max_zero "$(incident_math_subtract "$api_5xx_after" "$api_5xx_before")")"
  clip_failure_delta="$(incident_math_max_zero "$(incident_math_subtract "$clip_failure_after" "$clip_failure_before")")"
  error_ratio="$(incident_math_divide "$api_5xx_delta" "$api_total_delta")"
  mysql_exporter_up_min="$(incident_query_number mysql_exporter_up_min "$MYSQL_EXPORTER_UP_MIN_QUERY")"
  setlog_up="$(incident_query_number setlog_up "$SETLOG_UP_QUERY")"

  incident_assert_ge errorRatio "$error_ratio" 0.05
  incident_assert_gt clipFailureDelta "$clip_failure_delta" 0
  incident_assert_eq mysqlExporterUpMin "$mysql_exporter_up_min" 0
  incident_assert_eq setlogUp "$setlog_up" 1

  printf '{"incident":2,"passed":true,"errorRatio":%s,"clipFailureDelta":%s,"mysqlExporterUpMin":%s,"setlogUp":%s}\n' \
    "$error_ratio" "$clip_failure_delta" "$mysql_exporter_up_min" "$setlog_up"
}

printf 'preparing Incident 2 with baseline SetLog traffic\n'
COUNT="$BASELINE_COUNT" sh "$SCRIPT_DIR/baseline-traffic.sh"

if incident_validation_enabled; then
  api_total_before="$(incident_query_number api_total_before "$API_TOTAL_QUERY")"
  api_5xx_before="$(incident_query_number api_5xx_before "$API_5XX_QUERY")"
  clip_failure_before="$(incident_query_number clip_failure_before "$CLIP_FAILURE_QUERY")"
else
  api_total_before=0
  api_5xx_before=0
  clip_failure_before=0
fi

printf 'starting Incident 2: error increase drill\n'
sh "$SCRIPT_DIR/fault-errors.sh"

printf 'generating bounded failing traffic while Incident 2 is active\n'
ALLOW_FAILURES=1 COUNT="$INCIDENT_COUNT" SLEEP_SECONDS="$INCIDENT_SLEEP_SECONDS" sh "$SCRIPT_DIR/baseline-traffic.sh"

printf 'Incident 2 is active. Open Grafana and complete the incident table.\n'
if incident_validation_enabled; then
  validate_incident_2
else
  incident_print_validation_disabled_summary 2
fi
