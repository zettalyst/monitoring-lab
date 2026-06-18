# Incident Runbook

## 증상

```text
무엇이 사용자에게 깨져 보이는가:
```

## 먼저 볼 것

| 순서 | 확인 항목 | 링크 또는 PromQL |
|---:|---|---|
| 1 | Latency | |
| 2 | Traffic | |
| 3 | Errors | |
| 4 | Saturation | |

## 확인 명령어

```sh
docker compose ps
docker compose logs setlog --tail=100
docker stats --no-stream
docker compose exec setlog df -h
docker compose exec setlog du -sh /tmp
docker compose exec mysql mysql -uroot -proot -e "SHOW PROCESSLIST"
docker compose logs mysql --tail=100
docker compose logs mysqld-exporter --tail=100
```

## 완화 조치

```text
실행할 조치:
되돌리는 방법:
한 번에 같이 바꾸면 안 되는 것:
```

## 회복 검증

```text
회복으로 볼 지표:
기준값:
관찰값:
```
