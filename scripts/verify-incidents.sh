set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
BASE_URL="${BASE_URL:-http://localhost:8080}"
PROMETHEUS_URL="${PROMETHEUS_URL:-http://localhost:9090}"
WAIT_ATTEMPTS="${WAIT_ATTEMPTS:-90}"
WAIT_SLEEP_SECONDS="${WAIT_SLEEP_SECONDS:-2}"

. "$SCRIPT_DIR/incident-common.sh"

API_TRAFFIC_RATE_QUERY='sum(rate(http_server_requests_seconds_count{job="setlog", uri=~"/api/.*"}[1m])) or vector(0)'
I1_API_P95_QUERY='max(histogram_quantile(0.95, sum(rate(http_server_requests_seconds_bucket{job="setlog", uri=~"/api/.*", status!~"5.."}[2m])) by (le, method, uri))) or vector(0)'
I1_DB_PENDING_QUERY='max_over_time(hikaricp_connections_pending{job="setlog"}[2m]) or vector(0)'
I2_5XX_RATIO_QUERY='(sum(rate(http_server_requests_seconds_count{job="setlog", uri=~"/api/.*", status=~"5.."}[2m])) or vector(0)) / clamp_min((sum(rate(http_server_requests_seconds_count{job="setlog", uri=~"/api/.*"}[2m])) or vector(0)), 0.001)'
I2_MYSQL_EXPORTER_UP_QUERY='up{job="mysqld-exporter"} or vector(0)'
I3_RENDER_FAILURE_RATIO_QUERY='(sum(rate(setlog_vlog_render_jobs_total{job="setlog", result="failure", reason="disk"}[2m])) or vector(0)) / clamp_min((sum(rate(setlog_vlog_render_jobs_total{job="setlog"}[2m])) or vector(0)), 0.001)'
I3_DEBUG_LOG_BYTES_QUERY='max(setlog_render_debug_log_bytes{job="setlog"}) or vector(0)'
I4_RENDER_P95_QUERY='histogram_quantile(0.95, sum(rate(http_server_requests_seconds_bucket{job="setlog", uri="/api/render-jobs"}[2m])) by (le)) or vector(0)'
I4_RENDER_QUEUE_QUERY='max_over_time(setlog_vlog_render_queue_depth{job="setlog"}[2m]) or vector(0)'

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

wait_metric_ge() {
  name="$1"
  query="$2"
  threshold="$3"
  attempt=1
  while [ "$attempt" -le "$WAIT_ATTEMPTS" ]; do
    value="$(incident_query_number "$name" "$query")"
    if incident_number_ge "$value" "$threshold"; then
      printf '%s reached %s (threshold >= %s)\n' "$name" "$value" "$threshold"
      return 0
    fi
    sleep "$WAIT_SLEEP_SECONDS"
    attempt=$((attempt + 1))
  done

  value="$(incident_query_number "$name" "$query")"
  printf 'timed out waiting for %s >= %s; last value=%s\nquery: %s\n' "$name" "$threshold" "$value" "$query" >&2
  return 1
}

wait_metric_eq() {
  name="$1"
  query="$2"
  expected="$3"
  attempt=1
  while [ "$attempt" -le "$WAIT_ATTEMPTS" ]; do
    value="$(incident_query_number "$name" "$query")"
    if incident_number_eq "$value" "$expected"; then
      printf '%s reached %s\n' "$name" "$expected"
      return 0
    fi
    sleep "$WAIT_SLEEP_SECONDS"
    attempt=$((attempt + 1))
  done

  value="$(incident_query_number "$name" "$query")"
  printf 'timed out waiting for %s == %s; last value=%s\nquery: %s\n' "$name" "$expected" "$value" "$query" >&2
  return 1
}

wait_stack() {
  wait_http setlog "$BASE_URL/actuator/health"
  wait_http prometheus "$PROMETHEUS_URL/-/ready"
  wait_metric_ge apiTraffic "$API_TRAFFIC_RATE_QUERY" 0.1
}

reset_lab() {
  sh "$SCRIPT_DIR/fault-clear.sh"
  wait_stack
}

cd "$REPO_ROOT"

printf 'starting SetLog stack\n'
docker compose up --build -d
wait_stack

printf 'running Incident 1 smoke\n'
reset_lab
sh "$SCRIPT_DIR/incident-1-start.sh"
wait_metric_ge i1ApiP95 "$I1_API_P95_QUERY" 0.8
wait_metric_ge i1DbPending "$I1_DB_PENDING_QUERY" 1

printf 'running Incident 2 smoke\n'
reset_lab
sh "$SCRIPT_DIR/incident-2-start.sh"
wait_metric_ge i2ErrorRatio "$I2_5XX_RATIO_QUERY" 0.05
wait_metric_eq i2MysqlExporterUp "$I2_MYSQL_EXPORTER_UP_QUERY" 0

printf 'running Incident 3 smoke\n'
reset_lab
sh "$SCRIPT_DIR/incident-3-start.sh"
wait_metric_ge i3DebugLogBytes "$I3_DEBUG_LOG_BYTES_QUERY" 1
wait_metric_ge i3RenderFailureRatio "$I3_RENDER_FAILURE_RATIO_QUERY" 0.2

printf 'running Incident 4 smoke\n'
reset_lab
sh "$SCRIPT_DIR/incident-4-start.sh"
wait_metric_ge i4RenderP95 "$I4_RENDER_P95_QUERY" 2
wait_metric_ge i4RenderQueue "$I4_RENDER_QUEUE_QUERY" 1

reset_lab
printf 'incident smoke verification complete\n'
