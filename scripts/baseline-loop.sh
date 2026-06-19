set -eu

SCRIPT_DIR="$(CDPATH= cd "$(dirname "$0")" && pwd)"
BASE_URL="${BASE_URL:-http://setlog:8080}"
BASELINE_LOOP_WORKERS="${BASELINE_LOOP_WORKERS:-1}"
BASELINE_LOOP_COUNT="${BASELINE_LOOP_COUNT:-480}"
BASELINE_LOOP_SLEEP_SECONDS="${BASELINE_LOOP_SLEEP_SECONDS:-0.03}"
BASELINE_LOOP_PAUSE_SECONDS="${BASELINE_LOOP_PAUSE_SECONDS:-3}"
BASELINE_LOOP_HEALTH_ATTEMPTS="${BASELINE_LOOP_HEALTH_ATTEMPTS:-120}"
RENDER_EVERY="${RENDER_EVERY:-4}"
ALLOW_FAILURES="${ALLOW_FAILURES:-1}"

case "$BASELINE_LOOP_HEALTH_ATTEMPTS" in
  ''|*[!0-9]*)
    printf 'BASELINE_LOOP_HEALTH_ATTEMPTS must be a positive integer, got: %s\n' "$BASELINE_LOOP_HEALTH_ATTEMPTS" >&2
    exit 1
    ;;
esac

case "$BASELINE_LOOP_WORKERS" in
  ''|*[!0-9]*)
    printf 'BASELINE_LOOP_WORKERS must be a positive integer, got: %s\n' "$BASELINE_LOOP_WORKERS" >&2
    exit 1
    ;;
esac

if [ "$BASELINE_LOOP_WORKERS" -lt 1 ]; then
  printf 'BASELINE_LOOP_WORKERS must be a positive integer, got: %s\n' "$BASELINE_LOOP_WORKERS" >&2
  exit 1
fi

if [ "$BASELINE_LOOP_HEALTH_ATTEMPTS" -lt 1 ]; then
  printf 'BASELINE_LOOP_HEALTH_ATTEMPTS must be a positive integer, got: %s\n' "$BASELINE_LOOP_HEALTH_ATTEMPTS" >&2
  exit 1
fi

attempt=1
while [ "$attempt" -le "$BASELINE_LOOP_HEALTH_ATTEMPTS" ]; do
  if curl -fsS "$BASE_URL/actuator/health" >/dev/null; then
    break
  fi

  printf 'waiting for setlog health at %s/actuator/health (%s/%s)\n' "$BASE_URL" "$attempt" "$BASELINE_LOOP_HEALTH_ATTEMPTS" >&2
  sleep 1
  attempt=$((attempt + 1))
done

if [ "$attempt" -gt "$BASELINE_LOOP_HEALTH_ATTEMPTS" ]; then
  printf 'setlog did not become healthy at %s/actuator/health after %s attempts\n' "$BASE_URL" "$BASELINE_LOOP_HEALTH_ATTEMPTS" >&2
  exit 1
fi

printf 'baseline traffic loop started against %s\n' "$BASE_URL"

while :; do
  pids=""
  worker=1
  while [ "$worker" -le "$BASELINE_LOOP_WORKERS" ]; do
    COUNT="$BASELINE_LOOP_COUNT" \
      SLEEP_SECONDS="$BASELINE_LOOP_SLEEP_SECONDS" \
      RENDER_EVERY="$RENDER_EVERY" \
      ALLOW_FAILURES="$ALLOW_FAILURES" \
      sh "$SCRIPT_DIR/baseline-traffic.sh" &
    pids="$pids $!"
    worker=$((worker + 1))
  done

  failed=0
  for pid in $pids; do
    if ! wait "$pid"; then
      failed=1
    fi
  done

  if [ "$failed" -ne 0 ]; then
    printf 'one or more baseline traffic workers failed\n' >&2
    exit 1
  fi

  printf 'baseline traffic loop sleeping for %s seconds\n' "$BASELINE_LOOP_PAUSE_SECONDS"
  sleep "$BASELINE_LOOP_PAUSE_SECONDS"
done
