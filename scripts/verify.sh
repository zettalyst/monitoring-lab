set -eu

run_promtool() {
  if command -v promtool >/dev/null 2>&1; then
    promtool "$@"
  else
    docker run --rm \
      -v "$PWD/prometheus:/etc/prometheus:ro" \
      -v "$PWD:/workspace:ro" \
      --entrypoint promtool \
      prom/prometheus "$@"
  fi
}

printf 'checking docker compose config\n'
docker compose config --quiet

printf 'checking Bear generated sources\n'
python3 scripts/sync-bear-sources.py --check

dashboard_rules="$(mktemp "$PWD/.sre301-dashboard-rules.XXXXXX.yml")"
trap 'rm -f "$dashboard_rules"' EXIT

printf 'checking Grafana dashboards, panels, and query extraction\n'
python3 scripts/verify-sre301-assets.py --dashboard-rules-out "$dashboard_rules"

printf 'checking Grafana dashboard JSON\n'
if command -v python3 >/dev/null 2>&1; then
  for dashboard in grafana/dashboards/*.json grafana/dashboards/sre301/*.json; do
    python3 -m json.tool "$dashboard" >/tmp/sre301-dashboard.json
  done
elif command -v python >/dev/null 2>&1; then
  for dashboard in grafana/dashboards/*.json grafana/dashboards/sre301/*.json; do
    python -m json.tool "$dashboard" >/tmp/sre301-dashboard.json
  done
else
  docker run --rm -v "$PWD:/workspace" -w /workspace python:3.12-alpine \
    sh -c 'for dashboard in grafana/dashboards/*.json grafana/dashboards/sre301/*.json; do python -m json.tool "$dashboard" >/tmp/sre301-dashboard.json; done'
fi

printf 'checking Prometheus config and alert rules\n'
run_promtool check config /etc/prometheus/prometheus.yml

printf 'checking Grafana dashboard PromQL syntax\n'
run_promtool check rules "/workspace/${dashboard_rules#$PWD/}"

printf 'checking shell script syntax\n'
for script in scripts/*.sh; do
  sh -n "$script"
done

printf 'running Dockerized Gradle tests\n'
docker run --rm -v "$PWD/demo-service:/workspace" -w /workspace gradle:8.14.3-jdk21 gradle --no-daemon test

printf 'verification complete\n'
