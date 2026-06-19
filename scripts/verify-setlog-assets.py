#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]

GOLDEN_DASHBOARD = REPO_ROOT / "grafana/dashboards/setlog/golden-signals.json"
SUPPORT_DASHBOARD_DIR = REPO_ROOT / "grafana/dashboards/setlog-support"
MYSQL_DASHBOARD = SUPPORT_DASHBOARD_DIR / "mysql-dependency.json"
PROMETHEUS_DASHBOARD = SUPPORT_DASHBOARD_DIR / "prometheus-overview.json"
CADVISOR_DASHBOARD = SUPPORT_DASHBOARD_DIR / "container-runtime.json"
NODE_EXPORTER_DASHBOARD = SUPPORT_DASHBOARD_DIR / "host-overview.json"
ALERTING_FILE = REPO_ROOT / "grafana/provisioning/alerting/alerting.yml"
DASHBOARD_PROVISIONING_FILE = REPO_ROOT / "grafana/provisioning/dashboards/dashboards.yml"

QUERY_DASHBOARDS = (
    GOLDEN_DASHBOARD,
    MYSQL_DASHBOARD,
    PROMETHEUS_DASHBOARD,
    CADVISOR_DASHBOARD,
    NODE_EXPORTER_DASHBOARD,
)

NODE_CPU_ALLOWED_DASHBOARDS = {
    PROMETHEUS_DASHBOARD.as_posix(),
    NODE_EXPORTER_DASHBOARD.as_posix(),
}

EXPECTED_GOLDEN_PANELS = {
    "Service Up",
    "API Traffic",
    "API 5xx Ratio",
    "API Latency p95",
    "I1 Page: API p95 by Journey",
    "I1 Impact: Traffic and Status by API",
    "I1 Diagnostic: DB Pool Saturation",
    "I2 Page: API 5xx Ratio",
    "I2 Impact: Traffic and Status by API",
    "I2 Domain: Clip Upload Success vs Failure",
    "I2 Diagnostic: MySQL Dependency Up",
    "I3 Page: Render Failure Ratio",
    "I3 Impact: Render Job HTTP Status",
    "I3 Diagnostic: Render Debug Log Size",
    "I3 Diagnostic: SetLog Disk I/O",
    "I4 Page: Render p95 Latency",
    "I4 Page: Render Queue Depth",
    "I4 Diagnostic: SetLog CPU Pressure",
    "I4 Guardrail: Disk Debug Log Size",
    "Latency by API",
    "Clip Upload p95 by Network",
    "Room Sync p95",
    "SetLog Container Memory",
    "SetLog Container Network I/O",
    "Render Jobs by Result",
}

EXPECTED_GRAFANA_ALERTS = {
    "setlog-i1-high-latency": 101,
    "setlog-i2-too-many-5xx": 201,
    "setlog-i3-render-failures": 301,
    "setlog-i4-render-latency": 401,
    "setlog-i4-render-backlog": 402,
}

EXPECTED_SUPPORT_DASHBOARD_PANELS = {
    CADVISOR_DASHBOARD: {
        "cAdvisor Up",
        "Compose Containers",
        "Container Memory Total",
        "Container CPU by Service",
        "Container Memory by Service",
        "Container Network by Service",
        "Container Filesystem I/O by Service",
    },
    NODE_EXPORTER_DASHBOARD: {
        "Node Exporter Up",
        "CPU Busy",
        "Memory Used",
        "CPU Busy Trend",
        "Load Average",
        "Filesystem Used",
        "Network I/O",
    },
}

DOCS_WITH_PANEL_REFERENCES = [
    REPO_ROOT / "README.md",
    *sorted((REPO_ROOT / "labs").glob("*.md")),
    *sorted((REPO_ROOT / "answers").glob("*.md")),
    *sorted((REPO_ROOT / "templates").glob("*.md")),
]

STALE_PANEL_REFERENCES = {
    "Errors",
    "Traffic",
    "Traffic and Status",
    "Vlog Render Jobs",
    "Vlog Render Debug Log Size",
    "Vlog Render Queue Depth",
    "SetLog Container CPU Pressure",
    "Node CPU Saturation",
    "JVM Memory",
    "DB Pool Saturation",
    "Latency p95",
}

BACKTICK_PATTERN = re.compile(r"`([^`\n]+)`")


def fail(message: str) -> None:
    print(f"verify-setlog-assets: {message}", file=sys.stderr)
    raise SystemExit(1)


def load_dashboard(path: Path) -> dict[str, object]:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        fail(f"missing dashboard {path}")
    except json.JSONDecodeError as exception:
        fail(f"invalid dashboard JSON {path}: {exception}")


def walk_panels(dashboard: dict[str, object]) -> list[dict[str, object]]:
    panels: list[dict[str, object]] = []
    pending = list(dashboard.get("panels", []))
    while pending:
        panel = pending.pop(0)
        if isinstance(panel, dict):
            panels.append(panel)
            nested = panel.get("panels", [])
            if isinstance(nested, list):
                pending.extend(nested)
    return panels


def dashboard_titles(dashboard: dict[str, object]) -> set[str]:
    return {
        str(panel["title"])
        for panel in walk_panels(dashboard)
        if isinstance(panel.get("title"), str) and str(panel["title"]).strip()
    }


def dashboard_expressions(path: Path, dashboard: dict[str, object]) -> list[tuple[str, str, str]]:
    expressions: list[tuple[str, str, str]] = []
    for panel in walk_panels(dashboard):
        panel_title = str(panel.get("title", "untitled panel"))
        targets = panel.get("targets", [])
        if not isinstance(targets, list):
            continue
        for index, target in enumerate(targets, start=1):
            if not isinstance(target, dict):
                continue
            expr = target.get("expr")
            if isinstance(expr, str) and expr.strip():
                expressions.append((path.as_posix(), f"{panel_title} target {index}", expr.strip()))
    return expressions


def validate_golden_dashboard() -> None:
    dashboard = load_dashboard(GOLDEN_DASHBOARD)
    titles = dashboard_titles(dashboard)
    missing = sorted(EXPECTED_GOLDEN_PANELS - titles)
    if missing:
        fail(f"golden dashboard is missing expected panels: {', '.join(missing)}")
    forbidden = sorted(title for title in titles if title in STALE_PANEL_REFERENCES)
    if forbidden:
        fail(f"golden dashboard still exposes stale panel titles: {', '.join(forbidden)}")


def validate_support_dashboards() -> None:
    for path, expected_panels in EXPECTED_SUPPORT_DASHBOARD_PANELS.items():
        dashboard = load_dashboard(path)
        titles = dashboard_titles(dashboard)
        missing = sorted(expected_panels - titles)
        if missing:
            fail(f"{path.relative_to(REPO_ROOT)} is missing expected panels: {', '.join(missing)}")


def validate_dashboard_provisioning() -> None:
    try:
        text = DASHBOARD_PROVISIONING_FILE.read_text(encoding="utf-8")
    except FileNotFoundError:
        fail(f"missing Grafana dashboard provisioning file {DASHBOARD_PROVISIONING_FILE}")

    required = {
        "name: SetLog": "SetLog dashboard provider",
        "path: /var/lib/grafana/dashboards/setlog": "SetLog dashboard path",
        "folder: SetLog": "SetLog dashboard folder",
        "name: SetLog Support": "SetLog Support dashboard provider",
        "path: /var/lib/grafana/dashboards/setlog-support": "SetLog Support dashboard path",
        "folder: SetLog Support": "SetLog Support dashboard folder",
    }
    missing = [description for token, description in required.items() if token not in text]
    if missing:
        fail("Grafana dashboard provisioning is missing " + ", ".join(missing))
    if "foldersFromFilesStructure: true" in text:
        fail("Grafana dashboard provisioning must use explicit SetLog and SetLog Support providers")


def validate_doc_panel_references() -> None:
    allowed_titles = dashboard_titles(load_dashboard(GOLDEN_DASHBOARD))
    allowed_titles |= dashboard_titles(load_dashboard(MYSQL_DASHBOARD))
    allowed_titles |= dashboard_titles(load_dashboard(PROMETHEUS_DASHBOARD))
    allowed_titles |= dashboard_titles(load_dashboard(CADVISOR_DASHBOARD))
    allowed_titles |= dashboard_titles(load_dashboard(NODE_EXPORTER_DASHBOARD))

    failures: list[str] = []
    for path in DOCS_WITH_PANEL_REFERENCES:
        if not path.exists():
            continue
        for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
            if not any(token in line for token in ("패널", "panel", "Panel", "볼 것", "PromQL 또는 패널", "먼저 볼")):
                continue
            for value in BACKTICK_PATTERN.findall(line):
                if value in STALE_PANEL_REFERENCES and value not in allowed_titles:
                    failures.append(f"{path.relative_to(REPO_ROOT)}:{line_number}: stale panel reference `{value}`")

    if failures:
        fail("\n".join(failures))


def validate_dashboard_queries() -> list[tuple[str, str, str]]:
    expressions: list[tuple[str, str, str]] = []
    for path in QUERY_DASHBOARDS:
        dashboard = load_dashboard(path)
        expressions.extend(dashboard_expressions(path, dashboard))

    if not expressions:
        fail("no Grafana dashboard PromQL expressions were found")

    invalid_cpu = [
        f"{source} {label}"
        for source, label, expr in expressions
        if "node_cpu_seconds_total" in expr and source not in NODE_CPU_ALLOWED_DASHBOARDS
    ]
    if invalid_cpu:
        fail("lab dashboard queries must use cAdvisor container CPU metrics, found node CPU in " + ", ".join(invalid_cpu))

    invalid_i3_page_signal = [
        f"{source} {label}"
        for source, label, expr in expressions
        if label.startswith("I3 Page: Render Failure Ratio") and 'reason="disk"' not in expr
    ]
    if invalid_i3_page_signal:
        fail("I3 page signal queries must isolate disk-related render failures, found " + ", ".join(invalid_i3_page_signal))

    invalid_i1_page_signal = [
        f"{source} {label}"
        for source, label, expr in expressions
        if label.startswith("I1 Page: API p95 by Journey") and 'status!~"5.."' not in expr
    ]
    if invalid_i1_page_signal:
        fail("I1 page signal queries must exclude 5xx responses with status!~\"5..\", found " + ", ".join(invalid_i1_page_signal))

    return expressions


def validate_alerting_file() -> list[tuple[str, str, str]]:
    try:
        text = ALERTING_FILE.read_text(encoding="utf-8")
    except FileNotFoundError:
        fail(f"missing Grafana alert provisioning file {ALERTING_FILE}")

    alerts: dict[str, dict[str, str]] = {}
    current_uid: str | None = None
    current_expr_index = 0
    expressions: list[tuple[str, str, str]] = []
    expressions_by_uid: dict[str, list[str]] = {}

    for raw_line in text.splitlines():
        line = raw_line.strip()
        if line.startswith("- uid: "):
            current_uid = line.split(":", 1)[1].strip().strip('"')
            current_expr_index = 0
            alerts[current_uid] = {}
            continue
        if current_uid is None:
            continue
        if line.startswith("panelId: "):
            alerts[current_uid]["panelId"] = line.split(":", 1)[1].strip().strip('"')
        elif line.startswith("__dashboardUid__: "):
            alerts[current_uid]["dashboardUid"] = line.split(":", 1)[1].strip().strip('"')
        elif line.startswith("__panelId__: "):
            alerts[current_uid]["annotationPanelId"] = line.split(":", 1)[1].strip().strip('"')
        elif line.startswith("expr: "):
            expr = line.split(":", 1)[1].strip()
            if expr:
                current_expr_index += 1
                expressions.append((ALERTING_FILE.as_posix(), f"{current_uid} expression {current_expr_index}", expr))
                expressions_by_uid.setdefault(current_uid, []).append(expr)

    missing = sorted(set(EXPECTED_GRAFANA_ALERTS) - set(alerts))
    if missing:
        fail(f"Grafana alert provisioning is missing alert rules: {', '.join(missing)}")

    for uid, expected_panel_id in EXPECTED_GRAFANA_ALERTS.items():
        alert = alerts[uid]
        panel_id = alert.get("panelId")
        annotation_panel_id = alert.get("annotationPanelId")
        dashboard_uid = alert.get("dashboardUid")
        if panel_id != str(expected_panel_id):
            fail(f"{uid} must link to panelId {expected_panel_id}, got {panel_id}")
        if annotation_panel_id != str(expected_panel_id):
            fail(f"{uid} must annotate __panelId__ {expected_panel_id}, got {annotation_panel_id}")
        if dashboard_uid != "setlog-incident-response":
            fail(f"{uid} must annotate dashboard setlog-incident-response, got {dashboard_uid}")

    if len(expressions) < len(EXPECTED_GRAFANA_ALERTS):
        fail(f"expected at least {len(EXPECTED_GRAFANA_ALERTS)} Grafana alert PromQL expressions, found {len(expressions)}")

    i3_expressions = expressions_by_uid.get("setlog-i3-render-failures", [])
    if not i3_expressions or not any('reason="disk"' in expr for expr in i3_expressions):
        fail("setlog-i3-render-failures must isolate disk-related render failures with reason=\"disk\"")

    i1_expressions = expressions_by_uid.get("setlog-i1-high-latency", [])
    if not i1_expressions or not any('status!~"5.."' in expr for expr in i1_expressions):
        fail("setlog-i1-high-latency must exclude 5xx responses with status!~\"5..\"")

    return expressions


def write_dashboard_rule_file(path: Path, expressions: list[tuple[str, str, str]]) -> None:
    lines = ["groups:", "  - name: setlog-dashboard-query-parse", "    rules:"]
    for index, (_, label, expr) in enumerate(expressions, start=1):
        record_name = f"setlog_dashboard_query_{index:03d}"
        lines.append(f"      - record: {record_name}")
        lines.append("        labels:")
        lines.append(f"          panel: {json.dumps(label, ensure_ascii=True)}")
        lines.append("        expr: |")
        for expr_line in expr.splitlines():
            lines.append(f"          {expr_line}")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate SetLog dashboard, panel, and query assets.")
    parser.add_argument("--dashboard-rules-out", type=Path)
    args = parser.parse_args()

    validate_golden_dashboard()
    validate_support_dashboards()
    validate_dashboard_provisioning()
    validate_doc_panel_references()
    expressions = validate_dashboard_queries()
    expressions.extend(validate_alerting_file())
    if args.dashboard_rules_out:
        write_dashboard_rule_file(args.dashboard_rules_out, expressions)

    print(f"validated {len(expressions)} Grafana dashboard and alert queries")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
