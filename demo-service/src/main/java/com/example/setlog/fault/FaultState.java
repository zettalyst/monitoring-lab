package com.example.setlog.fault;

import java.io.IOException;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.Connection;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.ThreadLocalRandom;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;

import javax.sql.DataSource;

import io.micrometer.core.instrument.Gauge;
import io.micrometer.core.instrument.MeterRegistry;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Component;
import org.springframework.web.server.ResponseStatusException;

import static com.example.setlog.fault.FaultDtos.FaultStatus;

@Component
public class FaultState {

    private static final int MAX_LATENCY_MS = 5000;
    private static final int MAX_CPU_WORKERS = 4;
    private static final int MAX_DISK_MEGABYTES = 256;
    private static final int MAX_DB_HOLDERS = 10;
    private static final long MAX_DB_HOLD_MILLIS = 600_000;
    private static final long DB_POOL_CONTENTION_MILLIS = 800;
    private static final String DB_POOL_HOLDER_MARKER = "SETLOG_I1_DB_POOL_HOLDER";
    private static final int MAX_RENDER_DELAY_MS = 30_000;
    private static final int CPU_RENDER_WORK_MILLIS = 2500;

    private static volatile double cpuSink;

    private final DataSource dataSource;
    private final AtomicInteger latencyMs = new AtomicInteger();
    private final AtomicInteger errorRatePercent = new AtomicInteger();
    private final AtomicBoolean cpuActive = new AtomicBoolean();
    private final AtomicInteger cpuWorkers = new AtomicInteger();
    private final AtomicBoolean dbPoolActive = new AtomicBoolean();
    private final AtomicInteger dbPoolHolders = new AtomicInteger();
    private final AtomicBoolean renderActive = new AtomicBoolean();
    private final AtomicInteger renderDelayMs = new AtomicInteger();
    private final List<Thread> cpuThreads = new ArrayList<>();
    private final List<Thread> dbThreads = new ArrayList<>();
    private final List<Connection> dbConnections = new ArrayList<>();
    private final List<Statement> dbStatements = new ArrayList<>();

    private Path diskPressureFile;
    private volatile long diskBytes;

    FaultState(DataSource dataSource, MeterRegistry registry) {
        this.dataSource = dataSource;
        Gauge.builder("setlog.render.debug.log.bytes", this, FaultState::diskBytes)
            .description("Bytes retained in the SetLog render debug log during disk pressure incidents.")
            .register(registry);
    }

    String beforeApiRequest() {
        int errorRate = errorRatePercent.get();
        if (errorRate > 0 && ThreadLocalRandom.current().nextInt(100) < errorRate) {
            return "fault injection: synthetic 5xx response";
        }

        return null;
    }

    public void applyApiLatency() {
        int delay = latencyMs.get();
        if (delay > 0) {
            sleep(delay, "latency fault interrupted");
        }
    }

    public void applyDbPoolContention() {
        if (!dbPoolActive.get()) {
            return;
        }
        try (Connection ignored = dataSource.getConnection()) {
            sleep(DB_POOL_CONTENTION_MILLIS, "db pool contention fault interrupted");
        } catch (SQLException exception) {
            throw new ResponseStatusException(HttpStatus.SERVICE_UNAVAILABLE, "db pool contention fault failed: " + exception.getMessage(), exception);
        }
    }

    FaultStatus configureLatency(Integer requestedLatencyMs) {
        int value = requireRange(requestedLatencyMs, "latencyMs", 0, MAX_LATENCY_MS);
        latencyMs.set(value);
        return status();
    }

    FaultStatus configureErrors(Integer requestedErrorRatePercent) {
        int value = requireRange(requestedErrorRatePercent, "errorRatePercent", 0, 100);
        errorRatePercent.set(value);
        return status();
    }

    synchronized FaultStatus configureCpu(Boolean enabled, Integer requestedWorkers) {
        boolean shouldEnable = requireBoolean(enabled, "enabled");
        stopCpu();

        if (shouldEnable) {
            int workers = requireRange(requestedWorkers, "workers", 1, MAX_CPU_WORKERS);
            cpuActive.set(true);
            cpuWorkers.set(workers);
            for (int index = 0; index < workers; index++) {
                Thread thread = new Thread(this::burnCpu, "setlog-cpu-fault-" + index);
                thread.setDaemon(true);
                cpuThreads.add(thread);
                thread.start();
            }
        }

        return status();
    }

    synchronized FaultStatus configureDisk(Boolean enabled, Integer megabytes) {
        boolean shouldEnable = requireBoolean(enabled, "enabled");
        clearDiskPressure();

        if (shouldEnable) {
            int size = requireRange(megabytes, "megabytes", 1, MAX_DISK_MEGABYTES);
            Path path = Path.of(System.getProperty("java.io.tmpdir"), "setlog-render-debug.log");
            byte[] line = (
                "level=debug service=setlog component=render event=frame-buffer "
                    + "message=\"temporary render artifact retained during incident response\"\n"
            ).getBytes(StandardCharsets.UTF_8);
            long targetBytes = (long) size * 1024 * 1024;
            long writtenBytes = 0;
            try (OutputStream output = Files.newOutputStream(path)) {
                while (writtenBytes < targetBytes) {
                    int length = (int) Math.min(line.length, targetBytes - writtenBytes);
                    output.write(line, 0, length);
                    writtenBytes += length;
                }
            } catch (IOException exception) {
                throw new ResponseStatusException(HttpStatus.SERVICE_UNAVAILABLE, "disk fault failed: " + exception.getMessage(), exception);
            }
            diskPressureFile = path;
            diskBytes = targetBytes;
        }

        return status();
    }

    synchronized FaultStatus configureDbPool(Boolean enabled, Integer requestedHolders, Long requestedHoldMillis) {
        boolean shouldEnable = requireBoolean(enabled, "enabled");
        stopDbPool();

        if (shouldEnable) {
            int holders = requireRange(requestedHolders, "holders", 1, MAX_DB_HOLDERS);
            long holdMillis = requireRange(requestedHoldMillis, "holdMillis", 1000L, MAX_DB_HOLD_MILLIS);
            dbPoolActive.set(true);
            dbPoolHolders.set(0);
            for (int index = 0; index < holders; index++) {
                Thread thread = new Thread(() -> holdDatabaseConnection(holdMillis), "setlog-db-pool-fault-" + index);
                thread.setDaemon(true);
                dbThreads.add(thread);
                thread.start();
            }
        }

        return status();
    }

    synchronized FaultStatus configureRender(Boolean enabled, Integer requestedDelayMs) {
        boolean shouldEnable = requireBoolean(enabled, "enabled");

        if (shouldEnable) {
            int value = requireRange(requestedDelayMs, "delayMs", 1, MAX_RENDER_DELAY_MS);
            renderActive.set(true);
            renderDelayMs.set(value);
        } else {
            renderActive.set(false);
            renderDelayMs.set(0);
        }

        return status();
    }

    public int renderDelayMs() {
        return renderActive.get() ? renderDelayMs.get() : 0;
    }

    public boolean renderDiskPressureActive() {
        return diskBytes() > 0;
    }

    public int renderCpuWorkMillis() {
        return cpuActive.get() ? CPU_RENDER_WORK_MILLIS : 0;
    }

    public long diskBytes() {
        Path path = diskPressureFile;
        if (path == null) {
            return 0;
        }
        try {
            return Files.size(path);
        } catch (IOException exception) {
            return 0;
        }
    }

    synchronized FaultStatus reset() {
        latencyMs.set(0);
        errorRatePercent.set(0);
        stopCpu();
        clearDiskPressure();
        stopDbPool();
        renderActive.set(false);
        renderDelayMs.set(0);
        return status();
    }

    FaultStatus status() {
        return new FaultStatus(
            latencyMs.get(),
            errorRatePercent.get(),
            cpuActive.get(),
            cpuWorkers.get(),
            diskBytes(),
            dbPoolActive.get(),
            dbPoolHolders.get(),
            renderActive.get(),
            renderDelayMs.get()
        );
    }

    private void burnCpu() {
        double local = 0.0;
        while (cpuActive.get()) {
            local += Math.sqrt(System.nanoTime());
            if (local > 1_000_000) {
                cpuSink = local;
                local = 0.0;
            }
        }
        cpuSink = local;
    }

    private void holdDatabaseConnection(long holdMillis) {
        Connection connection = null;
        try {
            connection = dataSource.getConnection();
            synchronized (this) {
                if (!dbPoolActive.get()) {
                    return;
                }
                dbConnections.add(connection);
                dbPoolHolders.incrementAndGet();
            }
            long sleepSeconds = Math.max(1L, (holdMillis + 999L) / 1000L);
            Statement statement = connection.createStatement();
            synchronized (this) {
                if (!dbPoolActive.get()) {
                    closeQuietly(statement);
                    return;
                }
                dbStatements.add(statement);
            }
            try {
                statement.execute("SELECT /* " + DB_POOL_HOLDER_MARKER + " */ SLEEP(" + sleepSeconds + ")");
            } finally {
                synchronized (this) {
                    dbStatements.remove(statement);
                }
                closeQuietly(statement);
            }
        } catch (SQLException exception) {
            if (dbPoolActive.get()) {
                // KILLing the MySQL session is the intended mitigation. The thread exits after that.
            }
        } finally {
            synchronized (this) {
                if (connection != null) {
                    dbConnections.remove(connection);
                }
                int remaining = dbPoolHolders.updateAndGet(value -> Math.max(0, value - 1));
                if (remaining == 0) {
                    dbPoolActive.set(false);
                }
            }
            closeQuietly(connection);
        }
    }

    private void stopCpu() {
        cpuActive.set(false);
        cpuWorkers.set(0);
        interruptAndClear(cpuThreads);
    }

    private void stopDbPool() {
        dbPoolActive.set(false);
        dbPoolHolders.set(0);
        List<Statement> statements = new ArrayList<>(dbStatements);
        List<Connection> connections = new ArrayList<>(dbConnections);
        dbStatements.clear();
        dbConnections.clear();
        interruptAndClear(dbThreads);
        closeDatabaseHoldersAsync(statements, connections);
    }

    private void closeQuietly(Connection connection) {
        if (connection == null) {
            return;
        }
        try {
            connection.close();
        } catch (SQLException exception) {
            // Best-effort cleanup for a fault-injection holder.
        }
    }

    private void closeQuietly(Statement statement) {
        if (statement == null) {
            return;
        }
        try {
            statement.close();
        } catch (SQLException exception) {
            // Best-effort cleanup for a fault-injection holder.
        }
    }

    private void closeDatabaseHoldersAsync(List<Statement> statements, List<Connection> connections) {
        if (statements.isEmpty() && connections.isEmpty()) {
            return;
        }

        Thread cleanupThread = new Thread(() -> {
            for (Statement statement : statements) {
                try {
                    statement.cancel();
                } catch (SQLException exception) {
                    // The intended live mitigation is SQL KILL; reset cleanup is best effort.
                }
                closeQuietly(statement);
            }
            for (Connection connection : connections) {
                closeQuietly(connection);
            }
        }, "setlog-db-pool-cleanup");
        cleanupThread.setDaemon(true);
        cleanupThread.start();
    }

    private void interruptAndClear(List<Thread> threads) {
        for (Thread thread : threads) {
            thread.interrupt();
        }
        threads.clear();
    }

    private void clearDiskPressure() {
        if (diskPressureFile != null) {
            try {
                Files.deleteIfExists(diskPressureFile);
            } catch (IOException exception) {
                throw new ResponseStatusException(HttpStatus.SERVICE_UNAVAILABLE, "disk cleanup failed: " + exception.getMessage(), exception);
            } finally {
                diskPressureFile = null;
                diskBytes = 0;
            }
        }
    }

    private int requireRange(Integer value, String fieldName, int minimum, int maximum) {
        if (value == null || value < minimum || value > maximum) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST, fieldName + " must be between " + minimum + " and " + maximum);
        }
        return value;
    }

    private long requireRange(Long value, String fieldName, long minimum, long maximum) {
        if (value == null || value < minimum || value > maximum) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST, fieldName + " must be between " + minimum + " and " + maximum);
        }
        return value;
    }

    private boolean requireBoolean(Boolean value, String fieldName) {
        if (value == null) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST, fieldName + " is required");
        }
        return value;
    }

    private void sleep(long millis, String interruptedMessage) {
        try {
            Thread.sleep(millis);
        } catch (InterruptedException exception) {
            Thread.currentThread().interrupt();
            throw new ResponseStatusException(HttpStatus.SERVICE_UNAVAILABLE, interruptedMessage, exception);
        }
    }
}
