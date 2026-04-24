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

  for (const cat of Object.keys(categorized)) {
    if (categorized[cat].length === 0) continue;

    const section = document.createElement("section");
    section.className = "card";
    section.innerHTML = `<h2>${cat}</h2><div class="chart-grid" id="grid-${cat.replace(/\s+/g, '')}"></div>`;
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
          const values = data.series.map(x => x[agg]);
          activeCharts.push(new Chart(document.getElementById(canvasId), {
            type: "line",
            data: {
              labels,
              datasets: [{
                label: `${field} (${agg})`,
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
