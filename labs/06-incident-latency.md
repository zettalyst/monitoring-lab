# 06. Incident 1: 서비스 지연 모의 대응

## 배경

SetLog 사용자는 친구들과 같은 방에 들어가 매 시간 짧은 clip을 찍고, 서로의 현재 시간대 기록이 방 feed에 채워지는지 확인한다. 평소에는 정각에 찍은 clip이 곧바로 친구 방 timeline에 붙지만, 이번 실습에서는 "방금 찍은 2초 영상이 계속 업로드 중으로 남는다", "친구가 찍었다고 했는데 내 feed에는 이전 시간대만 보인다"는 신고가 들어온다.

## 문제 상황

진행자가 서비스 지연 Incident를 시작한다. 참가자는 원인을 바로 단정하지 말고, 사용자가 실제로 기다리는 흐름과 page signal을 먼저 확인한다.

- latency가 언제부터 올랐는가?
- 현재 시간대 clip 업로드, 친구 방 feed 확인, daily vlog render 중 어떤 여정이 영향을 받는가?
- error가 주된 증상인가, latency가 주된 증상인가?
- DB pool, CPU, dependency, 로그 중 어떤 보조 신호가 같은 시점에 움직이는가?
- 완화 뒤 같은 사용자 여정이 다시 baseline에 가까워졌는가?

## Incident 시작

진행자가 공용 실습 환경에서 Incident를 시작했다면 아래 명령은 실행하지 않는다. 로컬에서 혼자 실습할 때만 한 줄로 시작한다. 이 스크립트는 fault를 한 번 주입한 뒤 종료한다. 관측 traffic은 Compose의 `baseline-traffic` 서비스가 계속 만든다.

| 환경 | 명령 |
|---|---|
| macOS, Linux, WSL, Git Bash | `sh scripts/incident-1-start.sh` |
| PowerShell | `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\incident-1-start.ps1` |
| cmd | `scripts\incident-1-start.cmd` |

`Incident 1 is active` 메시지가 출력되면 Grafana에서 표를 작성한다.

## Grafana / PromQL 관찰

Grafana의 `SetLog Incident Response` 대시보드에서 시간 범위를 최근 15분으로 맞춘다.

바로 열기:

- [I1 Page: API p95 by Journey](http://localhost:3000/d/setlog-incident-response/setlog-incident-response?orgId=1&from=now-15m&to=now&refresh=5s&viewPanel=101)
- [I1 Impact: Traffic and Status by API](http://localhost:3000/d/setlog-incident-response/setlog-incident-response?orgId=1&from=now-15m&to=now&refresh=5s&viewPanel=102)
- [I1 Diagnostic: DB Pool Saturation](http://localhost:3000/d/setlog-incident-response/setlog-incident-response?orgId=1&from=now-15m&to=now&refresh=5s&viewPanel=103)
- [Alert: setlog-i1-high-latency](http://localhost:3000/alerting/grafana/setlog-i1-high-latency/view?orgId=1)

| 구분 | 볼 것 | 질문 |
|---|---|---|
| 페이지 조건 | `I1 Page: API p95 by Journey` | 사용자 요청이 baseline보다 오래 기다리는가? |
| 영향 범위 | `Latency by API` | upload, feed, render 중 어디가 느린가? |
| Error | `I1 Impact: Traffic and Status by API` | 실패율이 주된 증상인가, 대기 시간이 주된 증상인가? |
| 보조 신호 | `I1 Diagnostic: DB Pool Saturation` | latency 상승과 같은 시점에 pending이 생겼는가? |
| 보조 신호 | `I4 Diagnostic: SetLog CPU Pressure` | setlog 컨테이너 CPU가 latency를 설명할 만큼 같이 움직이는가? |

Prometheus에서 직접 확인한다.

```promql
histogram_quantile(
  0.95,
  sum(rate(http_server_requests_seconds_bucket{job="setlog", uri=~"/api/.*", status!~"5.."}[2m])) by (le, method, uri)
)
```

```promql
hikaricp_connections_pending{job="setlog"}
```

## Linux / Docker 확인

Grafana에서 세운 가설을 컨테이너와 OS 도구로 확인한다.

```sh
docker compose ps
docker compose logs setlog --tail=100
docker stats --no-stream
docker compose exec mysql mysql -uroot -proot -e "SHOW FULL PROCESSLIST"
docker compose exec mysql mysql -N -uroot -proot -e "SELECT ID, INFO FROM information_schema.PROCESSLIST WHERE INFO LIKE '%SETLOG_I1_DB_POOL_HOLDER%'"
```

확인할 것:

- setlog와 mysql 컨테이너는 살아 있는가?
- MySQL 자체 장애라기보다 `SETLOG_I1_DB_POOL_HOLDER` 세션이 connection을 점유하는 모양인가?
- CPU가 높지 않은데도 latency가 높은가?
- service log에 connection timeout, pending, slow request 흔적이 있는가?

## 완화

아래 제약을 지키면서 실행할 조치와 검증 방법을 먼저 작성한다.

제약:

- 진행자용 reset은 사용하지 않는다.
- baseline traffic은 계속 흐르는 상태에서 조치한다.
- dependency가 정상이라면 dependency부터 재기동하지 않는다.
- 한 번에 하나의 조치만 실행하고, 조치 전후를 같은 증상 지표로 비교한다.

아래 칸에 본인이 실행할 명령을 먼저 적고, 조별로 합의한 뒤 실행한다.

```text
1차 완화 대상:
1차 완화 명령:
상태 확인 명령:
회복 검증 지표:
```

정답 명령은 별도 진행자 문서에만 둔다. 이 실습에서는 멘티가 직접 선택하고 실행한 완화 조치로 회복을 만들어야 한다.

## 실습 문제

아래 표를 직접 채운다. root cause를 바로 맞히려 하지 말고, 사용자 증상에서 시작한다.

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

- 사용자가 기다리는 현상을 사용자 증상으로, p95 latency를 page signal로 기록했다.
- 영향 API와 시작 시점을 적었다.
- DB pool, CPU, dependency, 로그를 diagnostic 신호로 구분했다.
- reset 명령이 아니라 직접 선택한 완화 조치 전후의 p95 latency와 사용자 여정을 비교했다.
