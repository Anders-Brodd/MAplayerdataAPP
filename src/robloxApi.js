import { config } from "./config.js";
import { log, warn } from "./logger.js";

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function fetchWithRetry(url, options = {}, maxRetries = config.maxRetries) {
  let attempt = 0;

  while (attempt <= maxRetries) {
    const res = await fetch(url, options);
    if (res.ok) return res;

    if (res.status === 429 && attempt < maxRetries) {
      attempt += 1;
      const delay = Math.pow(2, attempt) * 500;
      warn(`Rate limited on ${url}. Retry ${attempt}/${maxRetries} in ${delay}ms`);
      await sleep(delay);
      continue;
    }

    return res;
  }

  return null;
}

export async function listAllKeys() {
  let cursor = "";
  let hasMore = true;
  const keys = [];

  while (hasMore) {
    const base = `https://apis.roblox.com/datastores/v1/universes/${config.universeId}/standard-datastores/datastore/entries`;
    const url = new URL(base);
    url.searchParams.set("datastoreName", config.dataStoreName);
    url.searchParams.set("maxPageSize", String(config.syncPageLimit));
    if (cursor) url.searchParams.set("cursor", cursor);

    const res = await fetchWithRetry(url.toString(), {
      method: "GET",
      headers: {
        "x-api-key": config.robloxApiKey
      }
    });

    if (!res) throw new Error(`Failed to list keys from Roblox API.`);
    if (!res.ok) {
      const body = await res.text();
      throw new Error(`listAllKeys failed ${res.status}: ${body}`);
    }

    const payload = await res.json();
    if (Array.isArray(payload.keys)) {
      keys.push(...payload.keys.map((k) => k.key));
      log(`Loaded ${payload.keys.length} keys (running total ${keys.length})`);
    }

    if (payload.nextPageCursor) {
      cursor = payload.nextPageCursor;
      await sleep(config.throttleMs);
    } else {
      hasMore = false;
    }
  }

  return keys;
}

export async function getEntry(entryKey) {
  const base = `https://apis.roblox.com/datastores/v1/universes/${config.universeId}/standard-datastores/datastore/entries/entry`;
  const url = new URL(base);
  url.searchParams.set("datastoreName", config.dataStoreName);
  url.searchParams.set("entryKey", entryKey);

  const res = await fetchWithRetry(url.toString(), {
    method: "GET",
    headers: {
      "x-api-key": config.robloxApiKey
    }
  });

  if (!res) throw new Error(`Failed to fetch entry ${entryKey}`);
  if (!res.ok) {
    const body = await res.text();
    throw new Error(`getEntry ${entryKey} failed ${res.status}: ${body}`);
  }

  const text = await res.text();
  try {
    return JSON.parse(text);
  } catch {
    return text;
  }
}
