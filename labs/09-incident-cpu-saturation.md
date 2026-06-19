# 09. Incident 4: CPU Pressure 모의 대응

## 배경

SetLog 사용자는 하루치 clip을 daily vlog로 묶고, 결과물을 바로 저장하거나 친구에게 공유한다. render worker가 CPU를 과도하게 사용하면 앱은 살아 있어도 render 요청과 feed 확인이 느려질 수 있다. 사용자가 경험하는 것은 "render를 눌렀는데 계속 기다린다", "앱 반응이 둔하다", "결과물이 늦게 준비된다"는 증상이다.

## 문제 상황

진행자가 CPU pressure와 render 지연이 함께 보이는 Incident를 시작한다. 참가자는 CPU 그래프만 보고 page하지 않고, 사용자-visible latency와 render backlog가 실제로 움직이는지 먼저 판단한다.

- 사용자가 직접 겪는 증상은 무엇인가?
- CPU 상승과 render latency 상승 시점이 일치하는가?
- disk/debug log 증가 없이도 CPU가 지연을 설명하는가?
- render queue depth가 backlog를 실제로 보여주는가?
- 완화 뒤 CPU, render latency, render queue depth가 어떻게 회복되는가?

## Incident 시작

진행자가 공용 실습 환경에서 Incident를 시작했다면 아래 명령은 실행하지 않는다. 로컬에서 혼자 실습할 때만 한 줄로 시작한다. 이 스크립트는 CPU fault를 한 번 주입한 뒤 종료한다. 관측 traffic은 Compose의 `baseline-traffic` 서비스가 계속 만든다.

| 환경 | 명령 |
|---|---|
| macOS, Linux, WSL, Git Bash | `sh scripts/incident-4-start.sh` |
| PowerShell | `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\incident-4-start.ps1` |
| cmd | `scripts\incident-4-start.cmd` |

`Incident 4 is active` 메시지가 출력되면 Grafana에서 표를 작성한다.

## Grafana / PromQL 관찰

바로 열기:

- [I4 Page: Render p95 Latency](http://localhost:3000/d/setlog-incident-response/setlog-incident-response?orgId=1&from=now-15m&to=now&refresh=5s&viewPanel=401)
- [I4 Page: Render Queue Depth](http://localhost:3000/d/setlog-incident-response/setlog-incident-response?orgId=1&from=now-15m&to=now&refresh=5s&viewPanel=402)
- [I4 Diagnostic: SetLog CPU Pressure](http://localhost:3000/d/setlog-incident-response/setlog-incident-response?orgId=1&from=now-15m&to=now&refresh=5s&viewPanel=403)
- [I4 Guardrail: Disk Debug Log Size](http://localhost:3000/d/setlog-incident-response/setlog-incident-response?orgId=1&from=now-15m&to=now&refresh=5s&viewPanel=404)
- [Alert: setlog-i4-render-latency](http://localhost:3000/alerting/grafana/setlog-i4-render-latency/view?orgId=1)
- [Alert: setlog-i4-render-backlog](http://localhost:3000/alerting/grafana/setlog-i4-render-backlog/view?orgId=1)

| 구분 | 패널 | 질문 |
|---|---|---|
| 페이지 조건 | `I4 Page: Render p95 Latency` | 사용자가 기다리는 시간이 늘었는가? |
| 페이지 조건 | `I4 Page: Render Queue Depth` | render queue depth가 올라가는가? |
| 도메인 증상 | `Render Jobs by Result` / `I4 Page: Render Queue Depth` | render failure보다 render 지연과 backlog가 주된 증상인가? |
| 보조 신호 | `I4 Diagnostic: SetLog CPU Pressure` | setlog 컨테이너 CPU 상승이 같은 시점인가? |
| 보조 신호 | `I4 Guardrail: Disk Debug Log Size` | debug log bytes는 주된 설명이 아닌가? |

Prometheus에서 직접 확인한다.

```promql
histogram_quantile(
  0.95,
  sum(rate(http_server_requests_seconds_bucket{job="setlog", uri="/api/render-jobs"}[2m])) by (le)
)
```

```promql
setlog_vlog_render_queue_depth{job="setlog"}
```

다음 쿼리는 원인 후보를 좁히는 보조 신호다.

```promql
(
  sum(rate(container_cpu_usage_seconds_total{job="cadvisor", container_label_com_docker_compose_service="setlog"}[2m]))
  /
  clamp_min(
    sum(
      container_spec_cpu_quota{job="cadvisor", container_label_com_docker_compose_service="setlog"}
      /
      container_spec_cpu_period{job="cadvisor", container_label_com_docker_compose_service="setlog"}
    ),
    0.001
  )
)
```

## Linux / Docker 확인

```sh
docker stats --no-stream
docker compose logs setlog --tail=100
docker compose exec setlog df -h
docker compose exec setlog sh -c "ls -lh /tmp/setlog-render-debug.log 2>/dev/null || true"
```

확인할 것:

- CPU 사용률 상승이 setlog와 관련 있는가?
- setlog는 살아 있지만 사용자 요청이 느린가?
- disk/debug log 증거는 큰 변화가 없는가?
- render queue depth와 render latency가 사용자 증상과 더 직접적으로 연결되는가?

## 완화

아래 제약을 지키면서 실행할 조치와 검증 방법을 먼저 작성한다.

제약:

- 진행자용 reset은 사용하지 않는다.
- baseline traffic은 계속 흐르는 상태에서 조치한다.
- disk cleanup으로 CPU 문제를 해결하려고 하지 않는다.
- 조치 전후를 같은 증상 지표로 비교한다.

아래 칸에 본인이 실행할 명령을 먼저 적고, 조별로 합의한 뒤 실행한다.

```text
1차 완화 대상:
1차 완화 명령:
1차 검증 지표:

회복 검증 지표:
```

정답 명령은 별도 진행자 문서에만 둔다. 이 실습에서는 멘티가 직접 선택하고 실행한 완화 조치로 회복을 만들어야 한다.

## 실습 문제

아래 표를 직접 채운다. 원인 후보를 쓰기 전에, 사용자가 실제로 겪은 지연과 영향부터 쓴다.

| 항목 | 답 |
|---|---|
| 사용자 증상 (Symptoms) |  |
| 영향 범위와 심각도 (Incident Impact) |  |
| 페이지 시그널 (Alert / Page Signal) |  |
| 함께 움직인 Diagnostic 신호 |  |
| Linux / Docker에서 확인한 증거 (Evidence) |  |
| 원인 가설 (Hypothesis) |  |
| 완화 조치 (Mitigation) |  |
| 회복 검증 (Recovery Validation) |  |

## 완료 기준

- render/API 지연을 사용자 증상으로, latency와 queue depth를 page signal로 기록했다.
- CPU pressure를 page signal이 아니라 diagnostic 신호로 구분했다.
- `docker stats`로 Grafana 가설을 확인했다.
- 직접 실행한 완화 조치 후 CPU, render queue, p95 latency를 다시 비교했다.
