import { listAllKeys, getEntry } from "./robloxApi.js";
import { normalizeEntry } from "./normalize.js";
import { insertOrUpdateEntry, startSyncRun, finishSyncRun } from "./db.js";
import { log, error } from "./logger.js";

let syncInProgress = false;

export async function syncNow() {
  if (syncInProgress) {
    throw new Error("Sync already running");
  }

  syncInProgress = true;
  const run = startSyncRun();
  let processed = 0;

  try {
    log("Starting telemetry sync", { runId: run.id });
    const keys = await listAllKeys();

    for (let i = 0; i < keys.length; i += 1) {
      const key = keys[i];
      try {
        const payload = await getEntry(key);
        const normalized = normalizeEntry(key, payload);
        insertOrUpdateEntry(key, payload, normalized);
        processed += 1;

        if ((i + 1) % 50 === 0 || i === keys.length - 1) {
          log(`Processed ${i + 1}/${keys.length} entries`);
        }
      } catch (entryErr) {
        error(`Failed to process key ${key}`, entryErr.message || String(entryErr));
      }
    }

    finishSyncRun(run.id, "success", processed);
    log("Telemetry sync complete", { runId: run.id, processed });
    return { runId: run.id, processed, totalKeys: keys.length };
  } catch (err) {
    finishSyncRun(run.id, "error", processed, err.message || String(err));
    error("Telemetry sync failed", err.message || String(err));
    throw err;
  } finally {
    syncInProgress = false;
  }
}

export function isSyncInProgress() {
  return syncInProgress;
}
