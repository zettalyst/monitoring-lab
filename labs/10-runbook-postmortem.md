# 10. Runbook과 Mini Postmortem

## 목표

- 장애가 터지면 바로 펼쳐 실행할 runbook을 쓴다.
- 상황이 정리되면 비난 없이 postmortem으로 배운 걸 남긴다.
- 완화 조치와 root cause 분석을 분리한다.

## Runbook 작성

[templates/incident-runbook.md](../templates/incident-runbook.md)를 복사해 하나의 incident를 기준으로 채웁니다.

반드시 포함할 항목:

- 증상
- 영향 범위
- 먼저 볼 대시보드
- 확인할 PromQL
- Linux 확인 명령어
- 완화 조치
- 회복 검증 방법

## Mini Postmortem 작성

[templates/mini-postmortem.md](../templates/mini-postmortem.md)를 복사해 작성합니다.

강조할 점:

- "누가 실수했나"가 아니라 "어떤 조건에서 탐지가 늦었나"를 적습니다.
- 알림은 원인보다 증상 기반으로 개선합니다.
- 다음 장애 때 더 빨리 줄일 피해를 정합니다.

## 완료 기준

- runbook은 장애 중에도 그대로 실행할 수 있다.
- postmortem은 timeline, impact, detection, mitigation, follow-up을 포함한다.
