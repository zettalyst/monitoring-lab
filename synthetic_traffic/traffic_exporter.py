from __future__ import annotations

import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from traffic_model import STEP_SECONDS, all_series, counter_value_at, series_rps


SERIES = all_series()


class CounterCache:
    def __init__(self) -> None:
        self.minute_ts = _floor_minute(time.time())
        self.values = {series: counter_value_at(self.minute_ts, series) for series in SERIES}

    def snapshot(self, timestamp: float) -> dict:
        target_ts = _floor_minute(timestamp)
        while self.minute_ts < target_ts:
            for series in SERIES:
                self.values[series] += series_rps(series, self.minute_ts) * STEP_SECONDS
            self.minute_ts += STEP_SECONDS
        return dict(self.values)

class MetricsHandler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        if self.path not in ("/metrics", "/"):
            self.send_response(404)
            self.end_headers()
            return

        body = render_metrics().encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format: str, *args) -> None:
        return


def render_metrics() -> str:
    timestamp = time.time()
    counters = COUNTERS.snapshot(timestamp)
    lines = [
        "# HELP http_requests_total Synthetic HTTP requests with weekly and daily seasonality.",
        "# TYPE http_requests_total counter",
    ]

    for series in SERIES:
        labels = ",".join(f'{key}="{_escape_label(value)}"' for key, value in series.labels.items())
        lines.append(f"http_requests_total{{{labels}}} {counters[series]:.3f}")

    lines.extend(
        [
            "# HELP lab_node_count Synthetic app node count.",
            "# TYPE lab_node_count gauge",
            "lab_node_count 4",
            "# HELP lab_capacity_limit_rps Synthetic app aggregate capacity limit in requests per second.",
            "# TYPE lab_capacity_limit_rps gauge",
            "lab_capacity_limit_rps 1400",
            "",
        ]
    )
    return "\n".join(lines)


def _escape_label(value: str) -> str:
    return value.replace("\\", "\\\\").replace("\n", "\\n").replace('"', '\\"')


def _floor_minute(timestamp: float) -> int:
    return int(timestamp // STEP_SECONDS) * STEP_SECONDS


COUNTERS = CounterCache()


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8000"))
    server = ThreadingHTTPServer(("0.0.0.0", port), MetricsHandler)
    server.serve_forever()
