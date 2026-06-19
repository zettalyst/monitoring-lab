set -eu

BASE_URL="${BASE_URL:-http://localhost:8080}"
COUNT="${COUNT:-480}"
SLEEP_SECONDS="${SLEEP_SECONDS:-0.03}"
ALLOW_FAILURES="${ALLOW_FAILURES:-0}"
RENDER_EVERY="${RENDER_EVERY:-4}"

case "$COUNT" in
  ''|*[!0-9]*)
    printf 'COUNT must be a positive integer, got: %s\n' "$COUNT" >&2
    exit 1
    ;;
esac

if [ "$COUNT" -lt 1 ]; then
  printf 'COUNT must be a positive integer, got: %s\n' "$COUNT" >&2
  exit 1
fi

case "$RENDER_EVERY" in
  ''|*[!0-9]*)
    printf 'RENDER_EVERY must be a non-negative integer, got: %s\n' "$RENDER_EVERY" >&2
    exit 1
    ;;
esac

allow_failure() {
  [ "$ALLOW_FAILURES" = "1" ] || [ "$ALLOW_FAILURES" = "true" ] || [ "$ALLOW_FAILURES" = "TRUE" ]
}

run_request() {
  operation="$1"
  shift

  if "$@"; then
    return 0
  fi

  if allow_failure; then
    printf 'request failed during %s; continuing because ALLOW_FAILURES=%s\n' "$operation" "$ALLOW_FAILURES" >&2
    return 0
  fi

  printf 'failed during %s\n' "$operation" >&2
  exit 1
}

parse_room_id() {
  sed -n 's/.*"roomId"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' |
    head -n 1
}

room_probe_required=0

if room_json="$(curl -fsS -X POST "$BASE_URL/api/rooms")"; then
  room_id="$(printf '%s\n' "$room_json" | parse_room_id)"
else
  if allow_failure; then
    printf 'failed to create room at %s/api/rooms; using synthetic room id because ALLOW_FAILURES=%s\n' "$BASE_URL" "$ALLOW_FAILURES" >&2
    room_probe_required=1
    room_id="room-outage-drill"
  else
    printf 'failed to create room at %s/api/rooms\n' "$BASE_URL" >&2
    exit 1
  fi
fi

if [ -z "$room_id" ]; then
  if allow_failure; then
    printf 'failed to parse roomId; using synthetic room id because ALLOW_FAILURES=%s\n' "$ALLOW_FAILURES" >&2
    room_probe_required=1
    room_id="room-outage-drill"
  else
    printf 'failed to parse roomId from /api/rooms response:\n%s\n' "$room_json" >&2
    exit 1
  fi
fi

i=1
while [ "$i" -le "$COUNT" ]; do
  if [ "$room_probe_required" -eq 1 ]; then
    if probe_json="$(curl -fsS -X POST "$BASE_URL/api/rooms")"; then
      probe_room_id="$(printf '%s\n' "$probe_json" | parse_room_id)"
      if [ -n "$probe_room_id" ]; then
        room_id="$probe_room_id"
        room_probe_required=0
        printf 'adopted recovered roomId %s during create room probe iteration %s\n' "$room_id" "$i" >&2
      elif allow_failure; then
        printf 'create room probe iteration %s returned no roomId; keeping synthetic room id\n' "$i" >&2
      else
        printf 'failed to parse roomId from create room probe iteration %s response:\n%s\n' "$i" "$probe_json" >&2
        exit 1
      fi
    else
      run_request "create room probe iteration $i" false
    fi
  fi

  run_request "create clip iteration $i" curl -fsS -X POST "$BASE_URL/api/clips" \
    -H 'Content-Type: application/json' \
    -d "{\"roomId\":\"$room_id\",\"networkType\":\"wifi\"}" >/dev/null

  if [ "$RENDER_EVERY" -gt 0 ] && [ $((i % RENDER_EVERY)) -eq 0 ]; then
    run_request "create render job iteration $i" curl -fsS -X POST "$BASE_URL/api/render-jobs" \
      -H 'Content-Type: application/json' \
      -d "{\"roomId\":\"$room_id\"}" >/dev/null
  fi

  run_request "fetch feed iteration $i" curl -fsS "$BASE_URL/api/feed" >/dev/null
  sleep "$SLEEP_SECONDS"
  i=$((i + 1))
done

printf 'sent %s baseline iterations to %s with room %s\n' "$COUNT" "$BASE_URL" "$room_id"
