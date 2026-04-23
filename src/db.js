import fs from "fs";
import path from "path";
import Database from "better-sqlite3";

import { config } from "./config.js";

fs.mkdirSync(path.dirname(config.dbPath), { recursive: true });

const db = new Database(config.dbPath);

db.pragma("journal_mode = WAL");

db.exec(`
  CREATE TABLE IF NOT EXISTS entries (
    entry_key TEXT PRIMARY KEY,
    payload_json TEXT NOT NULL,
    normalized_json TEXT NOT NULL,
    updated_at TEXT NOT NULL
  );

  CREATE TABLE IF NOT EXISTS sync_runs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    started_at TEXT NOT NULL,
    finished_at TEXT,
    status TEXT NOT NULL,
    key_count INTEGER DEFAULT 0,
    error_message TEXT
  );
`);

const upsertEntryStmt = db.prepare(`
  INSERT INTO entries (entry_key, payload_json, normalized_json, updated_at)
  VALUES (@entry_key, @payload_json, @normalized_json, @updated_at)
  ON CONFLICT(entry_key) DO UPDATE SET
    payload_json = excluded.payload_json,
    normalized_json = excluded.normalized_json,
    updated_at = excluded.updated_at
`);

export function insertOrUpdateEntry(entryKey, payloadObj, normalizedObj) {
  upsertEntryStmt.run({
    entry_key: entryKey,
    payload_json: JSON.stringify(payloadObj),
    normalized_json: JSON.stringify(normalizedObj),
    updated_at: new Date().toISOString()
  });
}

export function startSyncRun() {
  const startedAt = new Date().toISOString();
  const result = db
    .prepare("INSERT INTO sync_runs (started_at, status) VALUES (?, 'running')")
    .run(startedAt);

  return { id: result.lastInsertRowid, startedAt };
}

export function finishSyncRun(id, status, keyCount, errorMessage = null) {
  db.prepare(
    "UPDATE sync_runs SET finished_at = ?, status = ?, key_count = ?, error_message = ? WHERE id = ?"
  ).run(new Date().toISOString(), status, keyCount, errorMessage, id);
}

export function getLatestSyncRun() {
  return db
    .prepare("SELECT * FROM sync_runs ORDER BY id DESC LIMIT 1")
    .get();
}

export function getAllEntries(limit = 1000) {
  return db
    .prepare("SELECT entry_key, normalized_json, updated_at FROM entries ORDER BY updated_at DESC LIMIT ?")
    .all(limit);
}

export function getEntryCount() {
  const row = db.prepare("SELECT COUNT(*) AS count FROM entries").get();
  return row.count;
}

export function getNormalizedFieldUniverse() {
  const rows = db.prepare("SELECT normalized_json FROM entries").all();
  const fieldSet = new Set(["EntryKey"]);

  for (const row of rows) {
    const parsed = JSON.parse(row.normalized_json);
    for (const key of Object.keys(parsed)) {
      fieldSet.add(key);
    }
  }

  return [...fieldSet].sort();
}
