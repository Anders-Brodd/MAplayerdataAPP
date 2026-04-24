const syncBtn = document.getElementById("syncBtn");
const syncStatus = document.getElementById("syncStatus");
const overviewEl = document.getElementById("overview");
const bucketSelect = document.getElementById("bucketSelect");

const tableHead = document.querySelector("#entriesTable thead");
const tableBody = document.querySelector("#entriesTable tbody");

let activeCharts = [];

async function api(path, init) {
  const res = await fetch(path, init);
  if (!res.ok) throw new Error(await res.text());
  return res.json();
}

function setStatus(text) {
  syncStatus.textContent = text;
}

function renderOverview(data) {
  const latest = data.latestSync;
  overviewEl.innerHTML = `
    <div class="stat-box"><small>Total Entries</small><strong>${data.totalEntries}</strong></div>
    <div class="stat-box"><small>Sync Running</small><strong>${data.syncInProgress ? "Yes" : "No"}</strong></div>
    <div class="stat-box"><small>Last Sync Status</small><strong>${latest ? latest.status : "Never"}</strong></div>
    <div class="stat-box"><small>Last Sync Finished</small><strong>${latest?.finished_at || "-"}</strong></div>
  `;
}

function categorizeField(field) {
  const f = field.toLowerCase();
  if (/money|robux|purchase|spend|earn|coin|gem|revenue|price/i.test(f)) return 'Revenue';
  if (/time|duration|session|playtime|online/i.test(f)) return 'Play Time';
  if (/click|menu|button|screen|ui|open|close|hover/i.test(f)) return 'UI';
  if (/build|place|delete|prop|lift|item|structure/i.test(f)) return 'Building';
  return 'General';
}

function getChartType(field) {
  if (/(label|type|id|name|category|class)$/i.test(field.toLowerCase())) return 'top';
  return 'trend';
}

function getAggregation(field) {
  const f = field.toLowerCase();
  if (/time|duration|ping|rate|level|health/i.test(f) && !/total/i.test(f)) return 'average';
  return 'total';
}

function calculatePrediction(values) {
  if (values.length < 2) return null;
  let sumX = 0, sumY = 0, sumXY = 0, sumXX = 0;
  const n = values.length;
  values.forEach((y, x) => {
    sumX += x;
    sumY += y;
    sumXY += x * y;
    sumXX += x * x;
  });
  const slope = (n * sumXY - sumX * sumY) / (n * sumXX - sumX * sumX);
  const intercept = (sumY - slope * sumX) / n;
  return Math.max(0, slope * n + intercept); // Predict next period (x = n), floor at 0
}

async function loadDashboard() {
  const { fields } = await api("/api/fields");
  const bucket = bucketSelect.value;
  const skip = ["EntryKey", "RawValue", "Timestamp_ISO", "UpdatedAt_ISO"];
  
  const categorized = { 'Revenue': [], 'Play Time': [], 'UI': [], 'Building': [], 'General': [] };
  fields.forEach(f => {
    if (skip.includes(f)) return;
    categorized[categorizeField(f)].push(f);
  });

  activeCharts.forEach(c => c.destroy());
  activeCharts = [];

  const container = document.getElementById("dashboardContainer");
  container.innerHTML = "";

  const predictionsEl = document.getElementById("predictions");
  predictionsEl.innerHTML = "";
  let hasPredictions = false;

  for (const cat of Object.keys(categorized)) {
    if (categorized[cat].length === 0) continue;

    const section = document.createElement("section");
    section.className = "card";
    section.innerHTML = `<h2>${cat} Trends & Stats</h2><div class="chart-grid" id="grid-${cat.replace(/\s+/g, '')}"></div>`;
    container.appendChild(section);

    const grid = section.querySelector(".chart-grid");

    for (const field of categorized[cat]) {
      const wrap = document.createElement("div");
      wrap.className = "chart-wrap";
      const canvasId = `chart-${field.replace(/[^a-zA-Z0-9]/g, '')}`;
      wrap.innerHTML = `<h3>${field}</h3><canvas id="${canvasId}"></canvas>`;
      grid.appendChild(wrap);

      const type = getChartType(field);
      if (type === 'trend') {
        const agg = getAggregation(field);
        api(`/api/trends?metric=${encodeURIComponent(field)}&bucket=${encodeURIComponent(bucket)}`).then(data => {
          const labels = data.series.map(x => x.time);
          let values = data.series.map(x => x[agg]);

          // Convert play time metrics to minutes (assuming base is seconds)
          if (cat === 'Play Time') {
            const isMs = /ms$/i.test(field.toLowerCase());
            values = values.map(v => Number((v / (isMs ? 60000 : 60)).toFixed(2)));
          }

          // Generate predictions for key metrics
          if (['Revenue', 'Play Time'].includes(cat) && values.length > 0) {
            const nextVal = calculatePrediction(values);
            if (nextVal !== null) {
              hasPredictions = true;
              const formattedNext = cat === 'Revenue' ? Math.round(nextVal) : nextVal.toFixed(1) + ' min';
              predictionsEl.innerHTML += `<div class="stat-box"><small>${field} (Next ${bucket})</small><strong>${formattedNext}</strong></div>`;
            }
          }

          activeCharts.push(new Chart(document.getElementById(canvasId), {
            type: "line",
            data: {
              labels,
              datasets: [{
                label: `${field} (${agg}${cat === 'Play Time' ? ' in mins' : ''})`,
                data: values,
                borderColor: "#0f8c6b",
                backgroundColor: "rgba(15,140,107,0.2)",
                fill: true,
                tension: 0.22
              }]
            },
            options: { responsive: true, scales: { y: { beginAtZero: true } } }
          }));
        });
      } else {
        api(`/api/top?field=${encodeURIComponent(field)}`).then(data => {
          const labels = data.values.map(x => x.label);
          const values = data.values.map(x => x.count);
          activeCharts.push(new Chart(document.getElementById(canvasId), {
            type: "bar",
            data: {
              labels,
              datasets: [{
                label: `${field} frequency`,
                data: values,
                backgroundColor: "rgba(209,162,68,0.75)",
                borderColor: "#a77927",
                borderWidth: 1
              }]
            },
            options: { responsive: true, plugins: { legend: { display: false } } }
          }));
        });
      }
    }
  }

  setTimeout(() => {
    if (!hasPredictions && predictionsEl.innerHTML === "") {
      predictionsEl.innerHTML = `<div class="stat-box"><small>Status</small><strong>Not enough data for predictions</strong></div>`;
    }
  }, 1000);
}

async function loadTable() {
  const { rows } = await api("/api/players?limit=20");
  if (!rows.length) {
    tableHead.innerHTML = "";
    tableBody.innerHTML = `<tr><td>No data yet. Run a sync.</td></tr>`;
    return;
  }

  const allHeaders = new Set(["EntryKey", "UpdatedAt"]);
  for (const row of rows) {
    for (const key of Object.keys(row.data)) {
      allHeaders.add(key);
    }
  }

  const headers = [...allHeaders].slice(0, 12);
  tableHead.innerHTML = `<tr>${headers.map((h) => `<th>${h}</th>`).join("")}</tr>`;
  tableBody.innerHTML = rows
    .map((row) => {
      const merged = { EntryKey: row.entryKey, UpdatedAt: row.updatedAt, ...row.data };
      const cells = headers
        .map((header) => {
          const value = merged[header] ?? "";
          const text = typeof value === "string" ? value : JSON.stringify(value);
          return `<td>${text.length > 60 ? `${text.slice(0, 60)}...` : text}</td>`;
        })
        .join("");
      return `<tr>${cells}</tr>`;
    })
    .join("");
}

async function refreshAll() {
  const overview = await api("/api/overview");
  renderOverview(overview);
  await loadDashboard();
  await loadTable();
}

syncBtn.addEventListener("click", async () => {
  try {
    setStatus("Syncing...");
    syncBtn.disabled = true;
    await api("/api/sync", { method: "POST" });
    setStatus("Sync complete");
    await refreshAll();
  } catch (err) {
    setStatus("Sync failed");
    alert(err.message || String(err));
  } finally {
    syncBtn.disabled = false;
  }
});

bucketSelect.addEventListener("change", () => loadDashboard());

refreshAll().catch((err) => {
  setStatus("Load failed");
  console.error(err);
});
