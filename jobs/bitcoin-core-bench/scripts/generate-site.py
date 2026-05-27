#!/usr/bin/env python3
import argparse
import json
import pathlib
import shutil
import sqlite3


SITE_DIR = pathlib.Path(__file__).resolve().parents[1] / "site"


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
    for asset in SITE_DIR.iterdir():
        if asset.is_file():
            shutil.copy2(asset, args.output_dir / asset.name)
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
