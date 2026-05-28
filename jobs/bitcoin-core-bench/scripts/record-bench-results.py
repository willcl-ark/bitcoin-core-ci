#!/usr/bin/env python3
import argparse
import json
import pathlib
import sqlite3
import sys


SCHEMA = """
CREATE TABLE IF NOT EXISTS runs (
    id INTEGER PRIMARY KEY,
    job_id TEXT NOT NULL UNIQUE,
    commit_hash TEXT NOT NULL,
    commit_time TEXT NOT NULL,
    run_time TEXT NOT NULL,
    host TEXT NOT NULL,
    compiler TEXT NOT NULL,
    preset TEXT NOT NULL,
    min_time_ms INTEGER NOT NULL,
    artifact_dir TEXT NOT NULL,
    command TEXT NOT NULL,
    sample_index INTEGER NOT NULL DEFAULT 1,
    sample_count INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE IF NOT EXISTS results (
    run_id INTEGER NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
    row_index INTEGER NOT NULL,
    benchmark TEXT NOT NULL,
    unit TEXT,
    batch REAL,
    epochs INTEGER,
    iterations REAL,
    total_elapsed REAL,
    min_elapsed REAL,
    max_elapsed REAL,
    median_elapsed REAL,
    mdape_elapsed REAL,
    raw_json TEXT NOT NULL,
    PRIMARY KEY (run_id, row_index)
);

CREATE INDEX IF NOT EXISTS results_benchmark ON results(benchmark);
"""


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.tmp")
    with tmp.open("w") as f:
        json.dump(value, f, indent=2, sort_keys=True)
        f.write("\n")
    tmp.replace(path)


def write_metadata(args):
    write_json(
        args.metadata,
        {
            "artifact_dir": str(args.artifact_dir),
            "command": args.command,
            "commit": args.commit,
            "commit_time": args.commit_time,
            "compiler": args.compiler,
            "cpu_affinity": args.cpu_affinity,
            "cpuset_housekeeping": args.cpuset_housekeeping,
            "cpuset_shield": args.cpuset_shield,
            "host": args.host,
            "job_id": args.job_id,
            "min_time_ms": args.min_time_ms,
            "preset": args.preset,
            "run_time": args.run_time,
            "sample_count": args.sample_count,
            "sample_index": args.sample_index,
        },
    )


def first_present(row, keys):
    for key in keys:
        if key in row:
            return row[key]
    return None


def number_or_none(value):
    if isinstance(value, bool) or value is None:
        return None
    if isinstance(value, (int, float)):
        return value
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def int_or_none(value):
    number = number_or_none(value)
    if number is None:
        return None
    return int(number)


def benchmark_name(row):
    for key in ("name", "title", "benchmark"):
        value = row.get(key)
        if value:
            return str(value)
    return None


def result_rows(value):
    if isinstance(value, list):
        return [row for row in value if isinstance(row, dict) and benchmark_name(row)]
    if isinstance(value, dict):
        for key in ("benchmarks", "results"):
            rows = value.get(key)
            if isinstance(rows, list):
                return [row for row in rows if isinstance(row, dict) and benchmark_name(row)]
    return []


def ensure_schema(conn):
    conn.executescript(SCHEMA)
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


def insert_run(conn, metadata):
    ensure_schema(conn)
    commit_time = metadata.get("commit_time", metadata["run_time"])
    cursor = conn.execute(
        """
        INSERT INTO runs (
            job_id, commit_hash, commit_time, run_time, host, compiler, preset,
            min_time_ms, artifact_dir, command, sample_index, sample_count
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(job_id) DO UPDATE SET
            commit_hash = excluded.commit_hash,
            commit_time = excluded.commit_time,
            run_time = excluded.run_time,
            host = excluded.host,
            compiler = excluded.compiler,
            preset = excluded.preset,
            min_time_ms = excluded.min_time_ms,
            artifact_dir = excluded.artifact_dir,
            command = excluded.command,
            sample_index = excluded.sample_index,
            sample_count = excluded.sample_count
        RETURNING id
        """,
        (
            metadata["job_id"],
            metadata["commit"],
            commit_time,
            metadata["run_time"],
            metadata["host"],
            metadata["compiler"],
            metadata["preset"],
            metadata["min_time_ms"],
            metadata["artifact_dir"],
            metadata["command"],
            metadata.get("sample_index", 1),
            metadata.get("sample_count", 1),
        ),
    )
    return cursor.fetchone()[0]


def record(args):
    with args.metadata.open() as f:
        metadata = json.load(f)
    with args.bench_json.open() as f:
        bench_data = json.load(f)

    rows = result_rows(bench_data)
    if not rows:
        sys.exit(f"no benchmark rows found in {args.bench_json}")

    args.db.parent.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(args.db) as conn:
        run_id = insert_run(conn, metadata)
        conn.execute("DELETE FROM results WHERE run_id = ?", (run_id,))
        conn.executemany(
            """
            INSERT INTO results (
                run_id, row_index, benchmark, unit, batch, epochs, iterations,
                total_elapsed, min_elapsed, max_elapsed, median_elapsed,
                mdape_elapsed, raw_json
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                (
                    run_id,
                    index,
                    benchmark_name(row),
                    first_present(row, ("unit",)),
                    number_or_none(first_present(row, ("batch",))),
                    int_or_none(first_present(row, ("epochs",))),
                    number_or_none(
                        first_present(row, ("sum(iterations)", "iterations"))
                    ),
                    number_or_none(
                        first_present(
                            row,
                            (
                                "sumProduct(iterations, elapsed)",
                                "total",
                                "total_elapsed",
                            ),
                        )
                    ),
                    number_or_none(
                        first_present(
                            row,
                            ("minimum(elapsed)", "minimum", "min", "min_elapsed"),
                        )
                    ),
                    number_or_none(
                        first_present(
                            row,
                            ("maximum(elapsed)", "maximum", "max", "max_elapsed"),
                        )
                    ),
                    number_or_none(
                        first_present(row, ("median(elapsed)", "median", "median_elapsed"))
                    ),
                    number_or_none(
                        first_present(
                            row,
                            (
                                "medianAbsolutePercentError(elapsed)",
                                "mdape",
                                "mdape_elapsed",
                            ),
                        )
                    ),
                    json.dumps(row, sort_keys=True),
                )
                for index, row in enumerate(rows)
            ],
        )

    print(f"recorded {len(rows)} benchmark rows in {args.db}")


def main():
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(required=True)

    metadata_parser = subparsers.add_parser("write-metadata")
    metadata_parser.add_argument("--metadata", type=pathlib.Path, required=True)
    metadata_parser.add_argument("--job-id", required=True)
    metadata_parser.add_argument("--commit", required=True)
    metadata_parser.add_argument("--commit-time", required=True)
    metadata_parser.add_argument("--run-time", required=True)
    metadata_parser.add_argument("--sample-index", type=int, default=1)
    metadata_parser.add_argument("--sample-count", type=int, default=1)
    metadata_parser.add_argument("--host", required=True)
    metadata_parser.add_argument("--compiler", required=True)
    metadata_parser.add_argument("--preset", required=True)
    metadata_parser.add_argument("--min-time-ms", type=int, required=True)
    metadata_parser.add_argument("--artifact-dir", type=pathlib.Path, required=True)
    metadata_parser.add_argument("--cpu-affinity", default="")
    metadata_parser.add_argument("--cpuset-shield", default="")
    metadata_parser.add_argument("--cpuset-housekeeping", default="")
    metadata_parser.add_argument("--command", required=True)
    metadata_parser.set_defaults(func=write_metadata)

    record_parser = subparsers.add_parser("record")
    record_parser.add_argument("--db", type=pathlib.Path, required=True)
    record_parser.add_argument("--metadata", type=pathlib.Path, required=True)
    record_parser.add_argument("--bench-json", type=pathlib.Path, required=True)
    record_parser.set_defaults(func=record)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
