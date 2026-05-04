import express from "express";
import client from "prom-client";

const app = express();
const port = Number(process.env.PORT || 8080);

const register = new client.Registry();
client.collectDefaultMetrics({ register });

const httpRequestsTotal = new client.Counter({
  name: "http_requests_total",
  help: "Total number of HTTP requests handled by the app.",
  labelNames: ["method", "route", "status_code"],
  registers: [register]
});

const httpRequestDurationSeconds = new client.Histogram({
  name: "http_request_duration_seconds",
  help: "HTTP request duration in seconds.",
  labelNames: ["method", "route", "status_code"],
  buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5],
  registers: [register]
});

app.use((req, res, next) => {
  if (req.path === "/metrics") {
    next();
    return;
  }

  const start = process.hrtime.bigint();

  res.on("finish", () => {
    const durationSeconds = Number(process.hrtime.bigint() - start) / 1e9;
    const route = req.route?.path || req.path || "unknown";
    const labels = {
      method: req.method,
      route,
      status_code: String(res.statusCode)
    };

    httpRequestsTotal.inc(labels);
    httpRequestDurationSeconds.observe(labels, durationSeconds);
  });

  next();
});

app.get("/", (_req, res) => {
  res.json({
    service: "monitoring-lab-app",
    message: "ok"
  });
});

app.get("/health", (_req, res) => {
  res.json({ status: "ok" });
});

app.get("/work", async (req, res) => {
  const delayMs = Math.min(Number(req.query.delayMs || 100), 2000);
  await new Promise((resolve) => setTimeout(resolve, delayMs));

  res.json({
    status: "done",
    delayMs
  });
});

app.get("/metrics", async (_req, res) => {
  res.set("Content-Type", register.contentType);
  res.end(await register.metrics());
});

app.listen(port, () => {
  console.log(`monitoring-lab-app listening on ${port}`);
});
