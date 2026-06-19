package com.example.setlog;

import java.time.Duration;
import java.time.Instant;
import java.util.Map;

import com.example.setlog.api.SetLogDtos.RoomResponse;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.client.TestRestTemplate;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.test.context.ActiveProfiles;

import static org.assertj.core.api.Assertions.assertThat;

@ActiveProfiles("test")
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT)
class SetLogApplicationTests {

    @Autowired
    private TestRestTemplate restTemplate;

    @Test
    void healthEndpointIsExposed() {
        ResponseEntity<String> response = restTemplate.getForEntity("/actuator/health", String.class);

        assertThat(response.getStatusCode()).isEqualTo(HttpStatus.OK);
        assertThat(response.getBody()).contains("\"status\":\"UP\"");
    }

    @Test
    void prometheusEndpointContainsDomainMetricsAfterUpload() {
        RoomResponse room = restTemplate.postForObject("/api/rooms", Map.of(), RoomResponse.class);

        ResponseEntity<String> clipResponse = restTemplate.postForEntity(
            "/api/clips",
            Map.of("roomId", room.roomId(), "networkType", "wifi"),
            String.class
        );
        String metrics = restTemplate.getForObject("/actuator/prometheus", String.class);

        assertThat(clipResponse.getStatusCode()).isEqualTo(HttpStatus.OK);
        assertThat(metrics)
            .contains("setlog_clip_uploads_total")
            .contains("setlog_clip_upload_duration_seconds_count");
    }

    @Test
    void faultValidationReturnsExplicitBadRequest() {
        ResponseEntity<String> response = restTemplate.postForEntity(
            "/internal/faults/latency",
            Map.of("latencyMs", -1),
            String.class
        );

        assertThat(response.getStatusCode()).isEqualTo(HttpStatus.BAD_REQUEST);
        assertThat(response.getBody()).contains("latencyMs must be between 0 and 5000");
    }

    @Test
    void latencyFaultDelaysApiHandlerWork() {
        ResponseEntity<String> faultResponse = restTemplate.postForEntity(
            "/internal/faults/latency",
            Map.of("latencyMs", 120),
            String.class
        );

        Instant startedAt = Instant.now();
        ResponseEntity<String> apiResponse = restTemplate.postForEntity("/api/rooms", Map.of(), String.class);
        Duration elapsed = Duration.between(startedAt, Instant.now());

        assertThat(faultResponse.getStatusCode()).isEqualTo(HttpStatus.OK);
        assertThat(apiResponse.getStatusCode()).isEqualTo(HttpStatus.OK);
        assertThat(elapsed).isGreaterThanOrEqualTo(Duration.ofMillis(80));

        restTemplate.delete("/internal/faults");
    }

    @Test
    void renderFaultStatusIncludesDelayState() {
        ResponseEntity<String> response = restTemplate.postForEntity(
            "/internal/faults/render",
            Map.of("enabled", true, "delayMs", 4000),
            String.class
        );

        assertThat(response.getStatusCode()).isEqualTo(HttpStatus.OK);
        assertThat(response.getBody())
            .contains("\"renderActive\":true")
            .contains("\"renderDelayMs\":4000");

        restTemplate.delete("/internal/faults");
    }

    @Test
    void dbPoolFaultHolderEventuallyStopsInsteadOfReacquiringForever() throws InterruptedException {
        ResponseEntity<String> response = restTemplate.postForEntity(
            "/internal/faults/db-pool",
            Map.of("enabled", true, "holders", 1, "holdMillis", 1000),
            String.class
        );

        assertThat(response.getStatusCode()).isEqualTo(HttpStatus.OK);

        String status = "";
        for (int attempt = 0; attempt < 20; attempt++) {
            status = restTemplate.getForObject("/internal/faults", String.class);
            if (status != null && status.contains("\"dbPoolActive\":false")) {
                break;
            }
            Thread.sleep(150);
        }

        assertThat(status).contains("\"dbPoolActive\":false");
    }

    @Test
    void resetReturnsImmediatelyWhileDbPoolHolderIsSleeping() {
        ResponseEntity<String> response = restTemplate.postForEntity(
            "/internal/faults/db-pool",
            Map.of("enabled", true, "holders", 1, "holdMillis", 60000),
            String.class
        );

        Instant startedAt = Instant.now();
        restTemplate.delete("/internal/faults");
        Duration elapsed = Duration.between(startedAt, Instant.now());
        String status = restTemplate.getForObject("/internal/faults", String.class);

        assertThat(response.getStatusCode()).isEqualTo(HttpStatus.OK);
        assertThat(elapsed).isLessThan(Duration.ofSeconds(2));
        assertThat(status).contains("\"dbPoolActive\":false");
    }

    @Test
    void renderFaultValidationReturnsExplicitBadRequest() {
        ResponseEntity<String> response = restTemplate.postForEntity(
            "/internal/faults/render",
            Map.of("enabled", true, "delayMs", 0),
            String.class
        );

        assertThat(response.getStatusCode()).isEqualTo(HttpStatus.BAD_REQUEST);
        assertThat(response.getBody()).contains("delayMs must be between 1 and 30000");
    }

    @Test
    void diskFaultExposesRetainedRenderDebugLogMetric() {
        ResponseEntity<String> faultResponse = restTemplate.postForEntity(
            "/internal/faults/disk",
            Map.of("enabled", true, "megabytes", 1),
            String.class
        );
        String metrics = restTemplate.getForObject("/actuator/prometheus", String.class);

        assertThat(faultResponse.getStatusCode()).isEqualTo(HttpStatus.OK);
        assertThat(faultResponse.getBody()).contains("\"diskBytes\":1048576");
        assertThat(metrics).contains("setlog_render_debug_log_bytes");

        restTemplate.delete("/internal/faults");
    }
}
