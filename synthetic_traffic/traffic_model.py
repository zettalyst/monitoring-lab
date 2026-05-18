from __future__ import annotations

import math
from dataclasses import dataclass
from datetime import datetime, timezone


STEP_SECONDS = 60
MODEL_START_TS = int(datetime(2026, 1, 1, tzinfo=timezone.utc).timestamp())
KST_OFFSET_SECONDS = 9 * 60 * 60


@dataclass(frozen=True)
class TrafficSeries:
    service: str
    route: str
    status: str
    share: float

    @property
    def labels(self) -> dict[str, str]:
        return {
            "service": self.service,
            "route": self.route,
            "status": self.status,
        }


SERVICE_CONFIG = {
    "checkout": {
        "base_rps": 165.0,
        "phase": 0.1,
        "routes": {"/checkout": 0.55, "/cart": 0.30, "/payment": 0.15},
        "error_rate": 0.012,
    },
    "search": {
        "base_rps": 260.0,
        "phase": 1.7,
        "routes": {"/search": 0.70, "/suggest": 0.20, "/filters": 0.10},
        "error_rate": 0.006,
    },
    "profile": {
        "base_rps": 90.0,
        "phase": 2.8,
        "routes": {"/profile": 0.60, "/settings": 0.25, "/sessions": 0.15},
        "error_rate": 0.009,
    },
}


def all_series() -> list[TrafficSeries]:
    series: list[TrafficSeries] = []
    for service, config in SERVICE_CONFIG.items():
        error_rate = float(config["error_rate"])
        for route, route_share in config["routes"].items():
            series.append(TrafficSeries(service, route, "200", route_share * (1.0 - error_rate)))
            series.append(TrafficSeries(service, route, "500", route_share * error_rate))
    return series


def service_rps(service: str, timestamp: int | float) -> float:
    config = SERVICE_CONFIG[service]
    local_timestamp = float(timestamp) + KST_OFFSET_SECONDS
    local_day = math.floor(local_timestamp / 86400)
    seconds_in_day = local_timestamp % 86400
    hour = seconds_in_day / 3600.0
    weekday = int((local_day + 3) % 7)

    weekday_factor = [1.07, 1.10, 1.12, 1.08, 1.00, 0.78, 0.66][weekday]
    morning_peak = _gaussian(hour, 10.0, 2.4)
    lunch_peak = _gaussian(hour, 13.0, 1.0)
    evening_peak = _gaussian(hour, 20.5, 2.8)
    overnight_floor = 0.38
    daily_factor = overnight_floor + 0.35 * morning_peak + 0.18 * lunch_peak + 0.62 * evening_peak

    days_since_start = (float(timestamp) - MODEL_START_TS) / 86400.0
    slow_trend = 1.0 + 0.04 * math.sin((2.0 * math.pi * days_since_start / 28.0) + float(config["phase"]))
    deterministic_noise = 1.0 + 0.025 * math.sin((float(timestamp) / 1800.0) + float(config["phase"]) * 3.0)

    return max(0.0, float(config["base_rps"]) * weekday_factor * daily_factor * slow_trend * deterministic_noise)


def series_rps(series: TrafficSeries, timestamp: int | float) -> float:
    return service_rps(series.service, timestamp) * series.share


def counter_value_at(timestamp: int | float, series: TrafficSeries) -> float:
    target = int(timestamp // STEP_SECONDS) * STEP_SECONDS
    if target <= MODEL_START_TS:
        return 0.0

    value = 0.0
    current = MODEL_START_TS
    while current < target:
        value += series_rps(series, current) * STEP_SECONDS
        current += STEP_SECONDS
    return value


def _gaussian(value: float, center: float, width: float) -> float:
    return math.exp(-((value - center) ** 2) / (2.0 * width * width))
