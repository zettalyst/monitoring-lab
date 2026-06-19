package com.example.setlog.api;

import java.io.IOException;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.time.Instant;
import java.util.List;
import java.util.Set;
import java.util.UUID;

import javax.sql.DataSource;

import com.example.setlog.fault.FaultState;
import jakarta.annotation.PostConstruct;
import org.springframework.dao.DataAccessException;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.web.server.ResponseStatusException;

import static com.example.setlog.api.SetLogDtos.ClipRequest;
import static com.example.setlog.api.SetLogDtos.ClipResponse;
import static com.example.setlog.api.SetLogDtos.FeedResponse;
import static com.example.setlog.api.SetLogDtos.RenderJobRequest;
import static com.example.setlog.api.SetLogDtos.RenderJobResponse;
import static com.example.setlog.api.SetLogDtos.RoomResponse;

@Service
class SetLogService {

    private static final Set<String> NETWORK_TYPES = Set.of("wifi", "cellular", "unknown");
    private static final int RENDER_ARTIFACT_BYTES = 12 * 1024 * 1024;
    private static volatile double renderCpuSink;

    private final JdbcTemplate jdbcTemplate;
    private final SetLogMetrics metrics;
    private final FaultState faultState;

    SetLogService(DataSource dataSource, SetLogMetrics metrics, FaultState faultState) {
        this.jdbcTemplate = new JdbcTemplate(dataSource);
        this.metrics = metrics;
        this.faultState = faultState;
    }

    @PostConstruct
    void initializeSchema() {
        jdbcTemplate.execute("""
            CREATE TABLE IF NOT EXISTS rooms (
                room_id VARCHAR(64) PRIMARY KEY,
                created_at TIMESTAMP NOT NULL
            )
            """);
        jdbcTemplate.execute("""
            CREATE TABLE IF NOT EXISTS clips (
                clip_id VARCHAR(64) PRIMARY KEY,
                room_id VARCHAR(64) NOT NULL,
                network_type VARCHAR(32) NOT NULL,
                uploaded_at TIMESTAMP NOT NULL
            )
            """);
        jdbcTemplate.execute("""
            CREATE TABLE IF NOT EXISTS render_jobs (
                job_id VARCHAR(64) PRIMARY KEY,
                room_id VARCHAR(64) NOT NULL,
                status VARCHAR(32) NOT NULL,
                created_at TIMESTAMP NOT NULL
            )
            """);
    }

    RoomResponse createRoom() {
        faultState.applyApiLatency();
        faultState.applyDbPoolContention();
        String roomId = "room-" + UUID.randomUUID();
        jdbcTemplate.update("INSERT INTO rooms(room_id, created_at) VALUES (?, CURRENT_TIMESTAMP)", roomId);
        return new RoomResponse(roomId, "created");
    }

    ClipResponse uploadClip(ClipRequest request) {
        faultState.applyApiLatency();
        faultState.applyDbPoolContention();
        String roomId = requireText(request.roomId(), "roomId");
        String networkType = normalizeNetworkType(request.networkType());
        String clipId = "clip-" + UUID.randomUUID();
        Instant startedAt = Instant.now();
        String result = "failure";
        String reason = "db";

        try {
            ensureRoomExists(roomId);
            jdbcTemplate.update(
                "INSERT INTO clips(clip_id, room_id, network_type, uploaded_at) VALUES (?, ?, ?, CURRENT_TIMESTAMP)",
                clipId,
                roomId,
                networkType
            );
            result = "success";
            reason = "none";
            return new ClipResponse(clipId, roomId, networkType, "uploaded");
        } catch (DataAccessException exception) {
            throw new ResponseStatusException(HttpStatus.SERVICE_UNAVAILABLE, "clip upload failed: database write failed", exception);
        } finally {
            metrics.recordClipUpload(result, reason, networkType, Duration.between(startedAt, Instant.now()));
        }
    }

    RenderJobResponse renderDailyVlog(RenderJobRequest request) {
        faultState.applyApiLatency();
        faultState.applyDbPoolContention();
        String roomId = requireText(request.roomId(), "roomId");
        String jobId = "render-" + UUID.randomUUID();
        metrics.incrementRenderQueue();
        String result = "failure";
        String reason = "db";

        try {
            ensureRoomExists(roomId);
            if (faultState.renderDiskPressureActive()) {
                reason = "disk";
                writeTemporaryRenderArtifact(jobId);
            }
            int renderDelayMs = faultState.renderDelayMs();
            if (renderDelayMs > 0) {
                sleepForDemoWork(renderDelayMs);
            }
            int renderCpuWorkMillis = faultState.renderCpuWorkMillis();
            if (renderCpuWorkMillis > 0) {
                burnCpuForDemoWork(renderCpuWorkMillis);
            }
            sleepForDemoWork(75);
            jdbcTemplate.update(
                "INSERT INTO render_jobs(job_id, room_id, status, created_at) VALUES (?, ?, ?, CURRENT_TIMESTAMP)",
                jobId,
                roomId,
                "completed"
            );
            result = "success";
            reason = "none";
            return new RenderJobResponse(jobId, roomId, "completed");
        } catch (DataAccessException exception) {
            throw new ResponseStatusException(HttpStatus.SERVICE_UNAVAILABLE, "render job failed: database write failed", exception);
        } finally {
            metrics.recordRenderJob(result, reason);
            metrics.decrementRenderQueue();
        }
    }

    FeedResponse readFeed() {
        faultState.applyApiLatency();
        faultState.applyDbPoolContention();
        Instant startedAt = Instant.now();
        try {
            List<ClipResponse> clips = jdbcTemplate.query(
                "SELECT clip_id, room_id, network_type FROM clips ORDER BY uploaded_at DESC LIMIT 20",
                (row, rowNumber) -> new ClipResponse(
                    row.getString("clip_id"),
                    row.getString("room_id"),
                    row.getString("network_type"),
                    "visible"
                )
            );
            return new FeedResponse(clips, metrics.renderQueueDepth());
        } finally {
            metrics.recordRoomSync(Duration.between(startedAt, Instant.now()));
        }
    }

    private void ensureRoomExists(String roomId) {
        Integer count = jdbcTemplate.queryForObject("SELECT COUNT(*) FROM rooms WHERE room_id = ?", Integer.class, roomId);
        if (count == null || count == 0) {
            throw new ResponseStatusException(HttpStatus.NOT_FOUND, "roomId does not exist: " + roomId);
        }
    }

    private String normalizeNetworkType(String value) {
        String networkType = value == null || value.isBlank() ? "unknown" : value.trim().toLowerCase();
        if (!NETWORK_TYPES.contains(networkType)) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST, "networkType must be one of wifi, cellular, unknown");
        }
        return networkType;
    }

    private String requireText(String value, String fieldName) {
        if (value == null || value.isBlank()) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST, fieldName + " is required");
        }
        return value.trim();
    }

    private void sleepForDemoWork(long millis) {
        try {
            Thread.sleep(millis);
        } catch (InterruptedException exception) {
            Thread.currentThread().interrupt();
            throw new ResponseStatusException(HttpStatus.SERVICE_UNAVAILABLE, "render job interrupted", exception);
        }
    }

    private void burnCpuForDemoWork(long millis) {
        long deadline = System.nanoTime() + Duration.ofMillis(millis).toNanos();
        double local = 0.0;
        while (System.nanoTime() < deadline) {
            local += Math.sqrt(System.nanoTime());
            if (local > 1_000_000) {
                renderCpuSink = local;
                local = 0.0;
            }
        }
        renderCpuSink = local;
    }

    private void writeTemporaryRenderArtifact(String jobId) {
        Path path = Path.of(System.getProperty("java.io.tmpdir"), jobId + ".artifact.tmp");
        byte[] chunk = (
            "setlog render artifact job=" + jobId + " frame-buffer-padding\n"
        ).getBytes(StandardCharsets.UTF_8);
        int writtenBytes = 0;

        try (OutputStream output = Files.newOutputStream(path)) {
            while (writtenBytes < RENDER_ARTIFACT_BYTES) {
                int length = Math.min(chunk.length, RENDER_ARTIFACT_BYTES - writtenBytes);
                output.write(chunk, 0, length);
                writtenBytes += length;
            }
        } catch (IOException exception) {
            deleteTemporaryRenderArtifact(path);
            throw new ResponseStatusException(
                HttpStatus.SERVICE_UNAVAILABLE,
                "render job failed: temporary render artifact could not be written because /tmp is full",
                exception
            );
        }

        deleteTemporaryRenderArtifact(path);
    }

    private void deleteTemporaryRenderArtifact(Path path) {
        try {
            Files.deleteIfExists(path);
        } catch (IOException exception) {
            throw new ResponseStatusException(
                HttpStatus.SERVICE_UNAVAILABLE,
                "render job failed: temporary render artifact cleanup failed: " + exception.getMessage(),
                exception
            );
        }
    }
}
