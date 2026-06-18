# 07. Incident 2: 에러 증가 모의 대응

## 배경

SetLog의 핵심 여정은 친구 방을 만들거나 초대 코드로 합류하고, 시간대마다 짧은 clip을 찍어 방 timeline에 채우고, 하루가 끝나면 daily vlog로 묶어 보는 것이다. 사용자는 내부 dependency 이름을 알지 못한다. 사용자가 경험하는 것은 "친구 방을 새로 만들 수 없다", "방에 들어왔는데 지금 시간대 기록을 올릴 수 없다", "찍은 clip이 실패해서 친구들과 같은 하루를 채우지 못한다"는 증상이다.

## 문제 상황

진행자가 에러 증가 Incident를 시작한다. 참가자는 Grafana와 Prometheus를 보고 친구 방 시작, 현재 시간대 clip 업로드, daily vlog 생성 요청 중 어디가 실제로 깨지는지 판단한다.

- 5xx ratio가 언제부터 얼마나 늘었는가?
- traffic 자체가 줄어든 것인가, 요청은 들어오는데 실패하는 것인가?
- 친구 방 생성, 현재 시간대 clip 업로드, daily vlog 생성 요청 중 어떤 사용자 여정이 실패하는가?
- dependency, 로그, 컨테이너 상태 중 어떤 보조 신호가 같은 시점에 흔들리는가?
- 복구 후 실제 API 요청이 다시 성공하는가?

## Incident 시작

진행자가 공용 실습 환경에서 Incident를 시작했다면 아래 명령은 실행하지 않는다. 로컬에서 혼자 실습할 때만 한 줄로 시작한다. 이 스크립트는 실습 준비 traffic과 장애 상태에서의 관측 traffic을 함께 만든다.

| 환경 | 명령 |
|---|---|
| macOS, Linux, WSL, Git Bash | `sh scripts/incident-2-start.sh` |
| PowerShell | `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\incident-2-start.ps1` |
| cmd | `scripts\incident-2-start.cmd` |

실행이 끝나면 "Incident 2 is active" 메시지를 확인하고 Grafana에서 표를 작성한다.

## Grafana / PromQL 관찰

Grafana에서 먼저 `I2 Page: API 5xx Ratio`와 `I2 Impact: 5xx by API`를 본다. 실패가 늘었는지, traffic이 끊긴 것인지 구분한다.

| 구분 | 볼 것 | 질문 |
|---|---|---|
| 페이지 조건 | `I2 Page: API 5xx Ratio` | 5xx ratio가 threshold를 넘었는가? |
| 영향 범위 | `Latency by API` / status by API | 어떤 API가 실패하는가? |
| 도메인 증상 | `I2 Domain: Clip Upload Success vs Failure` | upload success rate가 떨어지는가? |
| 보조 신호 | Prometheus target | dependency exporter가 down인가? |
| 보조 신호 | service logs | DB connection/write failure가 보이는가? |

Prometheus에서 직접 확인한다.

```promql
(
  sum(rate(http_server_requests_seconds_count{job="setlog", uri=~"/api/.*", status=~"5.."}[2m]))
  or vector(0)
)
/
clamp_min(
  (sum(rate(http_server_requests_seconds_count{job="setlog", uri=~"/api/.*"}[2m])) or vector(0)),
  0.001
)
```

```promql
sum(rate(setlog_clip_uploads_total{job="setlog", result="success"}[1m]))
/
clamp_min(sum(rate(setlog_clip_uploads_total{job="setlog"}[1m])), 0.001)
```

다음 쿼리는 원인 후보를 좁히는 보조 신호다. 이것만으로 페이지하지 않는다.

```promql
up{job="mysqld-exporter"}
```

## Linux / Docker 확인

```sh
docker compose ps
docker compose logs setlog --tail=100
docker compose logs mysql --tail=100
docker compose logs mysqld-exporter --tail=100
```

확인할 것:

- setlog는 살아 있지만 사용자 요청이 실패하는가?
- 실패가 특정 API에만 국한되는가, 핵심 여정 전체로 퍼지는가?
- dependency 상태 변화와 5xx ratio 상승 시점이 일치하는가?
- 로그가 Prometheus에서 본 증상과 같은 방향을 가리키는가?

## 완화

아래 제약을 지키면서 실행할 조치와 검증 방법을 먼저 작성한다.

제약:

- 진행자용 reset은 사용하지 않는다.
- 앱을 먼저 재시작하기 전에 dependency 상태를 확인한다.
- 내려간 component만 복구하고, 앱 조치는 5xx가 계속될 때만 추가한다.
- 조치 전후를 같은 증상 지표로 비교한다.

아래 칸에 본인이 실행할 명령을 먼저 적고, 조별로 합의한 뒤 실행한다.

```text
dependency 복구 명령:
dependency 상태 확인 명령:
조건부 앱 조치 명령:
회복 검증 traffic 명령:
```

정답 명령은 별도 진행자 문서에만 둔다. 이 실습에서는 멘티가 직접 선택하고 실행한 완화 조치로 회복을 만들어야 한다.

## 실습 문제

아래 표를 직접 채운다. 원인 후보를 쓰기 전에, 사용자가 실제로 겪은 실패를 먼저 쓴다.

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

- 5xx ratio를 count가 아니라 비율로 계산했다.
- 영향 API와 사용자-visible 증상을 기록했다.
- dependency down 신호를 페이지 조건이 아니라 diagnostic 신호로 구분했다.
- 직접 dependency를 복구한 뒤 5xx ratio와 도메인 성공률을 다시 확인했다.
