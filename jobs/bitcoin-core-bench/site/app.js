const state = { rows: [], metadata: {} };
const minTrendRuns = 7;

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
    ? "Color shows percent change from each benchmark's rolling baseline."
    : `Heatmap activates after ${minTrendRuns} runs; currently ${runTimes.length}.`;

  if (!enoughRuns || benchmarks.length === 0) {
    Plotly.react("heatmap", [], {
      annotations: [{ text: `Need ${minTrendRuns} runs for heatmap`, x: 0.5, y: 0.5, xref: "paper", yref: "paper", showarrow: false }],
      xaxis: { visible: false },
      yaxis: { visible: false },
      paper_bgcolor: "rgba(0,0,0,0)",
      plot_bgcolor: "rgba(0,0,0,0)",
      font: { color: getComputedStyle(document.documentElement).getPropertyValue("--text") },
      margin: { t: 24, r: 24, b: 24, l: 24 },
    }, { responsive: true, displayModeBar: false });
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

  Plotly.react("heatmap", [{
    type: "heatmap",
    x: runTimes,
    y: benchmarks,
    z,
    zmid: 0,
    colorscale: [[0, "#287d3c"], [0.5, "#f2f4f7"], [1, "#b42318"]],
    colorbar: { title: "%" },
    hovertemplate: "%{y}<br>%{x}<br>%{z:.2f}%<extra></extra>",
  }], {
    margin: { t: 24, r: 24, b: 80, l: 260 },
    paper_bgcolor: "rgba(0,0,0,0)",
    plot_bgcolor: "rgba(0,0,0,0)",
    font: { color: getComputedStyle(document.documentElement).getPropertyValue("--text") },
    xaxis: { title: "Run time", gridcolor: getComputedStyle(document.documentElement).getPropertyValue("--line") },
    yaxis: { automargin: true },
  }, { responsive: true, displayModeBar: true });
}

function render() {
  const benchmark = document.getElementById("benchmark").value;
  const metric = document.getElementById("metric").value;
  const limit = Number(document.getElementById("limit").value);
  const groups = byBenchmark(metric);
  const selectedGroups = benchmark === "__all__"
    ? Array.from(groups.entries())
    : [[benchmark, groups.get(benchmark) || []]];
  const traces = selectedGroups.map(([name, groupRows]) => {
    let rows = groupRows.slice();
    if (limit > 0) rows = rows.slice(-limit);
    return {
      type: "scatter",
      mode: "lines+markers",
      name,
      x: rows.map((row) => row.run_time),
      y: rows.map((row) => row[metric]),
      line: { width: 2 },
      marker: { size: 5 },
      customdata: rows.map((row) => [row.commit_hash.slice(0, 12), row.job_id]),
      hovertemplate: "%{x}<br>%{customdata[0]}<br>%{y:.9f} s<extra>%{fullData.name}</extra>",
    };
  }).filter((trace) => trace.x.length > 0);

  Plotly.react("chart", traces, {
    margin: { t: 24, r: benchmark === "__all__" ? 180 : 24, b: 56, l: 72 },
    paper_bgcolor: "rgba(0,0,0,0)",
    plot_bgcolor: "rgba(0,0,0,0)",
    font: { color: getComputedStyle(document.documentElement).getPropertyValue("--text") },
    showlegend: benchmark === "__all__",
    legend: { x: 1.02, y: 1, xanchor: "left", yanchor: "top" },
    xaxis: { title: "Run time", gridcolor: getComputedStyle(document.documentElement).getPropertyValue("--line") },
    yaxis: { title: metric.replaceAll("_", " "), gridcolor: getComputedStyle(document.documentElement).getPropertyValue("--line") },
  }, { responsive: true, displayModeBar: true });

  const latestRows = selectedGroups
    .map(([name, groupRows]) => ({ name, latest: groupRows.at(-1) }))
    .filter((item) => item.latest);
  const latest = latestRows.length === 1 ? latestRows[0].latest : null;
  document.getElementById("summary").textContent = benchmark === "__all__"
    ? `Showing ${traces.length} benchmark series.`
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
  for (const id of ["benchmark", "metric", "limit"]) {
    document.getElementById(id).addEventListener("change", render);
  }
}

main().catch((error) => { document.getElementById("summary").textContent = error.message; });
