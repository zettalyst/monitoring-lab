# Prometheus and Grafana

This project contains a Docker Compose based observability stack with Prometheus and Grafana.

## Start

```sh
docker compose up -d
```

Prometheus: http://localhost:9090

Node Exporter: http://localhost:9100/metrics

Grafana: http://localhost:3000

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
