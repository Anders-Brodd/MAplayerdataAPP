export function log(message, extra) {
  const stamp = new Date().toISOString();
  if (extra === undefined) {
    console.log(`[${stamp}] ${message}`);
    return;
  }
  console.log(`[${stamp}] ${message}`, extra);
}

export function warn(message, extra) {
  const stamp = new Date().toISOString();
  if (extra === undefined) {
    console.warn(`[${stamp}] ${message}`);
    return;
  }
  console.warn(`[${stamp}] ${message}`, extra);
}

export function error(message, extra) {
  const stamp = new Date().toISOString();
  if (extra === undefined) {
    console.error(`[${stamp}] ${message}`);
    return;
  }
  console.error(`[${stamp}] ${message}`, extra);
}
