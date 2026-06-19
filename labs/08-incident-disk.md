# 08. Incident 3: 디스크 초과 모의 대응

## 배경

SetLog의 daily vlog render는 친구들이 하루 동안 시간대별로 채운 짧은 clip을 하나의 공유 가능한 브이로그로 묶는 핵심 여정이다. render 과정에서 임시 debug log나 산출물이 `/tmp`에 계속 남으면, 앱은 살아 있어도 새로운 daily vlog 결과물을 안정적으로 만들지 못할 수 있다.

사용자가 경험하는 것은 파일 시스템 상태가 아니다. 사용자가 보는 증상은 "하루치 기록을 브이로그로 만들려고 했는데 실패한다", "공유할 결과물이 준비되지 않는다", "다시 눌러도 render 요청이 실패한다"이다.

## 문제 상황

진행자가 디스크 초과 Incident를 시작한다. 참가자는 disk 그래프만 보고 바로 원인 확정하지 않고, daily vlog render 실패가 실제 사용자-visible 증상인지 먼저 판단한다.

- 사용자가 직접 겪는 증상은 무엇인가?
- render job 실패율이 언제부터 얼마나 증가했는가?
- 전체 API가 실패하는가, render 여정에 집중되어 있는가?
- disk 관련 diagnostic 신호가 render 실패와 같은 시점에 움직이는가?
- 완화 뒤 render 요청과 디스크 증거가 함께 회복되는가?

## Incident 시작

진행자가 공용 실습 환경에서 Incident를 시작했다면 아래 명령은 실행하지 않는다. 로컬에서 혼자 실습할 때만 한 줄로 시작한다. 이 스크립트는 disk fault를 한 번 주입한 뒤 종료한다. 관측 traffic은 Compose의 `baseline-traffic` 서비스가 계속 만든다.

| 환경 | 명령 |
|---|---|
| macOS, Linux, WSL, Git Bash | `sh scripts/incident-3-start.sh` |
| PowerShell | `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\incident-3-start.ps1` |
| cmd | `scripts\incident-3-start.cmd` |

`Incident 3 is active` 메시지가 출력되면 Grafana에서 표를 작성한다.

## Grafana / PromQL 관찰

바로 열기:

- [I3 Page: Render Failure Ratio](http://localhost:3000/d/sre301-golden-signals/sre301-golden-signals-lab?orgId=1&from=now-15m&to=now&refresh=5s&viewPanel=301)
- [I3 Impact: Render Job HTTP Status](http://localhost:3000/d/sre301-golden-signals/sre301-golden-signals-lab?orgId=1&from=now-15m&to=now&refresh=5s&viewPanel=302)
- [I3 Diagnostic: Render Debug Log Size](http://localhost:3000/d/sre301-golden-signals/sre301-golden-signals-lab?orgId=1&from=now-15m&to=now&refresh=5s&viewPanel=303)
- [I3 Diagnostic: SetLog Disk I/O](http://localhost:3000/d/sre301-golden-signals/sre301-golden-signals-lab?orgId=1&from=now-15m&to=now&refresh=5s&viewPanel=304)
- [Alert: sre301-i3-render-failures](http://localhost:3000/alerting/grafana/sre301-i3-render-failures/view?orgId=1)

| 구분 | 패널 | 질문 |
|---|---|---|
| 페이지 조건 | `I3 Page: Render Failure Ratio` | disk reason render failure 비율이 증가했는가? |
| 페이지 조건 | `I3 Impact: Render Job HTTP Status` | `/api/render-jobs` 5xx가 사용자 실패로 보이는가? |
| 영향 범위 | `Latency by API` / `I3 Impact: Render Job HTTP Status` | 실패가 render에 집중되는가, 전체 API로 퍼지는가? |
| 보조 신호 | `I3 Diagnostic: Render Debug Log Size` | render debug log bytes가 같은 시점에 증가했는가? |
| 보조 신호 | `I4 Diagnostic: SetLog CPU Pressure` | setlog 컨테이너 CPU가 주된 설명이 아닌가? |

Prometheus에서 직접 확인한다.

```promql
sum(rate(setlog_vlog_render_jobs_total{job="setlog", result="failure", reason="disk"}[2m]))
/
clamp_min(sum(rate(setlog_vlog_render_jobs_total{job="setlog"}[2m])), 0.001)
```

```promql
setlog_render_debug_log_bytes{job="setlog"}
```

다음 쿼리는 영향 API를 확인하는 보조 신호다.

```promql
sum(rate(http_server_requests_seconds_count{job="setlog", uri="/api/render-jobs", status=~"5.."}[1m])) by (status)
```

## Linux / Docker 확인

```sh
docker compose exec setlog df -h
docker compose exec setlog du -sh /tmp
docker compose exec setlog sh -c "ls -lh /tmp/sre301-render-debug.log 2>/dev/null || true"
docker stats --no-stream
docker compose logs setlog --tail=100
```

확인할 것:

- `/tmp` 사용량이 증가했는가?
- `/tmp/sre301-render-debug.log` 파일이 실제로 보이는가?
- render 실패 로그가 disk 관련 증거와 같은 시점인가?
- CPU가 render 실패를 설명할 만큼 높지 않은가?

## 완화

아래 제약을 지키면서 실행할 조치와 검증 방법을 먼저 작성한다.

제약:

- 진행자용 reset은 사용하지 않는다.
- baseline traffic은 계속 흐르는 상태에서 조치한다.
- 디스크 정리와 앱 재시작을 한 번에 섞지 않는다.
- 조치 하나마다 어떤 지표가 회복됐는지 기록한다.

아래 칸에 본인이 실행할 명령을 먼저 적고, 조별로 합의한 뒤 실행한다.

```text
1차 완화 대상:
1차 완화 명령:
1차 검증 지표:

2차 완화 대상:
2차 완화 명령:
2차 검증 지표:

회복 검증 지표:
```

정답 명령은 별도 진행자 문서에만 둔다. 이 실습에서는 멘티가 직접 선택하고 실행한 완화 조치로 회복을 만들어야 한다.

## 실습 문제

아래 표를 직접 채운다. 원인 후보를 쓰기 전에, 사용자가 실제로 겪은 실패와 영향부터 쓴다.

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

- daily vlog 생성 실패를 사용자 증상으로, render failure ratio를 page signal로 기록했다.
- disk/debug log 지표를 page signal이 아니라 diagnostic 신호로 구분했다.
- `df`, `du`, `ls`로 Grafana 가설을 확인했다.
- 직접 실행한 완화 조치 후 render failure ratio와 debug log bytes를 다시 비교했다.
