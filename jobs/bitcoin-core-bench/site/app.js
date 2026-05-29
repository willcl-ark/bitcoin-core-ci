const state = {
  rows: [],
  metadata: {},
  summary: { benchmarks: [], heatmap: {}, overview: [], series: [] },
  seriesRows: new Map(),
};
const minTrendRuns = 7;
const metric = "median_elapsed";
const seriesFocus = { hovered: null, pinned: null };
let chart;
let fullRowsPromise;
let renderToken = 0;
let toastTimer;

Chart.Tooltip.positioners.offset = (_elements, eventPosition) => ({
  x: eventPosition.x + 18,
  y: Math.max(12, eventPosition.y - 18),
  xAlign: "left",
  yAlign: "bottom",
});

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
function chartTime(row) { return row.commit_time || row.run_time; }
function focusedSeries() { return seriesFocus.pinned || seriesFocus.hovered; }
function pinnedSeries() { return seriesFocus.pinned; }
function needsFullHistory(limit, moverRange) { return limit === 0 || limit > (state.summary.recent_run_count || 90) || moverRange === "all-time"; }

function showChartStatus(message) {
  const selection = document.getElementById("chart-selection");
  const clear = pinnedSeries() ? document.createElement("button") : null;
  if (clear) {
    clear.type = "button";
    clear.textContent = "Clear";
    clear.addEventListener("click", clearPinnedSeries);
  }
  selection.replaceChildren(document.createTextNode(message), ...(clear ? [clear] : []));
}

function showToast(message) {
  const toast = document.getElementById("toast");
  toast.textContent = message;
  toast.classList.add("toast-visible");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => {
    toast.classList.remove("toast-visible");
  }, 1600);
}

async function writeClipboard(text) {
  if (navigator.clipboard?.writeText) {
    await navigator.clipboard.writeText(text);
    return;
  }

  const textarea = document.createElement("textarea");
  textarea.value = text;
  textarea.style.position = "fixed";
  textarea.style.left = "-9999px";
  textarea.setAttribute("readonly", "");
  document.body.appendChild(textarea);
  textarea.select();
  try {
    if (!document.execCommand("copy")) throw new Error("copy command failed");
  } finally {
    textarea.remove();
  }
}

async function copyCommitHash(point) {
  const commitHash = chart?.data?.datasets?.[point?.datasetIndex]?.data?.[point?.index]?.commitHash;
  if (!commitHash) return false;
  try {
    await writeClipboard(commitHash);
    showChartStatus(`Copied ${commitHash.slice(0, 12)}`);
    showToast("Copied");
  } catch (error) {
    showChartStatus(`Copy failed: ${commitHash}`);
    showToast("Copy failed");
  }
  return true;
}

async function copyCommitRange(segment) {
  if (!segment) return false;
  const dataset = chart?.data?.datasets?.[segment.datasetIndex];
  const from = dataset?.data?.[segment.fromIndex];
  const to = dataset?.data?.[segment.toIndex];
  if (!from?.commitHash || !to?.commitHash) return false;

  const range = `${from.commitHash}...${to.commitHash}`;
  try {
    await writeClipboard(range);
    showChartStatus(`Copied ${from.commit}...${to.commit}`);
    showToast(to.y > from.y ? "Copied slowdown range" : "Copied range");
  } catch (error) {
    showChartStatus(`Copy failed: ${range}`);
    showToast("Copy failed");
  }
  return true;
}

function colorWithAlpha(color, alpha) {
  const hex = color.replace("#", "");
  const red = parseInt(hex.slice(0, 2), 16);
  const green = parseInt(hex.slice(2, 4), 16);
  const blue = parseInt(hex.slice(4, 6), 16);
  return `rgba(${red}, ${green}, ${blue}, ${alpha})`;
}

function pointSegmentDistance(px, py, ax, ay, bx, by) {
  const dx = bx - ax;
  const dy = by - ay;
  if (dx === 0 && dy === 0) return Math.hypot(px - ax, py - ay);
  const t = Math.max(0, Math.min(1, ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)));
  return Math.hypot(px - (ax + t * dx), py - (ay + t * dy));
}

function nearestChartSeries(event, elements) {
  const datasetIndex = elements[0]?.datasetIndex;
  if (datasetIndex !== undefined) return chart.data.datasets[datasetIndex]?.label || null;

  let best = { label: null, distance: 12 };
  chart.data.datasets.forEach((dataset, datasetIndex) => {
    if (!chart.isDatasetVisible(datasetIndex)) return;
    const points = chart.getDatasetMeta(datasetIndex).data;
    for (let index = 1; index < points.length; index += 1) {
      const previous = points[index - 1];
      const current = points[index];
      const distance = pointSegmentDistance(
        event.x,
        event.y,
        previous.x,
        previous.y,
        current.x,
        current.y,
      );
      if (distance < best.distance) best = { label: dataset.label, distance };
    }
  });
  return best.label;
}

function nearestChartSegment(event) {
  let best = null;
  chart.data.datasets.forEach((dataset, datasetIndex) => {
    if (!chart.isDatasetVisible(datasetIndex)) return;
    const points = chart.getDatasetMeta(datasetIndex).data;
    for (let index = 1; index < points.length; index += 1) {
      const previous = points[index - 1];
      const current = points[index];
      const distance = pointSegmentDistance(
        event.x,
        event.y,
        previous.x,
        previous.y,
        current.x,
        current.y,
      );
      if (distance < (best?.distance ?? 10)) {
        best = {
          datasetIndex,
          fromIndex: index - 1,
          toIndex: index,
          distance,
        };
      }
    }
  });
  return best;
}

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
  return byBenchmarkRows(state.rows, metric);
}

function byBenchmarkRows(rows, metric) {
  const groups = new Map();
  for (const row of rows) {
    if (row[metric] === null || row[metric] === undefined) continue;
    if (!groups.has(row.benchmark)) groups.set(row.benchmark, []);
    groups.get(row.benchmark).push(row);
  }
  for (const rows of groups.values()) rows.sort((a, b) => chartTime(a).localeCompare(chartTime(b)));
  return groups;
}

function filterGroups(groups, filterText) {
  const needle = filterText.trim().toLowerCase();
  const entries = Array.from(groups.entries());
  if (!needle) return entries;
  return entries.filter(([name]) => name.toLowerCase().includes(needle));
}

function chartRows(rows, metric, limit, axisScale) {
  let visible = rows.slice();
  if (limit > 0) visible = visible.slice(-limit);
  if (axisScale === "logarithmic") visible = visible.filter((row) => row[metric] > 0);
  return visible;
}

function groupDelta(rows, metric) {
  if (rows.length < 2) return null;
  return pctDelta(rows.at(-1)[metric], rows[0][metric]);
}

function largestMovers(groups, limit, axisScale, useDisplayWindow, direction, count) {
  return groups
    .map(([name, rows]) => [name, useDisplayWindow ? chartRows(rows, metric, limit, axisScale) : rows])
    .map(([name, rows]) => ({ name, rows, delta: groupDelta(rows, metric) }))
    .filter((item) => item.delta !== null && item.delta !== undefined && !Number.isNaN(item.delta))
    .filter((item) => direction === "both" || (direction === "slowdowns" ? item.delta > 0 : item.delta < 0))
    .sort((a, b) => {
      if (direction === "slowdowns") return b.delta - a.delta || a.name.localeCompare(b.name);
      if (direction === "speedups") return a.delta - b.delta || a.name.localeCompare(b.name);
      return Math.abs(b.delta) - Math.abs(a.delta) || a.name.localeCompare(b.name);
    })
    .slice(0, count)
    .map((item) => [item.name, item.rows]);
}

function focusSeries(name, pinned = false) {
  if (pinned) seriesFocus.pinned = seriesFocus.pinned === name ? null : name;
  else seriesFocus.hovered = name;
  applySeriesFocus();
}

function hoverSeries(name) {
  if (seriesFocus.hovered === name) return;
  seriesFocus.hovered = name;
  renderSeriesFocus();
}

function clearHoverSeries(name) {
  if (seriesFocus.hovered === name) {
    seriesFocus.hovered = null;
    renderSeriesFocus();
  }
}

function clearPinnedSeries() {
  seriesFocus.pinned = null;
  applySeriesFocus();
}

function applySeriesFocus() {
  if (!chart) return;
  const active = pinnedSeries();
  chart.data.datasets.forEach((dataset) => {
    const selected = !active || dataset.label === active;
    dataset.borderColor = selected ? dataset.baseColor : colorWithAlpha(dataset.baseColor, 0.18);
    dataset.backgroundColor = selected ? dataset.baseColor : colorWithAlpha(dataset.baseColor, 0.18);
    dataset.borderWidth = selected && active ? 4 : selected ? 2 : 1;
    dataset.pointRadius = selected ? dataset.basePointRadius : 0;
    dataset.pointHoverRadius = selected ? 7 : 0;
  });
  chart.update("none");
  renderSeriesFocus();
}

function renderSeriesFocus() {
  const active = focusedSeries();
  const selection = document.getElementById("chart-selection");
  if (!active) {
    selection.replaceChildren();
  } else {
    const clear = document.createElement("button");
    clear.type = "button";
    clear.textContent = "Clear";
    clear.addEventListener("click", clearPinnedSeries);
    selection.replaceChildren(document.createTextNode(`Selected: ${active}`), clear);
  }
  for (const button of document.querySelectorAll(".series-button")) {
    button.classList.toggle("series-active", button.dataset.series === active);
  }
}

function sparkline(rows, metric) {
  const values = rows.map((row) => row[metric]).filter((value) => value !== null && value !== undefined);
  return sparklineValues(values);
}

function sparklineValues(values) {
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
  const benchmarks = state.summary.benchmarks || unique(state.rows.map((row) => row.benchmark));
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

async function fetchJson(path) {
  const response = await fetch(path);
  if (!response.ok) throw new Error(`failed to load ${path}: ${response.status}`);
  return response.json();
}

async function loadFullRows() {
  if (!fullRowsPromise) {
    document.getElementById("summary").textContent = "Loading full benchmark history...";
    fullRowsPromise = fetchJson("results.json").then((rows) => {
      state.rows = rows;
      return rows;
    });
  }
  return fullRowsPromise;
}

async function loadSeriesRows(benchmark) {
  if (state.seriesRows.has(benchmark)) return state.seriesRows.get(benchmark);
  const entry = (state.summary.series || []).find((item) => item.benchmark === benchmark);
  if (!entry) return [];
  const rows = await fetchJson(entry.path);
  state.seriesRows.set(benchmark, rows);
  return rows;
}

async function rowsForChart(benchmark, filterText, limit, moverRange) {
  const needFull = needsFullHistory(limit, moverRange);
  if (benchmark !== "__all__" && !filterText.trim()) {
    const rows = needFull ? await loadSeriesRows(benchmark) : state.rows.filter((row) => row.benchmark === benchmark);
    return byBenchmarkRows(rows, metric);
  }
  if (needFull) await loadFullRows();
  return byBenchmark(metric);
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
        queueRender();
        document.getElementById("chart").scrollIntoView({ block: "nearest" });
      }
    : null;
}

function renderOverview() {
  const items = state.summary.overview || [];

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
    trendCell.innerHTML = sparklineValues(item.sparkline || []);

    tr.replaceChildren(nameCell, latestCell, previousCell, deltaCell, trendCell);
    tr.addEventListener("click", () => {
      document.getElementById("benchmark").value = item.benchmark;
      queueRender();
      document.getElementById("chart").scrollIntoView({ block: "nearest" });
    });
    return tr;
  }));
}

function renderHeatmap() {
  const heatmapData = state.summary.heatmap || {};
  const runTimes = heatmapData.run_times || [];
  const benchmarks = heatmapData.benchmarks || [];
  const values = heatmapData.values || [];
  const enoughRuns = runTimes.length >= minTrendRuns;
  document.getElementById("heatmap-note").textContent = enoughRuns
    ? `Latest ${runTimes.length} runs; color shows percent change from each benchmark's rolling baseline.`
    : `Heatmap activates after ${minTrendRuns} runs; currently ${runTimes.length}.`;

  if (!enoughRuns || benchmarks.length === 0) {
    const empty = document.createElement("div");
    empty.className = "heatmap-empty";
    empty.textContent = `Need ${minTrendRuns} runs for heatmap`;
    document.getElementById("heatmap").replaceChildren(empty);
    return;
  }

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
      const value = values[rowIndex]?.[columnIndex];
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

function renderSeriesPanel(datasets, showPanel) {
  const panel = document.getElementById("series-panel");
  panel.hidden = !showPanel;
  if (!showPanel) {
    panel.replaceChildren();
    return;
  }

  const list = document.createElement("div");
  list.className = "series-list";
  datasets.forEach((dataset, index) => {
    const button = document.createElement("button");
    button.className = "series-button";
    button.type = "button";
    button.dataset.series = dataset.label;
    button.title = dataset.label;
    const swatch = document.createElement("span");
    swatch.className = "series-swatch";
    swatch.style.background = dataset.borderColor;
    const name = document.createElement("span");
    name.className = "series-name";
    name.textContent = dataset.label;
    button.replaceChildren(swatch, name);
    button.addEventListener("mouseenter", () => hoverSeries(dataset.label));
    button.addEventListener("mouseleave", () => clearHoverSeries(dataset.label));
    button.addEventListener("click", () => focusSeries(dataset.label, true));
    list.appendChild(button);
  });
  panel.replaceChildren(list);
  renderSeriesFocus();
}

async function render() {
  const token = ++renderToken;
  seriesFocus.hovered = null;
  seriesFocus.pinned = null;
  const benchmark = document.getElementById("benchmark").value;
  const filterText = document.getElementById("benchmark-filter").value;
  const chartView = document.getElementById("chart-view").value;
  const moverRange = document.getElementById("mover-range").value;
  const moverDirection = document.getElementById("mover-direction").value;
  const moverCount = Math.max(1, Math.min(100, Number(document.getElementById("mover-count").value) || 20));
  const limit = Number(document.getElementById("limit").value);
  const axisScale = document.getElementById("axis-scale").value;
  const groups = await rowsForChart(benchmark, filterText, limit, moverRange);
  if (token !== renderToken) return;
  const filteredGroups = filterGroups(groups, filterText);
  let selectedGroups = benchmark === "__all__" || filterText.trim()
    ? filteredGroups
    : [[benchmark, groups.get(benchmark) || []]];
  const matchingSeriesCount = selectedGroups.length;
  let moversApplied = false;
  if (chartView === "movers" && selectedGroups.length > moverCount) {
    const movers = largestMovers(
      selectedGroups,
      limit,
      axisScale,
      moverRange === "recent",
      moverDirection,
      moverCount,
    );
    if (movers.length > 0) {
      selectedGroups = movers;
      moversApplied = true;
    }
  }
  const selectedRows = [];
  const datasets = selectedGroups.map(([name, groupRows], index) => {
    const rows = chartRows(groupRows, metric, limit, axisScale);
    selectedRows.push(...rows);
    const color = seriesColor(index);
    const pointRadius = benchmark === "__all__" || filterText.trim() ? 2 : 3;
    return {
      label: name,
      data: rows.map((row) => ({
        x: chartTime(row),
        y: row[metric],
        commit: row.commit_hash.slice(0, 12),
        commitHash: row.commit_hash,
        jobId: row.job_id,
        runTime: row.run_time,
      })),
      baseColor: color,
      basePointRadius: pointRadius,
      borderColor: color,
      backgroundColor: color,
      borderWidth: 2,
      pointRadius,
      pointHoverRadius: 6,
      tension: 0.22,
    };
  }).filter((dataset) => dataset.data.length > 0);
  const labels = unique(selectedRows.map((row) => chartTime(row)));

  if (chart) chart.destroy();
  chart = new Chart(document.getElementById("chart-canvas"), {
    type: "line",
    data: { labels, datasets },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      interaction: { mode: "nearest", intersect: false },
      onHover: (event, elements) => {
        hoverSeries(nearestChartSeries(event, elements));
      },
      onClick: async (event, elements) => {
        const points = chart.getElementsAtEventForMode(event.native || event, "nearest", { intersect: true }, true);
        if (await copyCommitHash(points[0])) return;
        if (await copyCommitRange(nearestChartSegment(event))) return;
        const series = nearestChartSeries(event, elements);
        if (series) focusSeries(series, true);
      },
      plugins: {
        legend: {
          display: false,
        },
        tooltip: {
          position: "offset",
          caretPadding: 14,
          callbacks: {
            title: (items) => items[0]?.raw?.x || "",
            label: (item) => `${item.dataset.label}: ${formatSeconds(item.raw.y)}`,
            afterLabel: (item) => `${item.raw.commit}\n${item.raw.runTime}\n${item.raw.jobId}`,
          },
        },
      },
      scales: {
        x: {
          type: "category",
          title: { display: true, text: "Commit time", color: cssColor("--muted") },
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
  renderSeriesPanel(datasets, benchmark === "__all__");

  const latestRows = selectedGroups
    .map(([name, groupRows]) => ({ name, latest: groupRows.at(-1) }))
    .filter((item) => item.latest);
  const latest = latestRows.length === 1 ? latestRows[0].latest : null;
  const filterSummary = filterText.trim() ? ` matching "${filterText.trim()}"` : "";
  const viewSummary = moversApplied
    ? `, showing ${datasets.length} ${moverRange === "recent" ? "recent" : "all-time"} ${moverDirection} movers from ${matchingSeriesCount}`
    : "";
  document.getElementById("summary").textContent = benchmark === "__all__"
    ? `Showing ${datasets.length} benchmark series${filterSummary}${viewSummary}${axisScale === "logarithmic" ? " on a log axis" : ""}.`
    : filterText.trim()
    ? `Showing ${datasets.length} benchmark series${filterSummary}${viewSummary}${axisScale === "logarithmic" ? " on a log axis" : ""}.`
    : latest
    ? `${benchmark}: latest ${formatSeconds(latest[metric])} at ${chartTime(latest)} (${latest.commit_hash.slice(0, 12)})`
    : "No results for this selection.";
  renderOverview();
  renderHeatmap();
}

function queueRender() {
  render().catch((error) => {
    document.getElementById("summary").textContent = error.message;
  });
}

async function main() {
  const [metadata, summary, rows] = await Promise.all([
    fetchJson("metadata.json"),
    fetchJson("summary.json"),
    fetchJson("recent-results.json"),
  ]);
  state.metadata = metadata;
  state.summary = summary;
  state.rows = rows;
  populate();
  queueRender();
  for (const id of ["benchmark", "chart-view", "mover-range", "mover-direction", "mover-count", "limit", "axis-scale"]) {
    document.getElementById(id).addEventListener("change", queueRender);
  }
  document.getElementById("mover-count").addEventListener("input", queueRender);
  document.getElementById("benchmark-filter").addEventListener("input", () => {
    document.getElementById("benchmark").value = "__all__";
    queueRender();
  });
}

main().catch((error) => { document.getElementById("summary").textContent = error.message; });
