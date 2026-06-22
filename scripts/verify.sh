set -eu

run_promtool() {
  if command -v promtool >/dev/null 2>&1; then
    promtool "$@"
  else
    docker run --rm \
      -v "$PWD/prometheus:/etc/prometheus:ro" \
      -v "$PWD:/workspace:ro" \
      --entrypoint promtool \
      prom/prometheus:v3.12.0 "$@"
  fi
}

printf 'checking docker compose config\n'
docker compose config --quiet

printf 'checking Bear generated sources\n'
python3 scripts/sync-bear-sources.py --check

dashboard_rules="$(mktemp "$PWD/.setlog-dashboard-rules.XXXXXX.yml")"
trap 'rm -f "$dashboard_rules"' EXIT

printf 'checking Grafana dashboards, panels, and query extraction\n'
python3 scripts/verify-setlog-assets.py --dashboard-rules-out "$dashboard_rules"

printf 'checking Grafana dashboard JSON\n'
if command -v python3 >/dev/null 2>&1; then
  find grafana/dashboards -maxdepth 2 -type f -name '*.json' | while IFS= read -r dashboard; do
    python3 -m json.tool "$dashboard" >/tmp/setlog-dashboard.json
  done
elif command -v python >/dev/null 2>&1; then
  find grafana/dashboards -maxdepth 2 -type f -name '*.json' | while IFS= read -r dashboard; do
    python -m json.tool "$dashboard" >/tmp/setlog-dashboard.json
  done
else
  docker run --rm -v "$PWD:/workspace" -w /workspace python:3.12.13-alpine \
    sh -c 'find grafana/dashboards -maxdepth 2 -type f -name "*.json" | while IFS= read -r dashboard; do python -m json.tool "$dashboard" >/tmp/setlog-dashboard.json; done'
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
docker run --rm -v "$PWD/demo-service:/workspace" -w /workspace gradle:9.5.1-jdk21 gradle --no-daemon test

printf 'verification complete\n'
