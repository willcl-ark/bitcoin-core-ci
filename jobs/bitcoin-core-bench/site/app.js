const state = { rows: [], metadata: {} };
const minTrendRuns = 7;
let chart;

function formatSeconds(value) {
  if (value === null || value === undefined || Number.isNaN(value)) return "n/a";
  if (value < 0.000001) return `${(value * 1e9).toFixed(2)} ns`;
  if (value < 0.001) return `${(value * 1e6).toFixed(2)} us`;
  if (value < 1) return `${(value * 1e3).toFixed(2)} ms`;
  return `${value.toFixed(3)} s`;
}

function unique(values) { return Array.from(new Set(values)).sort((a, b) => a.localeCompare(b)); }
function pct(value) { return value === null || value === undefined || Number.isNaN(value) ? "n/a" : `${value >= 0 ? "+" : ""}${value.toFixed(2)}%`; }
function pctDelta(latest, base) { return base ? ((latest - base) / base) * 100 : null; }
function cssColor(name) { return getComputedStyle(document.documentElement).getPropertyValue(name).trim(); }

function seriesColor(index) {
  const colors = [
    "#0b7285", "#6741d9", "#c2255c", "#2b8a3e", "#e67700",
    "#1864ab", "#862e9c", "#087f5b", "#5c940d", "#d9480f",
  ];
  return colors[index % colors.length];
}

function heatmapColor(value) {
  if (value === null || value === undefined || Number.isNaN(value)) return "color-mix(in srgb, var(--line) 35%, transparent)";
  const clamped = Math.max(-15, Math.min(15, value));
  const intensity = Math.min(92, 16 + Math.abs(clamped) * 5);
  return clamped < 0
    ? `color-mix(in srgb, var(--good) ${intensity}%, var(--panel))`
    : `color-mix(in srgb, var(--bad) ${intensity}%, var(--panel))`;
}

function heatmapSeverityClass(value) {
  if (value === null || value === undefined || Number.isNaN(value) || value <= 0) return "";
  if (value >= 10) return " heatmap-very-slow";
  if (value >= 5) return " heatmap-slow";
  return "";
}

function byBenchmark(metric) {
  const groups = new Map();
  for (const row of state.rows) {
    if (row[metric] === null || row[metric] === undefined) continue;
    if (!groups.has(row.benchmark)) groups.set(row.benchmark, []);
    groups.get(row.benchmark).push(row);
  }
  for (const rows of groups.values()) rows.sort((a, b) => a.run_time.localeCompare(b.run_time));
  return groups;
}

function sparkline(rows, metric) {
  const values = rows.map((row) => row[metric]).filter((value) => value !== null && value !== undefined);
  if (values.length < 2) return "";
  const min = Math.min(...values);
  const max = Math.max(...values);
  const width = 110;
  const height = 28;
  const points = values.map((value, index) => {
    const x = values.length === 1 ? width / 2 : (index / (values.length - 1)) * width;
    const y = max === min ? height / 2 : height - ((value - min) / (max - min)) * (height - 4) - 2;
    return `${x.toFixed(1)},${y.toFixed(1)}`;
  }).join(" ");
  return `<svg class="spark" viewBox="0 0 ${width} ${height}" aria-hidden="true"><polyline points="${points}" fill="none" stroke="currentColor" stroke-width="2" /></svg>`;
}

function populate() {
  const benchmarks = unique(state.rows.map((row) => row.benchmark));
  const select = document.getElementById("benchmark");
  const allOption = document.createElement("option");
  allOption.value = "__all__";
  allOption.textContent = "All";
  select.replaceChildren(allOption, ...benchmarks.map((name) => {
    const option = document.createElement("option");
    option.value = name;
    option.textContent = name;
    return option;
  }));
  document.getElementById("updated").textContent = `Updated ${state.metadata.generated_at || "unknown"}`;
  document.getElementById("run-count").textContent = `${state.metadata.runs || 0} runs, ${state.metadata.results || 0} results`;
}

function updateTrendCard(id, item, metric) {
  const card = document.getElementById(id);
  card.disabled = !item;
  card.querySelector(".trend-name").textContent = item ? item.benchmark : "n/a";
  card.querySelector(".trend-value").textContent = item ? pct(item.delta) : "n/a";
  card.querySelector(".trend-detail").textContent = item
    ? `${formatSeconds(item.previous[metric])} to ${formatSeconds(item.latest[metric])}`
    : "Need at least two runs for this metric.";
  card.onclick = item
    ? () => {
        document.getElementById("benchmark").value = item.benchmark;
        render();
        document.getElementById("chart").scrollIntoView({ block: "nearest" });
      }
    : null;
}

function renderOverview() {
  const metric = document.getElementById("metric").value;
  const groups = byBenchmark(metric);
  const items = [];
  for (const [benchmark, rows] of groups.entries()) {
    const latest = rows.at(-1);
    const previous = rows.length > 1 ? rows.at(-2) : null;
    const delta = previous ? pctDelta(latest[metric], previous[metric]) : null;
    items.push({ benchmark, rows, latest, previous, delta });
  }
  items.sort((a, b) => Math.abs(b.delta ?? -1) - Math.abs(a.delta ?? -1) || a.benchmark.localeCompare(b.benchmark));

  const enoughRuns = (state.metadata.runs || 0) >= minTrendRuns;
  document.getElementById("overview-note").textContent = enoughRuns
    ? "Sorted by largest latest change versus the previous run."
    : `Need ${minTrendRuns} runs for robust rolling-median signals; showing latest values and previous-run deltas when available.`;

  const downtrend = items.filter((item) => item.delta < 0).sort((a, b) => a.delta - b.delta)[0] || null;
  const uptrend = items.filter((item) => item.delta > 0).sort((a, b) => b.delta - a.delta)[0] || null;
  updateTrendCard("trend-down", downtrend, metric);
  updateTrendCard("trend-up", uptrend, metric);

  const body = document.getElementById("overview-body");
  body.replaceChildren(...items.map((item) => {
    const tr = document.createElement("tr");
    const nameCell = document.createElement("td");
    nameCell.className = "name-cell";
    nameCell.title = item.benchmark;
    nameCell.textContent = item.benchmark;

    const latestCell = document.createElement("td");
    latestCell.textContent = formatSeconds(item.latest[metric]);

    const previousCell = document.createElement("td");
    previousCell.textContent = item.previous ? formatSeconds(item.previous[metric]) : "n/a";

    const deltaCell = document.createElement("td");
    deltaCell.className = item.delta > 0 ? "delta-bad" : item.delta < 0 ? "delta-good" : "";
    deltaCell.textContent = pct(item.delta);

    const trendCell = document.createElement("td");
    trendCell.innerHTML = sparkline(item.rows.slice(-30), metric);

    tr.replaceChildren(nameCell, latestCell, previousCell, deltaCell, trendCell);
    tr.addEventListener("click", () => {
      document.getElementById("benchmark").value = item.benchmark;
      render();
      document.getElementById("chart").scrollIntoView({ block: "nearest" });
    });
    return tr;
  }));
}

function renderHeatmap() {
  const metric = document.getElementById("metric").value;
  const runTimes = unique(state.rows.map((row) => row.run_time));
  const groups = byBenchmark(metric);
  const benchmarks = Array.from(groups.keys()).sort((a, b) => a.localeCompare(b));
  const enoughRuns = runTimes.length >= minTrendRuns;
  document.getElementById("heatmap-note").textContent = enoughRuns
    ? "Color shows percent change from each benchmark's rolling baseline; outlined red cells are large slowdowns."
    : `Heatmap activates after ${minTrendRuns} runs; currently ${runTimes.length}.`;

  if (!enoughRuns || benchmarks.length === 0) {
    const empty = document.createElement("div");
    empty.className = "heatmap-empty";
    empty.textContent = `Need ${minTrendRuns} runs for heatmap`;
    document.getElementById("heatmap").replaceChildren(empty);
    return;
  }

  const z = benchmarks.map((benchmark) => {
    const rows = groups.get(benchmark);
    const byTime = new Map(rows.map((row) => [row.run_time, row[metric]]));
    const values = [];
    return runTimes.map((runTime) => {
      const value = byTime.get(runTime);
      if (value === undefined) return null;
      const history = values.filter((entry) => entry !== null).slice(-6).sort((a, b) => a - b);
      values.push(value);
      if (history.length < 3) return null;
      const median = history[Math.floor(history.length / 2)];
      return pctDelta(value, median);
    });
  });

  const heatmap = document.getElementById("heatmap");
  const grid = document.createElement("div");
  grid.className = "heatmap-grid";
  grid.style.setProperty("--run-count", runTimes.length);
  grid.appendChild(document.createElement("div"));
  for (const runTime of runTimes) {
    const label = document.createElement("div");
    label.className = "heatmap-run";
    label.textContent = runTime;
    label.title = runTime;
    grid.appendChild(label);
  }
  benchmarks.forEach((benchmark, rowIndex) => {
    const label = document.createElement("div");
    label.className = "heatmap-label";
    label.textContent = benchmark;
    label.title = benchmark;
    grid.appendChild(label);
    runTimes.forEach((runTime, columnIndex) => {
      const cell = document.createElement("div");
      const value = z[rowIndex][columnIndex];
      cell.className = `heatmap-cell${heatmapSeverityClass(value)}`;
      cell.style.background = heatmapColor(value);
      cell.title = value === null || value === undefined
        ? `${benchmark}\n${runTime}\nn/a`
        : `${benchmark}\n${runTime}\n${pct(value)}`;
      grid.appendChild(cell);
    });
  });
  heatmap.replaceChildren(grid);
}

function render() {
  const benchmark = document.getElementById("benchmark").value;
  const metric = document.getElementById("metric").value;
  const limit = Number(document.getElementById("limit").value);
  const axisScale = document.getElementById("axis-scale").value;
  const groups = byBenchmark(metric);
  const selectedGroups = benchmark === "__all__"
    ? Array.from(groups.entries())
    : [[benchmark, groups.get(benchmark) || []]];
  const selectedRows = [];
  const datasets = selectedGroups.map(([name, groupRows], index) => {
    let rows = groupRows.slice();
    if (limit > 0) rows = rows.slice(-limit);
    if (axisScale === "logarithmic") rows = rows.filter((row) => row[metric] > 0);
    selectedRows.push(...rows);
    const color = seriesColor(index);
    return {
      label: name,
      data: rows.map((row) => ({
        x: row.run_time,
        y: row[metric],
        commit: row.commit_hash.slice(0, 12),
        jobId: row.job_id,
      })),
      borderColor: color,
      backgroundColor: color,
      borderWidth: 2,
      pointRadius: benchmark === "__all__" ? 2 : 3,
      pointHoverRadius: 6,
      tension: 0.22,
    };
  }).filter((dataset) => dataset.data.length > 0);
  const labels = unique(selectedRows.map((row) => row.run_time));

  if (chart) chart.destroy();
  chart = new Chart(document.getElementById("chart-canvas"), {
    type: "line",
    data: { labels, datasets },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      interaction: { mode: "nearest", intersect: false },
      plugins: {
        legend: {
          display: benchmark === "__all__",
          position: "right",
          labels: { color: cssColor("--text"), boxWidth: 12, boxHeight: 12 },
        },
        tooltip: {
          callbacks: {
            title: (items) => items[0]?.raw?.x || "",
            label: (item) => `${item.dataset.label}: ${formatSeconds(item.raw.y)}`,
            afterLabel: (item) => `${item.raw.commit}\n${item.raw.jobId}`,
          },
        },
      },
      scales: {
        x: {
          type: "category",
          title: { display: true, text: "Run time", color: cssColor("--muted") },
          grid: { color: cssColor("--line") },
          ticks: { color: cssColor("--muted"), maxRotation: 40, autoSkip: true },
        },
        y: {
          type: axisScale,
          title: { display: true, text: metric.replaceAll("_", " "), color: cssColor("--muted") },
          grid: { color: cssColor("--line") },
          ticks: { color: cssColor("--muted"), callback: (value) => formatSeconds(Number(value)) },
        },
      },
    },
  });

  const latestRows = selectedGroups
    .map(([name, groupRows]) => ({ name, latest: groupRows.at(-1) }))
    .filter((item) => item.latest);
  const latest = latestRows.length === 1 ? latestRows[0].latest : null;
  document.getElementById("summary").textContent = benchmark === "__all__"
    ? `Showing ${datasets.length} benchmark series${axisScale === "logarithmic" ? " on a log axis" : ""}.`
    : latest
    ? `${benchmark}: latest ${formatSeconds(latest[metric])} at ${latest.run_time} (${latest.commit_hash.slice(0, 12)})`
    : "No results for this selection.";
  renderOverview();
  renderHeatmap();
}

async function main() {
  const [metadata, rows] = await Promise.all([
    fetch("metadata.json").then((response) => response.json()),
    fetch("results.json").then((response) => response.json()),
  ]);
  state.metadata = metadata;
  state.rows = rows;
  populate();
  render();
  for (const id of ["benchmark", "metric", "limit", "axis-scale"]) {
    document.getElementById(id).addEventListener("change", render);
  }
}

main().catch((error) => { document.getElementById("summary").textContent = error.message; });
