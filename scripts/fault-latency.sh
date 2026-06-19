set -eu

BASE_URL="${BASE_URL:-http://localhost:8080}"
LATENCY_MS="${LATENCY_MS:-0}"
DB_POOL_HOLDERS="${DB_POOL_HOLDERS:-4}"
DB_POOL_HOLD_MILLIS="${DB_POOL_HOLD_MILLIS:-300000}"

case "$LATENCY_MS" in
  ''|*[!0-9]*)
    printf 'LATENCY_MS must be a non-negative integer, got: %s\n' "$LATENCY_MS" >&2
    exit 1
    ;;
esac

case "$DB_POOL_HOLDERS" in
  ''|*[!0-9]*)
    printf 'DB_POOL_HOLDERS must be a positive integer, got: %s\n' "$DB_POOL_HOLDERS" >&2
    exit 1
    ;;
esac

case "$DB_POOL_HOLD_MILLIS" in
  ''|*[!0-9]*)
    printf 'DB_POOL_HOLD_MILLIS must be a positive integer, got: %s\n' "$DB_POOL_HOLD_MILLIS" >&2
    exit 1
    ;;
esac

curl -fsS -X POST "$BASE_URL/internal/faults/db-pool" \
  -H 'Content-Type: application/json' \
  -d "{\"enabled\":true,\"holders\":$DB_POOL_HOLDERS,\"holdMillis\":$DB_POOL_HOLD_MILLIS}" >/dev/null || {
    printf 'failed to enable DB pool contention fault at %s/internal/faults/db-pool\n' "$BASE_URL" >&2
    exit 1
  }

curl -fsS -X POST "$BASE_URL/internal/faults/latency" \
  -H 'Content-Type: application/json' \
  -d "{\"latencyMs\":$LATENCY_MS}" || {
    printf 'failed to configure API latency fault at %s/internal/faults/latency\n' "$BASE_URL" >&2
    exit 1
  }
printf '\n'
