import { listAllKeys, getEntry } from "./robloxApi.js";
import { normalizeEntry } from "./normalize.js";
import { log, error } from "./logger.js";

let syncInProgress = false;
let latestSyncRun = null;
let nextRunId = 1;
let cachedEntries = [];

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function pickUpdatedAt(record) {
  const candidates = [
    "UpdatedAt_ISO",
    "Timestamp_ISO",
    "LastSeenAt_ISO",
    "LastSessionAt_ISO",
    "SessionStartAt_ISO",
    "CreatedAt_ISO"
  ];

  for (const key of candidates) {
    const value = record?.[key];
    if (typeof value === "string" && !Number.isNaN(new Date(value).getTime())) {
      return value;
    }
  }

  return new Date().toISOString();
}

export async function syncNow() {
  if (syncInProgress) {
    throw new Error("Sync already running");
  }

  syncInProgress = true;
  const run = { id: nextRunId++, startedAt: new Date().toISOString() };
  latestSyncRun = {
    id: run.id,
    started_at: run.startedAt,
    finished_at: null,
    status: "running",
    key_count: 0,
    error_message: null
  };
  let processed = 0;
  const nextEntries = [];

  try {
    log("Starting telemetry sync", { runId: run.id });
    const keys = await listAllKeys();

    for (let i = 0; i < keys.length; i += 1) {
      const key = keys[i];
      try {
        const payload = await getEntry(key);
        const normalized = normalizeEntry(key, payload);
        nextEntries.push({
          entry_key: key,
          normalized_json: JSON.stringify(normalized),
          updated_at: pickUpdatedAt(normalized)
        });
        processed += 1;

        if ((i + 1) % 50 === 0 || i === keys.length - 1) {
          log(`Processed ${i + 1}/${keys.length} entries`);
        }
      } catch (entryErr) {
        error(`Failed to process key ${key}`, entryErr.message || String(entryErr));
      }
    }

    cachedEntries = nextEntries.sort((a, b) => b.updated_at.localeCompare(a.updated_at));
    latestSyncRun = {
      ...latestSyncRun,
      finished_at: new Date().toISOString(),
      status: "success",
      key_count: processed,
      error_message: null
    };
    log("Telemetry sync complete", { runId: run.id, processed });
    return { runId: run.id, processed, totalKeys: keys.length };
  } catch (err) {
    latestSyncRun = {
      ...latestSyncRun,
      finished_at: new Date().toISOString(),
      status: "error",
      key_count: processed,
      error_message: err.message || String(err)
    };
    error("Telemetry sync failed", err.message || String(err));
    throw err;
  } finally {
    syncInProgress = false;
  }
}

export function isSyncInProgress() {
  return syncInProgress;
}

export async function ensureEntriesLoaded() {
  if (cachedEntries.length > 0) {
    return;
  }

  if (syncInProgress) {
    while (syncInProgress) {
      await sleep(200);
    }
    return;
  }

  await syncNow();
}

export function getLatestSyncRun() {
  return latestSyncRun;
}

export function getEntryCount() {
  return cachedEntries.length;
}

export function getAllEntries(limit = 1000) {
  return cachedEntries.slice(0, limit);
}

export function getNormalizedFieldUniverse() {
  const fieldSet = new Set(["EntryKey"]);

  for (const row of cachedEntries) {
    const parsed = JSON.parse(row.normalized_json);
    for (const key of Object.keys(parsed)) {
      fieldSet.add(key);
    }
  }

  return [...fieldSet].sort();
}
