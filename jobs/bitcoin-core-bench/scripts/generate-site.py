#!/usr/bin/env python3
import argparse
import datetime
import gzip
import hashlib
import json
import pathlib
import re
import sqlite3
import statistics
import tempfile


SITE_DIR = pathlib.Path(__file__).resolve().parents[1] / "site"
RECENT_RUNS = 30
MIN_TREND_RUNS = 7
NATURAL_RANGE_DAYS = 30
MIN_NATURAL_RANGE_POINTS = 3
METRIC = "ns_per_unit"


def ensure_schema(conn):
    columns = {
        row[1] for row in conn.execute("PRAGMA table_info(runs)")
    }
    if "commit_time" not in columns:
        conn.execute("ALTER TABLE runs ADD COLUMN commit_time TEXT")
        conn.execute("UPDATE runs SET commit_time = run_time WHERE commit_time IS NULL")
    if "sample_index" not in columns:
        conn.execute("ALTER TABLE runs ADD COLUMN sample_index INTEGER NOT NULL DEFAULT 1")
    if "sample_count" not in columns:
        conn.execute("ALTER TABLE runs ADD COLUMN sample_count INTEGER NOT NULL DEFAULT 1")


def query_rows(conn):
    return [
        dict(row)
        for row in conn.execute(
            """
            SELECT
                runs.job_id,
                runs.commit_hash,
                runs.commit_time,
                runs.run_time,
                runs.host,
                runs.compiler,
                runs.preset,
                runs.min_time_ms,
                runs.artifact_dir,
                results.benchmark,
                results.unit,
                results.batch,
                results.epochs,
                results.iterations,
                results.total_elapsed,
                results.min_elapsed,
                results.max_elapsed,
                results.median_elapsed,
                results.mdape_elapsed,
                runs.sample_index,
                runs.sample_count
            FROM results
            JOIN runs ON runs.id = results.run_id
            ORDER BY results.benchmark, runs.commit_time, results.row_index
            """
        )
    ]


def median_or_none(values):
    present = [value for value in values if value is not None]
    if not present:
        return None
    return statistics.median(present)


def ns_per_unit(row):
    if row["median_elapsed"] is None or not row["batch"]:
        return None
    return row["median_elapsed"] * 1e9 / row["batch"]


def series_key(row):
    return (row["benchmark"], row["unit"])


def series_label(benchmark, unit):
    return f"{benchmark} ({unit})"


def aggregate_rows(rows):
    groups = {}
    for row in rows:
        key = (
            row["commit_hash"],
            row["host"],
            row["compiler"],
            row["preset"],
            row["min_time_ms"],
            row["benchmark"],
            row["unit"],
        )
        groups.setdefault(key, []).append(row)

    aggregated = []
    for samples in groups.values():
        samples.sort(key=lambda row: (row["sample_index"], row["job_id"]))
        first = samples[0]
        median_values = [
            row["median_elapsed"]
            for row in samples
            if row["median_elapsed"] is not None
        ]
        ns_values = [
            ns_value
            for row in samples
            for ns_value in [ns_per_unit(row)]
            if ns_value is not None
        ]
        sample_count = len(median_values)
        row = dict(first)
        row["series"] = series_label(row["benchmark"], row["unit"])
        row["job_id"] = ",".join(row["job_id"] for row in samples)
        row["run_time"] = max(row["run_time"] for row in samples)
        row["sample_index"] = None
        row["sample_count"] = sample_count
        row["raw_sample_count"] = len(samples)
        row["total_elapsed"] = median_or_none(row["total_elapsed"] for row in samples)
        row["min_elapsed"] = min(
            (row["min_elapsed"] for row in samples if row["min_elapsed"] is not None),
            default=None,
        )
        row["max_elapsed"] = max(
            (row["max_elapsed"] for row in samples if row["max_elapsed"] is not None),
            default=None,
        )
        row["median_elapsed"] = median_or_none(median_values)
        row["sample_median_elapsed_values"] = median_values
        row["ns_per_unit"] = median_or_none(ns_values)
        row["sample_ns_per_unit_values"] = ns_values
        row["mdape_elapsed"] = median_or_none(row["mdape_elapsed"] for row in samples)
        if len(ns_values) >= 2:
            sample_median = row["ns_per_unit"]
            row["mad_ns_per_unit"] = statistics.median(
                abs(value - sample_median) for value in ns_values
            )
        else:
            row["mad_ns_per_unit"] = None
        aggregated.append(row)

    return sorted(
        aggregated,
        key=lambda row: (row["benchmark"], row["unit"], row["commit_time"], row["commit_hash"]),
    )


def chart_time(row):
    return row["commit_time"] or row["run_time"]


def parse_chart_time(value):
    if not value:
        return None
    return datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))


def unique_sorted(values):
    return sorted(set(values))


def pct_delta(latest, base):
    if not base:
        return None
    return ((latest - base) / base) * 100


def rows_by_series(rows):
    groups = {}
    for row in rows:
        if row[METRIC] is None:
            continue
        groups.setdefault(series_key(row), []).append(row)
    for group_rows in groups.values():
        group_rows.sort(key=chart_time)
    return groups


def sparkline_values(rows):
    return [row[METRIC] for row in rows[-30:] if row[METRIC] is not None]


def natural_range(group_rows, latest):
    result = {
        "count": 0,
        "days": NATURAL_RANGE_DAYS,
        "delta": None,
        "direction": "insufficient",
        "eligible": False,
        "end": None,
        "max": None,
        "min": None,
        "min_points": MIN_NATURAL_RANGE_POINTS,
        "start": None,
    }
    latest_value = latest[METRIC]
    latest_time = parse_chart_time(chart_time(latest))
    if latest_value is None or latest_time is None:
        return result

    cutoff = latest_time - datetime.timedelta(days=NATURAL_RANGE_DAYS)
    prior_rows = []
    for row in group_rows:
        row_time = parse_chart_time(chart_time(row))
        if row_time is None or row_time >= latest_time or row_time < cutoff:
            continue
        if row[METRIC] is not None:
            prior_rows.append(row)

    result["count"] = len(prior_rows)
    if not prior_rows:
        return result

    values = [row[METRIC] for row in prior_rows]
    result["min"] = min(values)
    result["max"] = max(values)
    result["start"] = chart_time(prior_rows[0])
    result["end"] = chart_time(prior_rows[-1])
    if len(prior_rows) < MIN_NATURAL_RANGE_POINTS:
        return result

    result["eligible"] = True
    if latest_value < result["min"]:
        result["direction"] = "faster"
        result["delta"] = pct_delta(latest_value, result["min"])
    elif latest_value > result["max"]:
        result["direction"] = "slower"
        result["delta"] = pct_delta(latest_value, result["max"])
    else:
        result["direction"] = "within"
        result["delta"] = 0
    return result


def overview_rows(rows):
    items = []
    for (benchmark, unit), group_rows in rows_by_series(rows).items():
        latest = group_rows[-1]
        previous = group_rows[-2] if len(group_rows) > 1 else None
        delta = pct_delta(latest[METRIC], previous[METRIC]) if previous else None
        items.append(
            {
                "benchmark": benchmark,
                "unit": unit,
                "series": series_label(benchmark, unit),
                "latest": latest,
                "natural_range": natural_range(group_rows, latest),
                "previous": previous,
                "delta": delta,
                "sparkline": sparkline_values(group_rows),
            }
        )
    return sorted(
        items,
        key=lambda item: (
            -(abs(item["delta"]) if item["delta"] is not None else -1),
            item["series"],
        ),
    )


def heatmap_data(rows):
    run_times = unique_sorted(chart_time(row) for row in rows)
    groups = rows_by_series(rows)
    series = sorted(groups, key=lambda key: series_label(*key))
    if len(run_times) < MIN_TREND_RUNS or not series:
        return {
            "benchmarks": [series_label(*key) for key in series],
            "run_times": run_times,
            "values": [],
        }

    values = []
    for key in series:
        by_time = {chart_time(row): row[METRIC] for row in groups[key]}
        history = []
        benchmark_values = []
        for run_time in run_times:
            value = by_time.get(run_time)
            if value is None:
                benchmark_values.append(None)
                continue
            baseline_values = sorted(history[-6:])
            history.append(value)
            if len(baseline_values) < 3:
                benchmark_values.append(None)
                continue
            median = baseline_values[len(baseline_values) // 2]
            benchmark_values.append(pct_delta(value, median))
        values.append(benchmark_values)

    return {
        "benchmarks": [series_label(*key) for key in series],
        "run_times": run_times,
        "values": values,
    }


def recent_rows(rows):
    run_times = unique_sorted(chart_time(row) for row in rows)
    recent_times = set(run_times[-RECENT_RUNS:])
    return [row for row in rows if chart_time(row) in recent_times]


def benchmark_slug(name):
    slug = re.sub(r"[^A-Za-z0-9_.-]+", "-", name).strip("-").lower()
    if not slug:
        slug = "benchmark"
    digest = hashlib.sha1(name.encode()).hexdigest()[:12]
    return f"{slug[:80]}-{digest}"


def series_manifest(rows):
    manifest = []
    for (benchmark, unit), group_rows in rows_by_series(rows).items():
        label = series_label(benchmark, unit)
        manifest.append(
            {
                "benchmark": benchmark,
                "unit": unit,
                "series": label,
                "path": f"series/{benchmark_slug(label)}.json",
                "points": len(group_rows),
            }
        )
    return sorted(manifest, key=lambda item: item["series"])


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.tmp")
    with tmp.open("w") as f:
        json.dump(value, f, sort_keys=True)
        f.write("\n")
    tmp.replace(path)
    write_gzip(path)


def write_gzip(path):
    replace_file(
        path.with_suffix(path.suffix + ".gz"),
        gzip.compress(path.read_bytes(), compresslevel=9),
    )


def replace_file(path, data):
    tmp = None
    try:
        with tempfile.NamedTemporaryFile(
            "wb",
            dir=path.parent,
            prefix=f".{path.name}.",
            delete=False,
        ) as f:
            f.write(data)
            tmp = pathlib.Path(f.name)
        tmp.chmod(0o644)
        tmp.replace(path)
    finally:
        if tmp is not None and tmp.exists():
            tmp.unlink()


def asset_version(value):
    return "".join(ch for ch in value if ch.isalnum())


def copy_assets(output_dir, version):
    for asset in SITE_DIR.iterdir():
        if not asset.is_file():
            continue
        output = output_dir / asset.name
        if asset.name == "index.html":
            output_data = asset.read_text().replace("__ASSET_VERSION__", version).encode()
            replace_file(
                output,
                output_data,
            )
        else:
            output_data = asset.read_bytes()
            replace_file(output, output_data)
        write_gzip(output)


def write_series(output_dir, rows):
    series_dir = output_dir / "series"
    series_dir.mkdir(parents=True, exist_ok=True)
    for stale in list(series_dir.glob("*.json")) + list(series_dir.glob("*.json.gz")):
        stale.unlink()
    for (benchmark, unit), group_rows in rows_by_series(rows).items():
        write_json(series_dir / f"{benchmark_slug(series_label(benchmark, unit))}.json", group_rows)


def generate(args):
    args.output_dir.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(args.db) as conn:
        conn.row_factory = sqlite3.Row
        ensure_schema(conn)
        sample_rows = query_rows(conn)
        rows = aggregate_rows(sample_rows)
        runs = conn.execute("SELECT COUNT(*) FROM runs").fetchone()[0]

    manifest = series_manifest(rows)
    recent = recent_rows(rows)
    write_json(args.output_dir / "results.json", rows)
    write_json(args.output_dir / "recent-results.json", recent)
    write_json(
        args.output_dir / "summary.json",
        {
            "benchmarks": [item["series"] for item in manifest],
            "heatmap": heatmap_data(recent),
            "overview": overview_rows(rows),
            "recent_run_count": RECENT_RUNS,
            "series": manifest,
        },
    )
    write_json(
        args.output_dir / "metadata.json",
        {
            "generated_at": args.generated_at,
            "results": len(rows),
            "runs": runs,
            "samples": len(sample_rows),
        },
    )
    write_series(args.output_dir, rows)
    copy_assets(args.output_dir, asset_version(args.generated_at))
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
