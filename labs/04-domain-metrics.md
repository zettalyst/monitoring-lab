# 04. SetLog 도메인 지표 설계

## 목표

- 서비스 지표와 도메인 지표를 구분한다.
- Prometheus metric type과 label을 설계한다.
- cardinality 위험 label을 제거한다.

## SetLog 핵심 여정

SetLog는 "친구들과 방을 만들고, 한 시간마다 2초씩 찍으면 하루치 영상을 브이로그처럼 만들 수 있는 앱"이라고 가정합니다.

1. 방 생성
2. 2초 클립 촬영
3. 클립 업로드
4. 친구 방에 동기화
5. 하루치 브이로그 렌더링
6. 공유와 채팅

## 실습

[templates/metric-design.md](../templates/metric-design.md)를 복사한 뒤, 본인 앱 기준으로 채웁니다.

SetLog라면 아래 질문에 답해야 합니다.

- 사용자가 제때 찍을 수 있었는가?
- 찍은 영상이 유실되지 않았는가?
- 친구 방에 늦게 보이지 않았는가?
- 하루치 브이로그가 정상적으로 생성되었는가?
- 공유 가능한 결과물이 만들어졌는가?

## 이 프로젝트의 도메인 지표

```text
setlog_clip_uploads_total{result, reason, network_type}
setlog_clip_upload_duration_seconds{network_type}
setlog_room_sync_duration_seconds
setlog_vlog_render_jobs_total{result, reason}
setlog_vlog_render_queue_depth
```

이 실습 앱에서 `setlog_room_sync_duration_seconds`는 친구 방 feed 조회 시간을 동기화 지연의 proxy로 기록합니다. `setlog_vlog_render_queue_depth`는 별도 비동기 큐가 아니라 동기 render 요청의 in-flight 작업 수를 backlog proxy로 보여줍니다.

## 완료 기준

- Counter, Gauge, Histogram 중 어떤 metric type을 쓸지 설명했다.
- `user_id`, `room_id`, `video_id`, `request_id` 같은 high-cardinality label을 제거했다.
- 본인 서비스의 Golden Signal PromQL을 2개 이상 작성했다.
