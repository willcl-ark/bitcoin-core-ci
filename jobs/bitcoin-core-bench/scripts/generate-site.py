#!/usr/bin/env python3
import argparse
import json
import pathlib
import sqlite3
import statistics
import tempfile


SITE_DIR = pathlib.Path(__file__).resolve().parents[1] / "site"


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
        sample_count = len(median_values)
        row = dict(first)
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
        row["mdape_elapsed"] = median_or_none(row["mdape_elapsed"] for row in samples)
        if sample_count >= 2:
            sample_median = row["median_elapsed"]
            row["mad_elapsed"] = statistics.median(
                abs(value - sample_median) for value in median_values
            )
        else:
            row["mad_elapsed"] = None
        aggregated.append(row)

    return sorted(
        aggregated,
        key=lambda row: (row["benchmark"], row["commit_time"], row["commit_hash"]),
    )


def write_json(path, value):
    tmp = path.with_name(f".{path.name}.tmp")
    with tmp.open("w") as f:
        json.dump(value, f, sort_keys=True)
        f.write("\n")
    tmp.replace(path)


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
            replace_file(
                output,
                asset.read_text().replace("__ASSET_VERSION__", version).encode(),
            )
        else:
            replace_file(output, asset.read_bytes())


def generate(args):
    args.output_dir.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(args.db) as conn:
        conn.row_factory = sqlite3.Row
        ensure_schema(conn)
        sample_rows = query_rows(conn)
        rows = aggregate_rows(sample_rows)
        runs = conn.execute("SELECT COUNT(*) FROM runs").fetchone()[0]

    write_json(args.output_dir / "results.json", rows)
    write_json(
        args.output_dir / "metadata.json",
        {
            "generated_at": args.generated_at,
            "results": len(rows),
            "runs": runs,
            "samples": len(sample_rows),
        },
    )
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
