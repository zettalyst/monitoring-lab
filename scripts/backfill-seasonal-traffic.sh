#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PYTHON_BIN="${PYTHON_BIN:-python3}"
DAYS="${DAYS:-35}"
STEP_SECONDS="${STEP_SECONDS:-60}"
END_OFFSET_SECONDS="${END_OFFSET_SECONDS:-300}"
BACKFILL_DIR="${BACKFILL_DIR:-$ROOT_DIR/tmp/seasonal-backfill}"
OPENMETRICS_FILE="$BACKFILL_DIR/http_requests.openmetrics"
BLOCKS_DIR="$BACKFILL_DIR/blocks"

rm -rf "$BACKFILL_DIR"
mkdir -p "$BLOCKS_DIR"

"$PYTHON_BIN" "$ROOT_DIR/scripts/generate_seasonal_openmetrics.py" "$OPENMETRICS_FILE" \
  --days "$DAYS" \
  --step-seconds "$STEP_SECONDS" \
  --end-offset-seconds "$END_OFFSET_SECONDS"

docker run --rm --entrypoint promtool \
  -v "$BACKFILL_DIR:/backfill" \
  prom/prometheus \
  tsdb create-blocks-from openmetrics \
  -q \
  --label=job=seasonal-app \
  --label=instance=synthetic-traffic:8000 \
  /backfill/http_requests.openmetrics \
  /backfill/blocks

docker compose stop prometheus

docker compose run --rm --no-deps --user root \
  -v "$BLOCKS_DIR:/backfill/blocks:ro" \
  --entrypoint /bin/sh \
  prometheus \
  -c '
set -eu

if [ -f /prometheus/seasonal-backfill-ulids.txt ]; then
  while IFS= read -r ulid; do
    case "$ulid" in
      ""|*/*|*..*) continue ;;
      *) rm -rf "/prometheus/$ulid" ;;
    esac
  done < /prometheus/seasonal-backfill-ulids.txt
fi

: > /prometheus/seasonal-backfill-ulids.txt
for block in /backfill/blocks/*; do
  [ -d "$block" ] || continue
  ulid="$(basename "$block")"
  cp -a "$block" "/prometheus/$ulid"
  echo "$ulid" >> /prometheus/seasonal-backfill-ulids.txt
  chown -R nobody:nobody "/prometheus/$ulid"
done
chown nobody:nobody /prometheus/seasonal-backfill-ulids.txt
'

docker compose up -d prometheus

echo "Backfilled seasonal http_requests_total data into the Prometheus volume."
