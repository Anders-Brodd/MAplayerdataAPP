import { idDictionaries, valueMappers } from "./mappings.js";

export function flattenData(obj, parentKey = "", target = {}) {
  if (obj === null || obj === undefined) return target;

  for (const [key, value] of Object.entries(obj)) {
    const path = parentKey ? `${parentKey}_${key}` : key;

    if (Array.isArray(value)) {
      target[path] = JSON.stringify(value);
      continue;
    }

    if (value && typeof value === "object") {
      flattenData(value, path, target);
      continue;
    }

    target[path] = value;
  }

  return target;
}

function isLikelyTimestamp(path, value) {
  if (typeof value !== "number") return false;
  if (!/(time|timestamp|date|at)$/i.test(path)) return false;

  // Accept Unix seconds or milliseconds within a broad, practical range.
  if (value > 1_000_000_000 && value < 20_000_000_000) return true;
  if (value > 1_000_000_000_000 && value < 20_000_000_000_000) return true;

  return false;
}

function toIso(value) {
  const ms = value > 20_000_000_000 ? value : value * 1000;
  return new Date(ms).toISOString();
}

function toDictionaryLabel(field, value) {
  const exact = idDictionaries[field];
  if (exact && Object.prototype.hasOwnProperty.call(exact, String(value))) {
    return exact[String(value)];
  }

  const suffix = field.split("_").at(-1);
  const fallback = idDictionaries[suffix];
  if (fallback && Object.prototype.hasOwnProperty.call(fallback, String(value))) {
    return fallback[String(value)];
  }

  return null;
}

function maybeDuration(path, value) {
  if (typeof value !== "number") return null;
  if (!/(duration|elapsed|seconds|ms)$/i.test(path)) return null;

  if (/ms$/i.test(path)) {
    return `${Math.round(value / 1000)} sec`;
  }

  if (/seconds$/i.test(path)) {
    return `${value} sec`;
  }

  return `${value}`;
}

export function humanizeFields(flattened) {
  const enriched = { ...flattened };

  for (const [field, value] of Object.entries(flattened)) {
    if (isLikelyTimestamp(field, value)) {
      enriched[`${field}_ISO`] = toIso(value);
    }

    const mapped = valueMappers[field] ? valueMappers[field](value) : null;
    if (mapped !== null && mapped !== undefined && mapped !== value) {
      enriched[`${field}_Label`] = mapped;
    }

    if (/(id)$/i.test(field) || /(type)$/i.test(field)) {
      const label = toDictionaryLabel(field, value);
      if (label) {
        enriched[`${field}_Label`] = label;
      }
    }

    const duration = maybeDuration(field, value);
    if (duration) {
      enriched[`${field}_Human`] = duration;
    }
  }

  return enriched;
}

export function normalizeEntry(entryKey, payload) {
  if (payload && typeof payload === "object") {
    const flat = flattenData(payload);
    const human = humanizeFields(flat);
    return {
      EntryKey: entryKey,
      ...human
    };
  }

  return {
    EntryKey: entryKey,
    RawValue: String(payload)
  };
}
