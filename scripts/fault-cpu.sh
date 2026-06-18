set -eu

BASE_URL="${BASE_URL:-http://localhost:8080}"
CPU_WORKERS="${CPU_WORKERS:-4}"

curl -fsS -X POST "$BASE_URL/internal/faults/cpu" \
  -H 'Content-Type: application/json' \
  -d "{\"enabled\":true,\"workers\":$CPU_WORKERS}" || {
    printf 'failed to enable CPU fault at %s/internal/faults/cpu\n' "$BASE_URL" >&2
    exit 1
  }
printf '\n'
