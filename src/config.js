import dotenv from "dotenv";

dotenv.config();

function numberEnv(name, fallback) {
  const value = process.env[name];
  if (!value) return fallback;
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

export const config = {
  port: numberEnv("PORT", 3000),
  robloxApiKey: process.env.ROBLOX_API_KEY || "",
  universeId: process.env.ROBLOX_UNIVERSE_ID || "",
  dataStoreName: process.env.ROBLOX_DATASTORE_NAME || "",
  dataStoreScope: process.env.ROBLOX_DATASTORE_SCOPE || "",
  syncPageLimit: numberEnv("SYNC_PAGE_LIMIT", 250),
  maxRetries: numberEnv("SYNC_MAX_RETRIES", 5),
  throttleMs: numberEnv("SYNC_THROTTLE_MS", 80)
};

export function validateConfig() {
  const missing = [];
  if (!config.robloxApiKey) missing.push("ROBLOX_API_KEY");
  if (!config.universeId) missing.push("ROBLOX_UNIVERSE_ID");
  if (!config.dataStoreName) missing.push("ROBLOX_DATASTORE_NAME");
  return missing;
}
