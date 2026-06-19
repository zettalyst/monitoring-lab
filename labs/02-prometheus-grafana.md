# 02. Prometheus와 Grafana 기본기

## 목표

- Prometheus pull model, scrape target, time series를 확인한다.
- Grafana datasource와 dashboard provisioning을 살펴본다.
- PromQL의 `rate`, `sum by`, `histogram_quantile`을 실습한다.

## 실행

```sh
docker compose up --build -d
```

Compose는 `setlog`가 healthy가 된 뒤 `baseline-traffic` 서비스를 시작합니다. 이 서비스는 정상 SetLog 트래픽을 계속 만들어 Prometheus에 baseline 시계열을 쌓습니다. 남아 있는 app fault를 지워야 하는 실습 시작점에서는 `sh scripts/fault-clear.sh`를 명시적으로 실행합니다.

Prometheus target 페이지를 엽니다.

```text
http://localhost:9090/targets
```

다음 target이 `UP`인지 봅니다.

- `prometheus`
- `setlog`
- `node-exporter`
- `cadvisor`
- `mysqld-exporter`

## PromQL 실습

Prometheus UI에서 차례로 실행해 봅니다.

```promql
up
```

```promql
sum(rate(http_server_requests_seconds_count{job="setlog", uri=~"/api/.*"}[1m]))
```

```promql
histogram_quantile(
  0.95,
  sum(rate(http_server_requests_seconds_bucket{job="setlog", uri=~"/api/.*", status!~"5.."}[5m])) by (le, method, uri)
)
```

```promql
sum(rate(setlog_clip_uploads_total{job="setlog"}[1m])) by (result, reason, network_type)
```

## 완료 기준

- `setlog`의 scrape endpoint가 `/actuator/prometheus`임을 확인했다.
- Grafana에서 `SetLog Incident Response` 대시보드를 열었다.
- `rate`와 `histogram_quantile`이 왜 counter와 histogram에 쓰이는지 설명할 수 있다.
