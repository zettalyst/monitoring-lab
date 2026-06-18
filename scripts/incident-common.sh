set -eu

PROMETHEUS_URL="${PROMETHEUS_URL:-http://localhost:9090}"
INCIDENT_VALIDATE="${INCIDENT_VALIDATE:-1}"
INCIDENT_AUTO_TUNE="${INCIDENT_AUTO_TUNE:-1}"
INCIDENT_VALIDATION_WINDOW="${INCIDENT_VALIDATION_WINDOW:-2m}"
INCIDENT_VALIDATION_ATTEMPTS="${INCIDENT_VALIDATION_ATTEMPTS:-12}"
INCIDENT_VALIDATION_SLEEP_SECONDS="${INCIDENT_VALIDATION_SLEEP_SECONDS:-5}"
INCIDENT_SCRAPE_WAIT_SECONDS="${INCIDENT_SCRAPE_WAIT_SECONDS:-8}"

is_true() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

incident_validation_enabled() {
  is_true "$INCIDENT_VALIDATE"
}

incident_auto_tune_enabled() {
  is_true "$INCIDENT_AUTO_TUNE"
}

incident_query_value() {
  query="$1"
  response="$(
    curl -fsG \
      --data-urlencode "query=$query" \
      "$PROMETHEUS_URL/api/v1/query"
  )" || {
    printf 'failed to query Prometheus at %s/api/v1/query\n' "$PROMETHEUS_URL" >&2
    return 1
  }

  case "$response" in
    *'"status":"success"'*) ;;
    *)
      printf 'Prometheus query did not succeed: %s\nquery: %s\n' "$response" "$query" >&2
      return 1
      ;;
  esac

  printf '%s\n' "$response" |
    sed -n 's/.*"value":\[[^][]*,"\([^"]*\)".*/\1/p' |
    head -n 1
}

incident_query_number() {
  name="$1"
  query="$2"
  value="$(incident_query_value "$query")"
  if [ -z "$value" ]; then
    printf 'metric %s returned no data\nquery: %s\n' "$name" "$query" >&2
    return 1
  fi

  awk -v value="$value" 'BEGIN {
    if (value == "+Inf" || value == "-Inf" || value == "NaN") {
      exit 1
    }
    if (value !~ /^-?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][-+]?[0-9]+)?$/) {
      exit 1
    }
  }' || {
    printf 'metric %s returned a non-numeric value: %s\n' "$name" "$value" >&2
    return 1
  }

  printf '%s\n' "$value"
}

incident_math_subtract() {
  awk -v left="$1" -v right="$2" 'BEGIN { printf "%.12g\n", left - right }'
}

incident_math_divide() {
  awk -v numerator="$1" -v denominator="$2" 'BEGIN {
    if (denominator <= 0) {
      print "0"
    } else {
      printf "%.12g\n", numerator / denominator
    }
  }'
}

incident_math_max_zero() {
  awk -v value="$1" 'BEGIN {
    if (value < 0) {
      print "0"
    } else {
      printf "%.12g\n", value
    }
  }'
}

incident_number_ge() {
  awk -v value="$1" -v threshold="$2" 'BEGIN { exit !(value + 0 >= threshold + 0) }'
}

incident_number_gt() {
  awk -v value="$1" -v threshold="$2" 'BEGIN { exit !(value + 0 > threshold + 0) }'
}

incident_number_le() {
  awk -v value="$1" -v threshold="$2" 'BEGIN { exit !(value + 0 <= threshold + 0) }'
}

incident_number_eq() {
  awk -v value="$1" -v expected="$2" 'BEGIN { exit !(value + 0 == expected + 0) }'
}

incident_assert_ge() {
  name="$1"
  value="$2"
  threshold="$3"
  incident_number_ge "$value" "$threshold" || {
    printf 'incident validation failed: %s expected >= %s, got %s\n' "$name" "$threshold" "$value" >&2
    return 1
  }
}

incident_assert_gt() {
  name="$1"
  value="$2"
  threshold="$3"
  incident_number_gt "$value" "$threshold" || {
    printf 'incident validation failed: %s expected > %s, got %s\n' "$name" "$threshold" "$value" >&2
    return 1
  }
}

incident_assert_le() {
  name="$1"
  value="$2"
  threshold="$3"
  incident_number_le "$value" "$threshold" || {
    printf 'incident validation failed: %s expected <= %s, got %s\n' "$name" "$threshold" "$value" >&2
    return 1
  }
}

incident_assert_eq() {
  name="$1"
  value="$2"
  expected="$3"
  incident_number_eq "$value" "$expected" || {
    printf 'incident validation failed: %s expected == %s, got %s\n' "$name" "$expected" "$value" >&2
    return 1
  }
}

incident_wait_for_scrape() {
  sleep "$INCIDENT_SCRAPE_WAIT_SECONDS"
}

incident_print_validation_disabled_summary() {
  incident="$1"
  printf '{"incident":%s,"passed":true,"validationSkipped":true}\n' "$incident"
}
