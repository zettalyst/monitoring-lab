# 03. 정상 상태 Baseline 관찰

## 목표

- 장애 판단은 "이상한 값"이 아니라 "정상 대비 얼마나 달라졌는가"로 한다.
- 정상 트래픽에서 latency, traffic, errors, saturation 기준값을 기록한다.

## Baseline 트래픽 생성

`docker compose up --build -d`를 실행하면 `baseline-traffic` 서비스가 자동으로 시작됩니다. 이 서비스는 app fault 상태를 먼저 reset한 뒤 `POST /api/rooms`, `POST /api/clips`, `POST /api/render-jobs`, `GET /api/feed`를 약 30 QPS 수준으로 반복 호출합니다.

자동 baseline loop 상태는 아래처럼 확인합니다.

```text
docker compose logs baseline-traffic --tail=50
```

패널을 더 빨리 채우고 싶을 때만 수동으로 추가 트래픽을 보냅니다.

| 환경 | 명령 |
|---|---|
| macOS, Linux, WSL, Git Bash | `sh scripts/baseline-traffic.sh` |
| PowerShell | `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\baseline-traffic.ps1` |
| cmd | `scripts\baseline-traffic.cmd` |

## 기록할 값

| 항목 | PromQL 또는 패널 | 관찰값 |
|---|---|---|
| 정상 RPS | `API Traffic` | |
| p50 latency | `Latency by API` | |
| p95 latency | `API Latency p95` | |
| 5xx error ratio | `API 5xx Ratio` | |
| DB active connections | `I1 Diagnostic: DB Pool Saturation` | |
| DB pending connections | `I1 Diagnostic: DB Pool Saturation` | |
| CPU usage | `I4 Diagnostic: SetLog CPU Pressure` | |
| Container memory | `SetLog Container Memory` | |

## 판단 연습

아래처럼 baseline을 문장으로 남깁니다.

```text
정상 요청량은 대략 __ RPS다.
p95 latency는 대략 __ ms다.
5xx는 정상 상황에서 __%다.
DB pending connection은 정상 상황에서 __개다.
```

## 완료 기준

- 본인 환경의 baseline 값을 표에 기록했다.
- 이후 incident drill에서 baseline 대비 차이를 근거로 설명할 수 있다.
