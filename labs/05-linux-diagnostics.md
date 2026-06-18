# 05. Linux 진단 도구 실습

이 장의 Linux 명령어는 호스트 OS가 아니라 Docker 컨테이너 안에서 실행합니다. 따라서 Windows, macOS, Linux 호스트 모두 Docker Desktop 또는 Docker Engine이 실행 중이면 같은 방식으로 실습할 수 있습니다.

## 목표

- 지표에서 흔들린 신호를 본 뒤 Linux 도구로 가설을 좁힌다.
- 컨테이너 환경에서도 `df`, `du`, `free`, `netstat`, `dmesg` 계열의 역할을 이해한다.

## 컨테이너 접속

```sh
docker compose exec setlog sh
docker compose exec mysql sh
```

## 명령어

서비스 컨테이너에서 봅니다.

```sh
df -h
du -sh /tmp
free -m
cat /proc/loadavg
cat /proc/meminfo | head
```

MySQL 컨테이너에서 봅니다.

```sh
mysqladmin -uroot -proot status
mysql -uroot -proot -e "SHOW PROCESSLIST"
mysql -uroot -proot -e "SHOW GLOBAL STATUS LIKE 'Threads_%'"
```

호스트에서는 이렇게 봅니다.

```text
docker compose logs setlog --tail=100
docker compose ps
docker stats --no-stream
```

Grafana의 Incident 실습용 saturation 패널은 cAdvisor의 `container_*` 지표를 사용합니다. `node-exporter`와 `node_*` 지표는 host/machine context 확인용으로 유지하지만, setlog 컨테이너의 CPU, memory, filesystem I/O, network 판단은 `container_label_com_docker_compose_service="setlog"`가 붙은 cAdvisor 지표를 우선 봅니다.

## 완료 기준

- Grafana에서 본 saturation 신호와 Linux 명령어 결과를 연결해 설명했다.
- 로그는 root cause 확인에 쓰되, 장애 범위와 시작 시점은 지표로 먼저 판단했다.
