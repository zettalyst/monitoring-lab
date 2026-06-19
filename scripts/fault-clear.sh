set -eu

BASE_URL="${BASE_URL:-http://localhost:8080}"
FAULT_CLEAR_SKIP_COMPOSE="${FAULT_CLEAR_SKIP_COMPOSE:-0}"

curl -fsS -X DELETE "$BASE_URL/internal/faults" || {
  printf 'failed to clear faults at %s/internal/faults\n' "$BASE_URL" >&2
  exit 1
}
printf '\n'

if [ "$FAULT_CLEAR_SKIP_COMPOSE" = "1" ] || [ "$FAULT_CLEAR_SKIP_COMPOSE" = "true" ] || [ "$FAULT_CLEAR_SKIP_COMPOSE" = "TRUE" ]; then
  printf 'cleared app faults at %s and skipped compose service recovery because FAULT_CLEAR_SKIP_COMPOSE=%s\n' "$BASE_URL" "$FAULT_CLEAR_SKIP_COMPOSE"
  exit 0
fi

docker compose up -d mysql mysqld-exporter setlog setlog-netem
docker compose restart setlog-netem

printf 'cleared app faults and ensured mysql, mysqld-exporter, setlog, and setlog-netem are running\n'
