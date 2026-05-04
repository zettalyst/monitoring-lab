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

Dashboards:

- Prometheus Overview
- App Service Metrics

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

## Generate Sample App Metrics

```sh
curl http://localhost:8080/
curl http://localhost:8080/health
curl "http://localhost:8080/work?delayMs=250"
curl http://localhost:8080/metrics
```

For dashboard panels that use `rate()`, generate traffic for at least 30 seconds:

```sh
for i in $(seq 1 30); do
  curl -s "http://localhost:8080/work?delayMs=150" >/dev/null
  sleep 1
done
```

Prometheus scrapes the app through the `app:8080` target. Useful queries:

```promql
rate(http_requests_total{job="app"}[5m])
histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket{job="app"}[5m])) by (le, route))
```
