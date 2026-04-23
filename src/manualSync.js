import { validateConfig } from "./config.js";
import { syncNow } from "./syncService.js";
import { log, error } from "./logger.js";

const missing = validateConfig();
if (missing.length) {
  error(`Missing required env values: ${missing.join(", ")}`);
  process.exit(1);
}

try {
  const result = await syncNow();
  log("Manual sync finished", result);
  process.exit(0);
} catch (err) {
  error("Manual sync failed", err.message || String(err));
  process.exit(1);
}
