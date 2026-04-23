function parseIsoFromRecord(record) {
  const candidates = [
    "Timestamp_ISO",
    "UpdatedAt_ISO",
    "LastSeenAt_ISO",
    "LastSessionAt_ISO",
    "SessionStartAt_ISO",
    "CreatedAt_ISO"
  ];

  for (const key of candidates) {
    if (record[key]) {
      const d = new Date(record[key]);
      if (!Number.isNaN(d.getTime())) return d;
    }
  }

  for (const [key, value] of Object.entries(record)) {
    if (/_ISO$/.test(key) && typeof value === "string") {
      const d = new Date(value);
      if (!Number.isNaN(d.getTime())) return d;
    }
  }

  return null;
}

function bucketKey(date, bucket) {
  const year = date.getUTCFullYear();
  const month = `${date.getUTCMonth() + 1}`.padStart(2, "0");
  const day = `${date.getUTCDate()}`.padStart(2, "0");

  if (bucket === "week") {
    const copy = new Date(Date.UTC(year, date.getUTCMonth(), date.getUTCDate()));
    const weekday = copy.getUTCDay();
    const diff = weekday === 0 ? -6 : 1 - weekday;
    copy.setUTCDate(copy.getUTCDate() + diff);
    const wy = copy.getUTCFullYear();
    const wm = `${copy.getUTCMonth() + 1}`.padStart(2, "0");
    const wd = `${copy.getUTCDate()}`.padStart(2, "0");
    return `${wy}-${wm}-${wd}`;
  }

  if (bucket === "month") {
    return `${year}-${month}`;
  }

  return `${year}-${month}-${day}`;
}

export function buildTrendSeries(records, metric, bucket = "day") {
  const groups = new Map();

  for (const record of records) {
    const date = parseIsoFromRecord(record);
    if (!date) continue;

    const value = Number(record[metric]);
    if (!Number.isFinite(value)) continue;

    const key = bucketKey(date, bucket);
    const prev = groups.get(key) || { sum: 0, count: 0, min: Infinity, max: -Infinity };
    prev.sum += value;
    prev.count += 1;
    prev.min = Math.min(prev.min, value);
    prev.max = Math.max(prev.max, value);
    groups.set(key, prev);
  }

  return [...groups.entries()]
    .sort((a, b) => a[0].localeCompare(b[0]))
    .map(([time, agg]) => ({
      time,
      total: agg.sum,
      average: agg.count ? agg.sum / agg.count : 0,
      min: agg.min === Infinity ? 0 : agg.min,
      max: agg.max === -Infinity ? 0 : agg.max,
      count: agg.count
    }));
}

export function buildTopDimensions(records, field, limit = 15) {
  const counts = new Map();

  for (const record of records) {
    const value = record[field];
    if (value === undefined || value === null || value === "") continue;
    const key = String(value);
    counts.set(key, (counts.get(key) || 0) + 1);
  }

  return [...counts.entries()]
    .map(([label, count]) => ({ label, count }))
    .sort((a, b) => b.count - a.count)
    .slice(0, limit);
}
