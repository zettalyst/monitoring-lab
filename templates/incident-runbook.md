# Incident Runbook

## 증상

```text
무엇이 사용자에게 깨져 보이는가:
```

## 먼저 볼 것

Incident start 스크립트는 fault를 한 번 주입한 뒤 종료한다. baseline traffic은 Compose 서비스가 계속 만들며, `fault-clear`는 reset이지 멘티 완화 조치가 아니다.

| 순서 | 확인 항목 | 링크 또는 PromQL |
|---:|---|---|
| 1 | Latency | |
| 2 | Traffic | |
| 3 | Errors | |
| 4 | Saturation | |
| 5 | Grafana alert direct link | |

## 확인 명령어

```sh
docker compose ps
docker compose logs setlog --tail=100
docker stats --no-stream
docker compose exec setlog df -h
docker compose exec setlog du -sh /tmp
docker compose exec mysql mysql -uroot -proot -e "SHOW FULL PROCESSLIST"
docker compose exec mysql mysql -N -uroot -proot -e "SELECT ID, INFO FROM information_schema.PROCESSLIST WHERE INFO LIKE '%SETLOG_I1_DB_POOL_HOLDER%'"
docker compose logs mysql --tail=100
docker compose logs mysqld-exporter --tail=100
```

## 완화 조치

```text
판단:
실행할 조치:
되돌리는 방법:
한 번에 같이 바꾸면 안 되는 것:
조치 후 같은 조건으로 다시 볼 지표:
```

## 회복 검증

```text
회복으로 볼 지표:
기준값:
관찰값:
상시 baseline traffic에서 회복됐는지:
```
