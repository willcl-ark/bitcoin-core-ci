#!/usr/bin/env python3
import argparse
import json
import pathlib
import sqlite3


INDEX_HTML = """<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Bitcoin Core Benchmarks</title>
  <script src="https://cdn.plot.ly/plotly-3.0.1.min.js"></script>
  <style>
    :root {
      color-scheme: light dark;
      --bg: #f8fafc;
      --panel: #ffffff;
      --text: #172033;
      --muted: #667085;
      --line: #d0d5dd;
      --accent: #0b7285;
    }

    @media (prefers-color-scheme: dark) {
      :root {
        --bg: #111827;
        --panel: #1f2937;
        --text: #f9fafb;
        --muted: #aeb6c2;
        --line: #374151;
        --accent: #4fb3c8;
      }
    }

    * {
      box-sizing: border-box;
    }

    body {
      margin: 0;
      background: var(--bg);
      color: var(--text);
      font-family: ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    }

    header {
      border-bottom: 1px solid var(--line);
      background: var(--panel);
    }

    main,
    .header-inner {
      width: min(1200px, calc(100vw - 32px));
      margin: 0 auto;
    }

    .header-inner {
      padding: 24px 0;
      display: flex;
      gap: 16px;
      align-items: end;
      justify-content: space-between;
      flex-wrap: wrap;
    }

    h1 {
      margin: 0;
      font-size: 28px;
      line-height: 1.2;
    }

    .meta {
      color: var(--muted);
      font-size: 14px;
    }

    main {
      padding: 24px 0 40px;
    }

    .toolbar {
      display: grid;
      grid-template-columns: minmax(220px, 1fr) repeat(2, minmax(140px, 180px));
      gap: 12px;
      align-items: end;
      margin-bottom: 20px;
    }

    label {
      display: grid;
      gap: 6px;
      color: var(--muted);
      font-size: 13px;
      font-weight: 600;
    }

    select {
      width: 100%;
      border: 1px solid var(--line);
      border-radius: 6px;
      background: var(--panel);
      color: var(--text);
      padding: 9px 10px;
      font: inherit;
    }

    #chart {
      width: 100%;
      height: min(680px, calc(100vh - 230px));
      min-height: 420px;
      border: 1px solid var(--line);
      border-radius: 8px;
      background: var(--panel);
    }

    .summary {
      margin-top: 16px;
      color: var(--muted);
      font-size: 14px;
    }

    @media (max-width: 760px) {
      .toolbar {
        grid-template-columns: 1fr;
      }

      #chart {
        height: 520px;
      }
    }
  </style>
</head>
<body>
  <header>
    <div class="header-inner">
      <div>
        <h1>Bitcoin Core Benchmarks</h1>
        <div class="meta" id="updated"></div>
      </div>
      <div class="meta" id="run-count"></div>
    </div>
  </header>
  <main>
    <div class="toolbar">
      <label>
        Benchmark
        <select id="benchmark"></select>
      </label>
      <label>
        Metric
        <select id="metric">
          <option value="median_elapsed">Median elapsed</option>
          <option value="min_elapsed">Minimum elapsed</option>
          <option value="max_elapsed">Maximum elapsed</option>
          <option value="total_elapsed">Total elapsed</option>
        </select>
      </label>
      <label>
        Recent runs
        <select id="limit">
          <option value="30">30</option>
          <option value="90" selected>90</option>
          <option value="180">180</option>
          <option value="365">365</option>
          <option value="0">All</option>
        </select>
      </label>
    </div>
    <div id="chart"></div>
    <div class="summary" id="summary"></div>
  </main>
  <script>
    const state = {
      rows: [],
      metadata: {},
    };

    function formatSeconds(value) {
      if (value === null || value === undefined) return "n/a";
      if (value < 0.000001) return `${(value * 1e9).toFixed(2)} ns`;
      if (value < 0.001) return `${(value * 1e6).toFixed(2)} us`;
      if (value < 1) return `${(value * 1e3).toFixed(2)} ms`;
      return `${value.toFixed(3)} s`;
    }

    function unique(values) {
      return Array.from(new Set(values)).sort((a, b) => a.localeCompare(b));
    }

    function populate() {
      const benchmarks = unique(state.rows.map((row) => row.benchmark));
      const select = document.getElementById("benchmark");
      select.replaceChildren(...benchmarks.map((name) => {
        const option = document.createElement("option");
        option.value = name;
        option.textContent = name;
        return option;
      }));
      document.getElementById("updated").textContent = `Updated ${state.metadata.generated_at || "unknown"}`;
      document.getElementById("run-count").textContent = `${state.metadata.runs || 0} runs, ${state.metadata.results || 0} results`;
    }

    function render() {
      const benchmark = document.getElementById("benchmark").value;
      const metric = document.getElementById("metric").value;
      const limit = Number(document.getElementById("limit").value);
      let rows = state.rows.filter((row) => row.benchmark === benchmark && row[metric] !== null);
      rows.sort((a, b) => a.run_time.localeCompare(b.run_time));
      if (limit > 0) rows = rows.slice(-limit);

      const y = rows.map((row) => row[metric]);
      const trace = {
        type: "scatter",
        mode: "lines+markers",
        x: rows.map((row) => row.run_time),
        y,
        line: { color: "#0b7285", width: 2 },
        marker: { size: 5 },
        customdata: rows.map((row) => [row.commit_hash.slice(0, 12), row.job_id]),
        hovertemplate: "%{x}<br>%{customdata[0]}<br>%{y:.9f} s<extra></extra>",
      };

      Plotly.react("chart", [trace], {
        margin: { t: 24, r: 24, b: 56, l: 72 },
        paper_bgcolor: "rgba(0,0,0,0)",
        plot_bgcolor: "rgba(0,0,0,0)",
        font: { color: getComputedStyle(document.documentElement).getPropertyValue("--text") },
        xaxis: { title: "Run time", gridcolor: getComputedStyle(document.documentElement).getPropertyValue("--line") },
        yaxis: { title: metric.replaceAll("_", " "), gridcolor: getComputedStyle(document.documentElement).getPropertyValue("--line") },
      }, { responsive: true, displayModeBar: true });

      const latest = rows.at(-1);
      document.getElementById("summary").textContent = latest
        ? `${benchmark}: latest ${formatSeconds(latest[metric])} at ${latest.run_time} (${latest.commit_hash.slice(0, 12)})`
        : "No results for this selection.";
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

    main().catch((error) => {
      document.getElementById("summary").textContent = error.message;
    });
  </script>
</body>
</html>
"""


def query_rows(conn):
    return [
        dict(row)
        for row in conn.execute(
            """
            SELECT
                runs.job_id,
                runs.commit_hash,
                runs.run_time,
                runs.host,
                runs.compiler,
                runs.preset,
                runs.min_time_ms,
                results.benchmark,
                results.unit,
                results.batch,
                results.epochs,
                results.iterations,
                results.total_elapsed,
                results.min_elapsed,
                results.max_elapsed,
                results.median_elapsed,
                results.mdape_elapsed
            FROM results
            JOIN runs ON runs.id = results.run_id
            ORDER BY results.benchmark, runs.run_time, results.row_index
            """
        )
    ]


def write_json(path, value):
    tmp = path.with_name(f".{path.name}.tmp")
    with tmp.open("w") as f:
        json.dump(value, f, sort_keys=True)
        f.write("\n")
    tmp.replace(path)


def generate(args):
    args.output_dir.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(args.db) as conn:
        conn.row_factory = sqlite3.Row
        rows = query_rows(conn)
        runs = conn.execute("SELECT COUNT(*) FROM runs").fetchone()[0]

    write_json(args.output_dir / "results.json", rows)
    write_json(
        args.output_dir / "metadata.json",
        {
            "generated_at": args.generated_at,
            "results": len(rows),
            "runs": runs,
        },
    )
    (args.output_dir / "index.html").write_text(INDEX_HTML)
    print(f"generated benchmark dashboard in {args.output_dir}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--db", type=pathlib.Path, required=True)
    parser.add_argument("--output-dir", type=pathlib.Path, required=True)
    parser.add_argument("--generated-at", required=True)
    args = parser.parse_args()
    generate(args)


if __name__ == "__main__":
    main()
