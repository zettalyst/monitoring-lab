set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/incident-common.sh"

BASELINE_COUNT="${BASELINE_COUNT:-20}"
INCIDENT_COUNT="${INCIDENT_COUNT:-90}"
INCIDENT_SLEEP_SECONDS="${INCIDENT_SLEEP_SECONDS:-0.7}"

RENDER_TOTAL_QUERY='sum(setlog_vlog_render_jobs_total{job="setlog"}) or vector(0)'
RENDER_DISK_FAILURE_QUERY='sum(setlog_vlog_render_jobs_total{job="setlog", result="failure", reason="disk"}) or vector(0)'
DEBUG_LOG_BYTES_QUERY='max(setlog_render_debug_log_bytes{job="setlog"}) or vector(0)'

validate_incident_3() {
  incident_wait_for_scrape

  render_total_after="$(incident_query_number render_total "$RENDER_TOTAL_QUERY")"
  render_disk_failure_after="$(incident_query_number render_disk_failure_total "$RENDER_DISK_FAILURE_QUERY")"
  render_total_delta="$(incident_math_max_zero "$(incident_math_subtract "$render_total_after" "$render_total_before")")"
  render_disk_failure_delta="$(incident_math_max_zero "$(incident_math_subtract "$render_disk_failure_after" "$render_disk_failure_before")")"
  render_disk_failure_ratio="$(incident_math_divide "$render_disk_failure_delta" "$render_total_delta")"
  debug_log_bytes="$(incident_query_number debug_log_bytes "$DEBUG_LOG_BYTES_QUERY")"

  incident_assert_ge renderDiskFailureRatio "$render_disk_failure_ratio" 0.2
  incident_assert_gt renderDiskFailureDelta "$render_disk_failure_delta" 0
  incident_assert_gt debugLogBytes "$debug_log_bytes" 0

  printf '{"incident":3,"passed":true,"renderDiskFailureRatio":%s,"renderDiskFailureDelta":%s,"debugLogBytes":%s}\n' \
    "$render_disk_failure_ratio" "$render_disk_failure_delta" "$debug_log_bytes"
}

printf 'preparing Incident 3 with baseline SetLog traffic\n'
COUNT="$BASELINE_COUNT" sh "$SCRIPT_DIR/baseline-traffic.sh"

if incident_validation_enabled; then
  render_total_before="$(incident_query_number render_total_before "$RENDER_TOTAL_QUERY")"
  render_disk_failure_before="$(incident_query_number render_disk_failure_before "$RENDER_DISK_FAILURE_QUERY")"
else
  render_total_before=0
  render_disk_failure_before=0
fi

printf 'starting Incident 3: disk pressure drill\n'
sh "$SCRIPT_DIR/fault-disk.sh"

printf 'generating bounded render traffic while Incident 3 is active\n'
COUNT="$INCIDENT_COUNT" SLEEP_SECONDS="$INCIDENT_SLEEP_SECONDS" RENDER_EVERY=1 ALLOW_FAILURES=1 sh "$SCRIPT_DIR/baseline-traffic.sh"

printf 'Incident 3 is active. Open Grafana and complete the incident table.\n'
if incident_validation_enabled; then
  validate_incident_3
else
  incident_print_validation_disabled_summary 3
fi
