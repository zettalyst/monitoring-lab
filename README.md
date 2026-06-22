# SetLog Incident Response: Grafana, Prometheus 장애 모니터링 실습

이 저장소는 SetLog 운영 장애 대응 워크숍을 위한 로컬 실습 프로젝트입니다. 흐름은 `Baseline 관찰 -> Golden Signals 대시보드 -> 도메인 지표 설계 -> Incident Response -> Runbook/Postmortem`으로 이어집니다.

강의 정본은 Bear note입니다. main에는 Bear에서 생성한 `LECTURE.md`만 배포용 mirror로 둡니다. `slides/`와 `answers/`는 main에서 제외하며, 답안은 추후 answer 브랜치에서 관리합니다. 정본 ID와 sync 절차는 [Bear Source of Truth](docs/bear-source-of-truth.md)를 따릅니다.

## 준비물

- Docker Desktop
- Windows에서는 Docker Desktop의 Linux containers 모드를 사용합니다.
- Java 21은 로컬 개발 때만 필요합니다. 빌드와 테스트는 Dockerized Gradle로 돌립니다.
- 터미널은 2개를 열어두면 편합니다. 하나는 Compose 실행용, 하나는 Incident 시작과 진단용입니다.

지원 터미널:

| 환경 | 실행 방식 |
|---|---|
| macOS, Linux, WSL, Git Bash | `sh scripts/*.sh` |
| Windows PowerShell | `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\*.ps1` |
| Windows cmd | `scripts\*.cmd` |

cmd용 스크립트는 기본 Windows PowerShell을 호출하므로 별도 `pwsh` 설치는 필요 없습니다.

## 빠른 시작

```text
docker compose up --build -d
```

Compose가 `setlog` health를 확인한 뒤 `baseline-traffic` 서비스를 시작합니다. 이 서비스는 여러 worker로 SetLog 정상 트래픽을 계속 보내서 Grafana와 Prometheus에 baseline을 자동으로 쌓습니다. 실습 전 깨끗한 상태가 필요하면 명시적으로 `sh scripts/fault-clear.sh`를 실행합니다. `baseline-traffic` 시작 시 fault를 자동으로 지우려면 `BASELINE_CLEAR_FAULTS_ON_START=1 docker compose up -d --force-recreate baseline-traffic`처럼 opt-in으로 실행합니다.

접속 주소:

- SetLog service: http://localhost:8080
- Prometheus: http://localhost:9090
- Grafana: http://localhost:3000
- Node Exporter: http://localhost:9100/metrics
- cAdvisor: http://localhost:8081/metrics
- mysqld_exporter: http://localhost:9104/metrics

Grafana 기본 로그인:

- User: `admin`
- Password: `admin`

Grafana에서는 `SetLog` 폴더의 `SetLog Incident Response` 대시보드를 주 실습 화면으로 열어 둡니다. Prometheus, cAdvisor, Node Exporter, MySQL 상세 대시보드는 `SetLog Support` 폴더에서 보조 증거 확인용으로 사용합니다.

## 실습 순서

1. [장애 대응 관점의 Monitoring](labs/01-monitoring-intro.md)
2. [Prometheus와 Grafana 기본기](labs/02-prometheus-grafana.md)
3. [정상 상태 Baseline 관찰](labs/03-baseline.md)
4. [SetLog 도메인 지표 설계](labs/04-domain-metrics.md)
5. [Linux 진단 도구 실습](labs/05-linux-diagnostics.md)
6. [Incident 1: SetLog 서비스 지연 대응](labs/06-incident-latency.md)
7. [Incident 2: SetLog 에러 증가 대응](labs/07-incident-errors.md)
8. [Incident 3: SetLog 디스크 압박 대응](labs/08-incident-disk.md)
9. [Incident 4: SetLog CPU Pressure 대응](labs/09-incident-cpu-saturation.md)
10. [Runbook과 Mini Postmortem](labs/10-runbook-postmortem.md)

## SetLog API

macOS, Linux, WSL, Git Bash:

```sh
curl -sS -X POST http://localhost:8080/api/rooms
curl -sS -X POST http://localhost:8080/api/clips \
  -H 'Content-Type: application/json' \
  -d '{"roomId":"room-id-from-create-room","networkType":"wifi"}'
curl -sS -X POST http://localhost:8080/api/render-jobs \
  -H 'Content-Type: application/json' \
  -d '{"roomId":"room-id-from-create-room"}'
curl -sS http://localhost:8080/api/feed
curl -sS http://localhost:8080/actuator/prometheus
```

PowerShell:

```powershell
$room = Invoke-RestMethod -Method Post -Uri http://localhost:8080/api/rooms
Invoke-RestMethod -Method Post -Uri http://localhost:8080/api/clips -ContentType "application/json" -Body (@{ roomId = $room.roomId; networkType = "wifi" } | ConvertTo-Json -Compress)
Invoke-RestMethod -Method Post -Uri http://localhost:8080/api/render-jobs -ContentType "application/json" -Body (@{ roomId = $room.roomId } | ConvertTo-Json -Compress)
Invoke-RestMethod -Uri http://localhost:8080/api/feed
Invoke-RestMethod -Uri http://localhost:8080/actuator/prometheus
```

cmd:

```bat
curl.exe -sS -X POST http://localhost:8080/api/rooms
curl.exe -sS -X POST http://localhost:8080/api/clips -H "Content-Type: application/json" -d "{\"roomId\":\"room-id-from-create-room\",\"networkType\":\"wifi\"}"
curl.exe -sS -X POST http://localhost:8080/api/render-jobs -H "Content-Type: application/json" -d "{\"roomId\":\"room-id-from-create-room\"}"
curl.exe -sS http://localhost:8080/api/feed
curl.exe -sS http://localhost:8080/actuator/prometheus
```

## 트래픽과 Incident 시작

`docker compose up --build -d` 이후에는 baseline 트래픽이 자동으로 생성됩니다. 기본값은 `BASELINE_LOOP_WORKERS=3`, worker당 `COUNT=160`, `SLEEP_SECONDS=0.03`, `RENDER_EVERY=4`이며, `baseline-loop`는 3초 pause 후 반복합니다. Incident 실습과 회복 검증은 이 상시 baseline 트래픽을 전제로 합니다.

자동 baseline loop 상태는 아래처럼 확인합니다.

```text
docker compose logs baseline-traffic --tail=50
```

Incident start 스크립트는 fault를 한 번 주입한 뒤 종료합니다. 멘티는 이미 흐르고 있는 baseline traffic을 보면서 Grafana, Prometheus, Docker/MySQL 명령으로 판단하고 완화 조치를 실행합니다. reset이 필요하면 진행자용 `sh scripts/fault-clear.sh`를 명시적으로 실행합니다.

Incident 시작:

| 작업 | macOS, Linux, WSL, Git Bash | PowerShell | cmd |
|---|---|---|---|
| Incident 1 / service latency | `sh scripts/incident-1-start.sh` | `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\incident-1-start.ps1` | `scripts\incident-1-start.cmd` |
| Incident 2 / error increase | `sh scripts/incident-2-start.sh` | `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\incident-2-start.ps1` | `scripts\incident-2-start.cmd` |
| Incident 3 / disk pressure | `sh scripts/incident-3-start.sh` | `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\incident-3-start.ps1` | `scripts\incident-3-start.cmd` |
| Incident 4 / CPU pressure | `sh scripts/incident-4-start.sh` | `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\incident-4-start.ps1` | `scripts\incident-4-start.cmd` |
| facilitator reset, not mitigation | `sh scripts/fault-clear.sh` | `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\fault-clear.ps1` | `scripts\fault-clear.cmd` |

답안은 main에 포함하지 않습니다. 멘티용 main에는 실행 스크립트와 관찰 템플릿만 둡니다.

## 주요 지표

- Golden Signals: `http_server_requests_seconds`, `up`, `hikaricp_connections_*`, `jvm_*`, `container_*`
- Docker container 리소스 지표: `container_cpu_usage_seconds_total`, `container_memory_working_set_bytes`, `container_fs_reads_bytes_total`, `container_fs_writes_bytes_total`, `container_network_*`
- MySQL dependency 지표: `up{job="mysqld-exporter"}`, `mysql_up`, `mysql_global_status_threads_*`
- `node-exporter`와 `node_*` 지표는 host/machine context 확인용으로 유지합니다. Incident 실습의 CPU, memory, filesystem I/O, network 판단은 cAdvisor의 Docker container 지표를 우선 사용합니다.
- SetLog 도메인 지표: `setlog_clip_uploads_total`, `setlog_clip_upload_duration_seconds`, `setlog_room_sync_duration_seconds`, `setlog_vlog_render_jobs_total`, `setlog_vlog_render_queue_depth`, `setlog_render_debug_log_bytes`
- 증상 기반 page 알림과 원인 후보 diagnostic 신호 예시: [prometheus/rules/setlog-alerts.yml](prometheus/rules/setlog-alerts.yml)
  - Page: p95 latency, 5xx ratio, traffic drop, render failure, render latency/backlog처럼 사용자 영향에 가까운 신호
  - Diagnostic: DB pool pending, mysqld-exporter down, setlog container CPU pressure, render debug log bytes처럼 원인 후보를 좁히는 보조 신호

## 워크시트

- [Triage 질문지](templates/triage.md)
- [Metric 설계 워크시트](templates/metric-design.md)
- [Incident Runbook 템플릿](templates/incident-runbook.md)
- [Mini Postmortem 템플릿](templates/mini-postmortem.md)

답안 파일은 main에 포함하지 않습니다. 추후 answer 브랜치에서 `answers/` 디렉터리로 관리합니다.

## 검증

로컬에 Gradle이 없어도 Docker로 테스트합니다. 전체 검증은 Bear mirror stale 여부, Compose config, Grafana dashboard/panel/query, Prometheus rule, shell syntax, Dockerized Gradle test를 확인합니다.

전체 검증:

| 환경 | 명령 |
|---|---|
| macOS, Linux, WSL, Git Bash | `sh scripts/verify.sh` |
| PowerShell | `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify.ps1` |
| cmd | `scripts\verify.cmd` |

개별 검증:

macOS, Linux, WSL, Git Bash:

```sh
docker run --rm -v "$PWD/demo-service:/workspace" -w /workspace gradle:9.5.1-jdk21 gradle --no-daemon test
docker compose config
python3 scripts/sync-bear-sources.py --check
python3 scripts/sync-bear-sources.py --check --include-answers
python3 scripts/verify-setlog-assets.py --dashboard-rules-out /tmp/setlog-dashboard-rules.yml
python3 -m json.tool grafana/dashboards/setlog/golden-signals.json >/tmp/setlog-dashboard.json
docker run --rm -v "$PWD/prometheus:/etc/prometheus:ro" --entrypoint promtool prom/prometheus:v3.12.0 check config /etc/prometheus/prometheus.yml
docker run --rm -v /tmp/setlog-dashboard-rules.yml:/tmp/setlog-dashboard-rules.yml:ro --entrypoint promtool prom/prometheus:v3.12.0 check rules /tmp/setlog-dashboard-rules.yml
docker compose up --build -d
```

Incident 1~4가 실제 Grafana/Prometheus 신호와 맞게 주입되는지 확인하려면 Docker stack smoke를 별도로 실행합니다.

```sh
sh scripts/verify-incidents.sh
sh scripts/verify-grafana-alerts.sh
sh scripts/verify-live-mitigation.sh
```

PowerShell:

```powershell
docker run --rm -v "${PWD}\demo-service:/workspace" -w /workspace gradle:9.5.1-jdk21 gradle --no-daemon test
docker compose config
Get-Content -Raw .\grafana\dashboards\setlog\golden-signals.json | ConvertFrom-Json | Out-Null
docker compose up --build -d
```

cmd:

```bat
docker run --rm -v "%cd%\demo-service:/workspace" -w /workspace gradle:9.5.1-jdk21 gradle --no-daemon test
docker compose config
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-Content -Raw .\grafana\dashboards\setlog\golden-signals.json | ConvertFrom-Json | Out-Null"
docker compose up --build -d
```

Docker 없이 데모 서비스만 확인할 때는 로컬 Gradle에서 `local` profile을 명시합니다.

```text
gradle --no-daemon bootRun --args="--spring.profiles.active=local"
```

Prometheus target을 확인하려면:

macOS, Linux, WSL, Git Bash:

```sh
curl -sS 'http://localhost:9090/api/v1/query?query=up'
```

PowerShell:

```powershell
Invoke-RestMethod -Uri "http://localhost:9090/api/v1/query?query=up"
```

cmd:

```bat
curl.exe -sS "http://localhost:9090/api/v1/query?query=up"
```

정리:

```text
docker compose down
docker compose down -v
```
