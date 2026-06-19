package com.example.setlog.api;

import java.time.Duration;
import java.util.concurrent.atomic.AtomicInteger;

import io.micrometer.core.instrument.Counter;
import io.micrometer.core.instrument.Gauge;
import io.micrometer.core.instrument.MeterRegistry;
import io.micrometer.core.instrument.Timer;
import org.springframework.stereotype.Component;

@Component
class SetLogMetrics {

    private final MeterRegistry registry;
    private final AtomicInteger renderQueueDepth = new AtomicInteger();

    SetLogMetrics(MeterRegistry registry) {
        this.registry = registry;
        Gauge.builder("setlog.vlog.render.queue.depth", renderQueueDepth, AtomicInteger::get)
            .description("Number of SetLog daily vlog render jobs waiting or running.")
            .register(registry);
    }

    void recordClipUpload(String result, String reason, String networkType, Duration duration) {
        Counter.builder("setlog.clip.uploads")
            .description("Total SetLog clip upload attempts.")
            .tag("result", result)
            .tag("reason", reason)
            .tag("network_type", networkType)
            .register(registry)
            .increment();

        Timer.builder("setlog.clip.upload.duration")
            .description("SetLog clip upload duration.")
            .tag("network_type", networkType)
            .publishPercentileHistogram()
            .register(registry)
            .record(duration);
    }

    void recordRoomSync(Duration duration) {
        Timer.builder("setlog.room.sync.duration")
            .description("Time to read the latest room feed.")
            .publishPercentileHistogram()
            .register(registry)
            .record(duration);
    }

    void recordRenderJob(String result, String reason) {
        Counter.builder("setlog.vlog.render.jobs")
            .description("Total SetLog vlog render job attempts.")
            .tag("result", result)
            .tag("reason", reason)
            .register(registry)
            .increment();
    }

    void incrementRenderQueue() {
        renderQueueDepth.incrementAndGet();
    }

    void decrementRenderQueue() {
        renderQueueDepth.updateAndGet(value -> Math.max(0, value - 1));
    }

    int renderQueueDepth() {
        return renderQueueDepth.get();
    }
}
