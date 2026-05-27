#!/usr/bin/env python3
import argparse
import json
import pathlib
import shutil
import sqlite3


SITE_DIR = pathlib.Path(__file__).resolve().parents[1] / "site"


def ensure_schema(conn):
    columns = {
        row[1] for row in conn.execute("PRAGMA table_info(runs)")
    }
    if "commit_time" not in columns:
        conn.execute("ALTER TABLE runs ADD COLUMN commit_time TEXT")
        conn.execute("UPDATE runs SET commit_time = run_time WHERE commit_time IS NULL")


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
            ORDER BY results.benchmark, runs.commit_time, results.row_index
            """
        )
    ]


def write_json(path, value):
    tmp = path.with_name(f".{path.name}.tmp")
    with tmp.open("w") as f:
        json.dump(value, f, sort_keys=True)
        f.write("\n")
    tmp.replace(path)


def asset_version(value):
    return "".join(ch for ch in value if ch.isalnum())


def copy_assets(output_dir, version):
    for asset in SITE_DIR.iterdir():
        if not asset.is_file():
            continue
        output = output_dir / asset.name
        if asset.name == "index.html":
            output.write_text(
                asset.read_text().replace("__ASSET_VERSION__", version)
            )
        else:
            shutil.copy2(asset, output)


def generate(args):
    args.output_dir.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(args.db) as conn:
        conn.row_factory = sqlite3.Row
        ensure_schema(conn)
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
