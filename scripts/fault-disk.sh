set -eu

BASE_URL="${BASE_URL:-http://localhost:8080}"
DISK_MEGABYTES="${DISK_MEGABYTES:-90}"

curl -fsS -X POST "$BASE_URL/internal/faults/disk" \
  -H 'Content-Type: application/json' \
  -d "{\"enabled\":true,\"megabytes\":$DISK_MEGABYTES}" || {
    printf 'failed to enable disk fault at %s/internal/faults/disk\n' "$BASE_URL" >&2
    exit 1
  }
printf '\n'
