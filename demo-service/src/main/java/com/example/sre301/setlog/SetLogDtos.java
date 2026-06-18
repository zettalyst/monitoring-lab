package com.example.sre301.setlog;

import java.util.List;

public final class SetLogDtos {

    private SetLogDtos() {
    }

    public record RoomResponse(String roomId, String status) {
    }

    public record ClipRequest(String roomId, String networkType) {
    }

    public record ClipResponse(String clipId, String roomId, String networkType, String status) {
    }

    public record RenderJobRequest(String roomId) {
    }

    public record RenderJobResponse(String jobId, String roomId, String status) {
    }

    public record FeedResponse(List<ClipResponse> clips, int renderQueueDepth) {
    }
}
