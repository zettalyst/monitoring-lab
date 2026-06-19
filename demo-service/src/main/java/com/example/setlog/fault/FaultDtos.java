package com.example.setlog.fault;

public final class FaultDtos {

    private FaultDtos() {
    }

    public record LatencyFaultRequest(Integer latencyMs) {
    }

    public record ErrorFaultRequest(Integer errorRatePercent) {
    }

    public record CpuFaultRequest(Boolean enabled, Integer workers) {
    }

    public record DiskFaultRequest(Boolean enabled, Integer megabytes) {
    }

    public record DbPoolFaultRequest(Boolean enabled, Integer holders, Long holdMillis) {
    }

    public record RenderFaultRequest(Boolean enabled, Integer delayMs) {
    }

    public record FaultStatus(
        int latencyMs,
        int errorRatePercent,
        boolean cpuActive,
        int cpuWorkers,
        long diskBytes,
        boolean dbPoolActive,
        int dbPoolHolders,
        boolean renderActive,
        int renderDelayMs
    ) {
    }
}
