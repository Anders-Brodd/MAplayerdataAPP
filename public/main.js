const syncBtn = document.getElementById("syncBtn");
const syncStatus = document.getElementById("syncStatus");
const overviewEl = document.getElementById("overview");
const metricSelect = document.getElementById("metricSelect");
const bucketSelect = document.getElementById("bucketSelect");
const topFieldSelect = document.getElementById("topFieldSelect");

const tableHead = document.querySelector("#entriesTable thead");
const tableBody = document.querySelector("#entriesTable tbody");

let trendChart;
let topChart;

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

function refillSelect(select, values, preferred = null) {
  const previous = preferred ?? select.value;
  select.innerHTML = "";
  for (const value of values) {
    const option = document.createElement("option");
    option.value = value;
    option.textContent = value;
    select.appendChild(option);
  }
  if (values.includes(previous)) {
    select.value = previous;
  }
}

async function loadFields() {
  const { fields } = await api("/api/fields");
  const numericLikely = fields.filter((f) => /count|money|spent|earned|duration|level|xp|sessions|total/i.test(f));
  const idLikely = fields.filter((f) => /(label|type|id)/i.test(f));

  refillSelect(metricSelect, numericLikely.length ? numericLikely : fields);
  refillSelect(topFieldSelect, idLikely.length ? idLikely : fields);
}

async function loadTrend() {
  const metric = metricSelect.value;
  if (!metric) return;
  const bucket = bucketSelect.value;

  const data = await api(`/api/trends?metric=${encodeURIComponent(metric)}&bucket=${encodeURIComponent(bucket)}`);

  const labels = data.series.map((x) => x.time);
  const values = data.series.map((x) => x.total);

  if (trendChart) trendChart.destroy();
  trendChart = new Chart(document.getElementById("trendChart"), {
    type: "line",
    data: {
      labels,
      datasets: [
        {
          label: `${metric} (total)` ,
          data: values,
          borderColor: "#0f8c6b",
          backgroundColor: "rgba(15,140,107,0.2)",
          fill: true,
          tension: 0.22
        }
      ]
    },
    options: {
      responsive: true,
      scales: {
        y: {
          beginAtZero: true
        }
      }
    }
  });
}

async function loadTop() {
  const field = topFieldSelect.value;
  if (!field) return;

  const data = await api(`/api/top?field=${encodeURIComponent(field)}`);
  const labels = data.values.map((x) => x.label);
  const values = data.values.map((x) => x.count);

  if (topChart) topChart.destroy();
  topChart = new Chart(document.getElementById("topChart"), {
    type: "bar",
    data: {
      labels,
      datasets: [
        {
          label: `${field} frequency`,
          data: values,
          backgroundColor: "rgba(209,162,68,0.75)",
          borderColor: "#a77927",
          borderWidth: 1
        }
      ]
    },
    options: {
      responsive: true,
      plugins: { legend: { display: false } }
    }
  });
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
  await loadFields();
  await loadTrend();
  await loadTop();
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

metricSelect.addEventListener("change", () => loadTrend());
bucketSelect.addEventListener("change", () => loadTrend());
topFieldSelect.addEventListener("change", () => loadTop());

refreshAll().catch((err) => {
  setStatus("Load failed");
  console.error(err);
});
