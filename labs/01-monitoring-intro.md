# 01. 장애 대응 관점의 Monitoring

## 목표

- 모니터링을 ~~문제를 자동으로 찾아주는 도구~~가 아니라 **탐색 공간을 줄이는 장치**로 이해한다.
- 로그보다 [Golden Signals](https://sre.google/sre-book/monitoring-distributed-systems/#xref_monitoring_golden-signals)를 먼저 보는 이유를 설명할 수 있다.
- 증상 (Symptoms) 기반 알림과 원인 (Causes) 기반 알림을 구분한다.

## 핵심 개념

장애 초반의 목표는 root cause를 맞히는 일이 아니라 피해를 줄이는 일입니다. 먼저 볼 질문은 네 가지입니다.

1. 언제부터 이상했나?
2. 누가, 어디가, 얼마나 영향받고 있나?
3. 어떤 신호가 먼저 흔들렸나?
4. 조치 후 회복됐나?

강의의 메시지는 단순합니다. 원인을 바로 알림으로 보내기보다 사용자 증상을 알림으로 보냅니다. 원인 정보는 대시보드와 runbook에 담고, 페이지는 사용자 영향이 있는 증상에 겁니다.

## 실습

1. Grafana 대시보드에서 `API Latency p95`, `API Traffic`, `API 5xx Ratio`, `I4 Diagnostic: SetLog CPU Pressure` 패널 위치를 봅니다.
2. [templates/triage.md](../templates/triage.md)를 열고, 본인 서비스에서 장애가 났다고 가정해 적습니다.
3. 아래 문장이 증상 기반인지 원인 기반인지 구분합니다.

| 문장 | 구분 |
|---|---|
| 5xx 응답이 3분 동안 10%를 넘었다 | |
| MySQL primary가 죽었다 | |
| p95 latency가 baseline 대비 7배 상승했다 | |
| 특정 배포 버전의 로그가 많아졌다 | |

## 완료 기준

- Golden Signals 네 가지를 말할 수 있다.
- 장애 초반에 로그보다 지표를 먼저 보는 이유를 설명할 수 있다.
- 증상 기반 페이지 조건을 2개 이상 작성했다.
