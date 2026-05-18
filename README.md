# Prometheus and Grafana

This project contains a Docker Compose based observability stack with Prometheus and Grafana.

## Start

```sh
docker compose up -d
```

Prometheus: http://localhost:9090

Sample App: http://localhost:8080

Node Exporter: http://localhost:9100/metrics

Grafana: http://localhost:3000

Synthetic app metrics: http://localhost:8000/metrics

Dashboards:

- Prometheus Overview
- App Service Metrics
- SRE Golden Signals
- Availability Multiples

Default Grafana login:

- User: `admin`
- Password: `admin`

## Stop

```sh
docker compose down
```

To remove persisted Prometheus and Grafana data:

```sh
docker compose down -v
```

## Add Metrics Targets

Edit `prometheus/prometheus.yml` and add another entry under `scrape_configs`.
For a service running directly on the host, Docker Desktop can usually reach it through `host.docker.internal`.

## 3-week Same-time Median Dashboard

This lab includes a synthetic `seasonal-app` target that exposes `http_requests_total`
for multiple services with weekday and time-of-day seasonality. Prometheus is
configured with 45 days of retention so the dashboard can query samples from
1, 2, and 3 weeks ago.

Backfill historical samples into the Prometheus volume:

```sh
./scripts/backfill-seasonal-traffic.sh
```

Then open Grafana and select the `Traffic Seasonality - 3 Week Median`
dashboard. The core baseline query is:

```promql
quantile_over_time(
  0.5,
  (
    sum by (service) (
      rate(http_requests_total[5m])
    )
  )[2w:1w] offset 1w
)
```

The dashboard range panels use an equivalent explicit-offset expression so the
baseline follows each Grafana timestamp instead of being affected by subquery
step alignment:

```promql
quantile by (service) (
  0.5,
  label_replace(
    sum by (service) (rate(http_requests_total[5m] offset 1w)),
    "seasonal_week", "1w", "service", ".*"
  )
  or
  label_replace(
    sum by (service) (rate(http_requests_total[5m] offset 2w)),
    "seasonal_week", "2w", "service", ".*"
  )
  or
  label_replace(
    sum by (service) (rate(http_requests_total[5m] offset 3w)),
    "seasonal_week", "3w", "service", ".*"
  )
)
```

## Generate Sample App Metrics

```sh
curl http://localhost:8080/
curl http://localhost:8080/health
curl "http://localhost:8080/work?delayMs=250"
curl http://localhost:8080/error
curl http://localhost:8080/metrics
```

For dashboard panels that use `rate()`, generate traffic for at least 30 seconds:

```sh
for i in $(seq 1 30); do
  curl -s "http://localhost:8080/work?delayMs=150" >/dev/null
  if [ $((i % 10)) -eq 0 ]; then curl -s http://localhost:8080/error >/dev/null; fi
  sleep 1
done
```

Prometheus scrapes the app through the `app:8080` target. Useful queries:

```promql
rate(http_requests_total{job="app"}[5m])
histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket{job="app"}[5m])) by (le, route))
sum(rate(http_requests_total{job="app",status_code=~"5.."}[5m])) / clamp_min(sum(rate(http_requests_total{job="app"}[5m])), 0.001)
nodejs_eventloop_lag_p99_seconds{job="app"}
```

## Availability Multiple Practice

The sample app exposes lab-only metrics for practicing critical-situation detection:

```promql
lab_capacity_limit_rps{job="app"}
lab_node_count{job="app"}
```

The `Availability Multiples` dashboard uses these queries:

```promql
# 최대가용배수 = 한계 사용량 / 현재 사용량
max(lab_capacity_limit_rps{job="app"}) / clamp_min(sum(rate(http_requests_total{job="app"}[5m])), 0.001)

# 부하증가배수 = n / (n - 1)
max(lab_node_count{job="app"}) / (max(lab_node_count{job="app"}) - 1)

# 임계상황 = 부하증가배수 > 최대가용배수
(max(lab_node_count{job="app"}) / (max(lab_node_count{job="app"}) - 1)) > bool (max(lab_capacity_limit_rps{job="app"}) / clamp_min(sum(rate(http_requests_total{job="app"}[5m])), 0.001))
```

Generate enough traffic to trigger the critical-situation alert:

```sh
for i in $(seq 1 120); do
  curl -s "http://localhost:8080/work?delayMs=50" >/dev/null &
  curl -s "http://localhost:8080/work?delayMs=50" >/dev/null &
  sleep 0.2
done
wait
```
