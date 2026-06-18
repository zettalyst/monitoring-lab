set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/incident-common.sh"

BASELINE_COUNT="${BASELINE_COUNT:-20}"
INCIDENT_COUNT="${INCIDENT_COUNT:-12}"
INCIDENT_SLEEP_SECONDS="${INCIDENT_SLEEP_SECONDS:-0.05}"
INCIDENT_CONCURRENCY="${INCIDENT_CONCURRENCY:-3}"
CPU_WORKERS_EXPLICIT=0
if [ "${CPU_WORKERS+x}" = x ]; then
  CPU_WORKERS_EXPLICIT=1
fi
CPU_WORKERS="${CPU_WORKERS:-4}"
INCIDENT_MAX_CPU_WORKERS="${INCIDENT_MAX_CPU_WORKERS:-4}"

RENDER_P95_QUERY="histogram_quantile(0.95, sum(rate(http_server_requests_seconds_bucket{job=\"setlog\", uri=\"/api/render-jobs\"}[$INCIDENT_VALIDATION_WINDOW])) by (le))"
RENDER_QUEUE_MAX_QUERY="max_over_time(setlog_vlog_render_queue_depth{job=\"setlog\"}[$INCIDENT_VALIDATION_WINDOW])"
RENDER_FAILURE_QUERY='sum(setlog_vlog_render_jobs_total{job="setlog", result="failure"}) or vector(0)'
CPU_RATIO_QUERY='sum(rate(container_cpu_usage_seconds_total{job="cadvisor", container_label_com_docker_compose_service="setlog", cpu="total"}[1m])) / clamp_min(sum(container_spec_cpu_quota{job="cadvisor", container_label_com_docker_compose_service="setlog"} / container_spec_cpu_period{job="cadvisor", container_label_com_docker_compose_service="setlog"}), 0.001)'

run_concurrent_incident_traffic() {
  pids=""
  failures=0
  worker=1
  while [ "$worker" -le "$INCIDENT_CONCURRENCY" ]; do
    COUNT="$INCIDENT_COUNT" SLEEP_SECONDS="$INCIDENT_SLEEP_SECONDS" RENDER_EVERY=1 sh "$SCRIPT_DIR/baseline-traffic.sh" &
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

collect_incident_4_metrics() {
  render_p95="$(incident_query_number render_p95 "$RENDER_P95_QUERY")"
  render_queue_max="$(incident_query_number render_queue_max "$RENDER_QUEUE_MAX_QUERY")"
  render_failure_after="$(incident_query_number render_failure_total "$RENDER_FAILURE_QUERY")"
  render_failure_delta="$(incident_math_max_zero "$(incident_math_subtract "$render_failure_after" "$render_failure_before")")"

  if cpu_ratio="$(incident_query_number cpu_ratio "$CPU_RATIO_QUERY")"; then
    if incident_number_ge "$cpu_ratio" 0.6; then
      cpu_diagnostic="ok"
    else
      cpu_diagnostic="weak"
      printf 'warning: CPU metric weak on this runtime; cpuRatio=%s, using render p95 and queue depth as primary signals\n' "$cpu_ratio" >&2
    fi
  else
    cpu_ratio=0
    cpu_diagnostic="unavailable"
    printf 'warning: CPU metric unavailable on this runtime; using render p95 and queue depth as primary signals\n' >&2
  fi
}

incident_4_metrics_pass() {
  incident_number_ge "$render_p95" 2 &&
    incident_number_ge "$render_queue_max" 1 &&
    incident_number_eq "$render_failure_delta" 0
}

validate_incident_4_metrics() {
  incident_assert_ge renderP95 "$render_p95" 2
  incident_assert_ge renderQueueMax "$render_queue_max" 1
  incident_assert_eq renderFailureDelta "$render_failure_delta" 0
}

run_incident_4_attempt() {
  attempt_workers="$1"

  printf 'starting Incident 4: CPU pressure drill with CPU_WORKERS=%s\n' "$attempt_workers" >&2
  CPU_WORKERS="$attempt_workers" sh "$SCRIPT_DIR/fault-cpu.sh"

  if incident_validation_enabled || incident_auto_tune_enabled; then
    render_failure_before="$(incident_query_number render_failure_before "$RENDER_FAILURE_QUERY")"
  else
    render_failure_before=0
  fi

  printf 'generating bounded render-heavy traffic while Incident 4 is active\n' >&2
  run_concurrent_incident_traffic

  if incident_validation_enabled || incident_auto_tune_enabled; then
    incident_wait_for_scrape
    collect_incident_4_metrics
    printf 'observed renderP95=%s renderQueueMax=%s renderFailureDelta=%s cpuRatio=%s with CPU_WORKERS=%s\n' \
      "$render_p95" "$render_queue_max" "$render_failure_delta" "$cpu_ratio" "$attempt_workers" >&2
  fi
}

run_adaptive_cpu_pressure_drill() {
  if incident_auto_tune_enabled && [ "$CPU_WORKERS_EXPLICIT" -eq 0 ]; then
    attempt_workers=1
    while [ "$attempt_workers" -le "$INCIDENT_MAX_CPU_WORKERS" ]; do
      run_incident_4_attempt "$attempt_workers"

      if ! incident_number_eq "$render_failure_delta" 0; then
        printf 'Incident 4 generated render failures at CPU_WORKERS=%s; expected CPU pressure without failures\n' "$attempt_workers" >&2
        return 1
      fi

      if incident_4_metrics_pass; then
        chosen_cpu_workers="$attempt_workers"
        return 0
      fi

      attempt_workers=$((attempt_workers + 1))
    done

    printf 'Incident 4 render symptoms did not reach renderP95>=2s and renderQueueMax>=1 up to INCIDENT_MAX_CPU_WORKERS=%s; try increasing INCIDENT_CONCURRENCY or INCIDENT_COUNT\n' "$INCIDENT_MAX_CPU_WORKERS" >&2
    return 1
  fi

  if incident_auto_tune_enabled; then
    printf 'CPU_WORKERS is explicitly set; using CPU_WORKERS=%s without auto-tuning\n' "$CPU_WORKERS" >&2
  else
    printf 'INCIDENT_AUTO_TUNE is disabled; using CPU_WORKERS=%s\n' "$CPU_WORKERS" >&2
  fi

  run_incident_4_attempt "$CPU_WORKERS"
  chosen_cpu_workers="$CPU_WORKERS"
}

print_incident_4_summary() {
  if incident_validation_enabled; then
    validate_incident_4_metrics
    printf '{"incident":4,"passed":true,"renderP95":%s,"renderQueueMax":%s,"renderFailureDelta":%s,"cpuRatio":%s,"cpuDiagnostic":"%s","chosenCpuWorkers":%s}\n' \
      "$render_p95" "$render_queue_max" "$render_failure_delta" "$cpu_ratio" "$cpu_diagnostic" "$chosen_cpu_workers"
  else
    printf '{"incident":4,"passed":true,"validationSkipped":true,"chosenCpuWorkers":%s}\n' "$chosen_cpu_workers"
  fi
}

printf 'preparing Incident 4 with baseline SetLog traffic\n'
COUNT="$BASELINE_COUNT" sh "$SCRIPT_DIR/baseline-traffic.sh"

run_adaptive_cpu_pressure_drill

printf 'Incident 4 is active. Open Grafana and complete the incident table.\n'
print_incident_4_summary
