#!/usr/bin/env python3
from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path


ROOT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT_DIR / "synthetic_traffic"))

from traffic_model import STEP_SECONDS, all_series, counter_value_at, series_rps  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate OpenMetrics history for seasonal traffic demos.")
    parser.add_argument("output", type=Path)
    parser.add_argument("--days", type=int, default=35)
    parser.add_argument("--step-seconds", type=int, default=STEP_SECONDS)
    parser.add_argument("--end-offset-seconds", type=int, default=300)
    args = parser.parse_args()

    if args.days < 22:
        raise SystemExit("--days must be at least 22 so the 3-week same-time query has data.")
    if args.step_seconds <= 0:
        raise SystemExit("--step-seconds must be positive.")

    end_ts = _floor(time.time() - args.end_offset_seconds, args.step_seconds)
    start_ts = _floor(end_ts - args.days * 86400, args.step_seconds)
    series_list = all_series()
    counters = {series: counter_value_at(start_ts, series) for series in series_list}

    args.output.parent.mkdir(parents=True, exist_ok=True)
    sample_count = 0
    with args.output.open("w", encoding="utf-8") as handle:
        handle.write("# HELP http_requests Synthetic HTTP requests with weekly and daily seasonality.\n")
        handle.write("# TYPE http_requests counter\n")

        timestamp = start_ts
        while timestamp <= end_ts:
            if timestamp > start_ts:
                previous_ts = timestamp - args.step_seconds
                for series in series_list:
                    counters[series] += series_rps(series, previous_ts) * args.step_seconds

            for series in series_list:
                labels = ",".join(f'{key}="{_escape_label(value)}"' for key, value in series.labels.items())
                handle.write(f"http_requests_total{{{labels}}} {counters[series]:.3f} {timestamp}\n")
                sample_count += 1
            timestamp += args.step_seconds

        handle.write("# EOF\n")

    print(f"wrote {sample_count} samples from {start_ts} to {end_ts} into {args.output}")
    return 0


def _floor(value: float, step: int) -> int:
    return int(value // step) * step


def _escape_label(value: str) -> str:
    return value.replace("\\", "\\\\").replace("\n", "\\n").replace('"', '\\"')


if __name__ == "__main__":
    raise SystemExit(main())
