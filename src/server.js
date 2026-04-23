import express from "express";
import cors from "cors";
import path from "path";
import { fileURLToPath } from "url";

import { config, validateConfig } from "./config.js";
import { log } from "./logger.js";
import {
  getLatestSyncRun,
  getEntryCount,
  getAllEntries,
  getNormalizedFieldUniverse
} from "./db.js";
import { buildTrendSeries, buildTopDimensions } from "./trends.js";
import { syncNow, isSyncInProgress } from "./syncService.js";

const app = express();
app.use(cors());
app.use(express.json({ limit: "2mb" }));

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
app.use(express.static(path.join(__dirname, "..", "public")));

app.get("/api/health", (_req, res) => {
  res.json({ ok: true, syncInProgress: isSyncInProgress() });
});

app.get("/api/overview", (_req, res) => {
  const latest = getLatestSyncRun();
  const count = getEntryCount();
  res.json({
    totalEntries: count,
    latestSync: latest || null,
    syncInProgress: isSyncInProgress()
  });
});

app.get("/api/fields", (_req, res) => {
  res.json({ fields: getNormalizedFieldUniverse() });
});

app.get("/api/players", (req, res) => {
  const limit = Math.min(Number(req.query.limit) || 100, 1000);
  const rows = getAllEntries(limit).map((row) => ({
    entryKey: row.entry_key,
    updatedAt: row.updated_at,
    data: JSON.parse(row.normalized_json)
  }));
  res.json({ rows });
});

app.get("/api/trends", (req, res) => {
  const metric = String(req.query.metric || "");
  const bucket = String(req.query.bucket || "day");

  if (!metric) {
    return res.status(400).json({ error: "Query parameter 'metric' is required" });
  }

  const rows = getAllEntries(5000).map((r) => JSON.parse(r.normalized_json));
  const series = buildTrendSeries(rows, metric, bucket);
  return res.json({ metric, bucket, series });
});

app.get("/api/top", (req, res) => {
  const field = String(req.query.field || "");
  const limit = Math.min(Number(req.query.limit) || 15, 100);

  if (!field) {
    return res.status(400).json({ error: "Query parameter 'field' is required" });
  }

  const rows = getAllEntries(5000).map((r) => JSON.parse(r.normalized_json));
  const values = buildTopDimensions(rows, field, limit);
  return res.json({ field, values });
});

app.post("/api/sync", async (_req, res) => {
  if (isSyncInProgress()) {
    return res.status(409).json({ error: "Sync already running" });
  }

  try {
    const result = await syncNow();
    return res.json({ ok: true, result });
  } catch (err) {
    return res.status(500).json({
      ok: false,
      error: err.message || String(err)
    });
  }
});

app.get("*", (_req, res) => {
  res.sendFile(path.join(__dirname, "..", "public", "index.html"));
});

const missing = validateConfig();
if (missing.length) {
  log(`Missing environment values: ${missing.join(", ")}. Fill .env before running sync.`);
}

app.listen(config.port, () => {
  log(`Telemetry analytics server listening on http://localhost:${config.port}`);
});
