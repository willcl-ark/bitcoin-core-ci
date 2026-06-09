#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import pathlib
import platform
import shutil
import sqlite3
import subprocess
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

CREATE TABLE IF NOT EXISTS run_environment (
    run_id INTEGER PRIMARY KEY REFERENCES runs(id) ON DELETE CASCADE,
    before_json TEXT NOT NULL,
    during_json TEXT NOT NULL DEFAULT '{}',
    after_json TEXT NOT NULL,
    compiler_path TEXT,
    compiler_version TEXT,
    cmake_path TEXT,
    cmake_version TEXT,
    ninja_path TEXT,
    ninja_version TEXT,
    kernel_release TEXT,
    kernel_cmdline TEXT,
    nixos_system TEXT,
    ci_flake TEXT,
    cpu_affinity TEXT,
    cpuset_shield TEXT,
    boost_before TEXT,
    boost_during TEXT,
    boost_after TEXT
);
"""


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.tmp")
    with tmp.open("w") as f:
        json.dump(value, f, indent=2, sort_keys=True)
        f.write("\n")
    tmp.replace(path)


def read_text(path):
    try:
        return pathlib.Path(path).read_text().strip()
    except (FileNotFoundError, NotADirectoryError, PermissionError, OSError):
        return None


def readlink(path):
    try:
        return os.readlink(path)
    except OSError:
        return None


def sha256_file(path):
    try:
        with pathlib.Path(path).open("rb") as f:
            return hashlib.file_digest(f, "sha256").hexdigest()
    except (FileNotFoundError, NotADirectoryError, PermissionError, OSError):
        return None


def command_output(command):
    try:
        completed = subprocess.run(
            command,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=3,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired, OSError) as err:
        return {"command": command, "error": str(err)}

    return {
        "command": command,
        "exit_code": completed.returncode,
        "stdout": completed.stdout.strip(),
        "stderr": completed.stderr.strip(),
    }


def tool_version(command):
    path = shutil.which(command)
    if path is None:
        return {"path": None, "version": None}

    version = command_output([path, "--version"])
    return {
        "path": path,
        "version": (version.get("stdout") or "").splitlines()[0]
        if version.get("stdout")
        else None,
    }


def write_toolchain(args):
    write_json(
        args.output,
        {
            name: tool_version(name)
            for name in ("gcc", "g++", "cc", "c++", "cmake", "ninja", "ld", "ccache")
        },
    )


def expand_cpu_list(cpu_list):
    cpus = []
    for part in cpu_list.split(","):
        part = part.strip()
        if not part:
            continue
        if "-" in part:
            start, end = part.split("-", 1)
            if start.isdigit() and end.isdigit():
                cpus.extend(range(int(start), int(end) + 1))
        elif part.isdigit():
            cpus.append(int(part))
    return sorted(set(cpus))


def cpu_state(cpus):
    result = {}
    for cpu in cpus:
        base = pathlib.Path(f"/sys/devices/system/cpu/cpu{cpu}")
        cpufreq = base / "cpufreq"
        result[str(cpu)] = {
            "online": read_text(base / "online"),
            "thread_siblings_list": read_text(base / "topology/thread_siblings_list"),
            "scaling_governor": read_text(cpufreq / "scaling_governor"),
            "scaling_cur_freq": read_text(cpufreq / "scaling_cur_freq"),
            "scaling_min_freq": read_text(cpufreq / "scaling_min_freq"),
            "scaling_max_freq": read_text(cpufreq / "scaling_max_freq"),
            "cpuinfo_min_freq": read_text(cpufreq / "cpuinfo_min_freq"),
            "cpuinfo_max_freq": read_text(cpufreq / "cpuinfo_max_freq"),
        }
    return result


def systemd_cpu_properties():
    units = [
        "system.slice",
        "user.slice",
        "init.scope",
        "ci-bitcoin-bench.slice",
    ]
    return {
        unit: command_output(["systemctl", "show", "-p", "AllowedCPUs", unit])
        for unit in units
    }


def pressure_state():
    return {
        name: read_text(pathlib.Path("/proc/pressure") / name)
        for name in ("cpu", "io", "memory")
    }


def thermal_state():
    zones = {}
    for path in sorted(pathlib.Path("/sys/class/thermal").glob("thermal_zone*")):
        zones[path.name] = {
            "type": read_text(path / "type"),
            "temp": read_text(path / "temp"),
        }

    hwmon = {}
    for path in sorted(pathlib.Path("/sys/class/hwmon").glob("hwmon*")):
        temps = {}
        for temp_input in sorted(path.glob("temp*_input")):
            prefix = temp_input.name.removesuffix("_input")
            temps[prefix] = {
                "input": read_text(temp_input),
                "label": read_text(path / f"{prefix}_label"),
            }
        hwmon[path.name] = {
            "name": read_text(path / "name"),
            "temps": temps,
        }

    return {"thermal_zones": zones, "hwmon": hwmon}


def interrupt_state(cpus):
    text = read_text("/proc/interrupts")
    if text is None:
        return None

    lines = text.splitlines()
    if not lines:
        return None

    header = lines[0].split()
    cpu_columns = {
        int(name.removeprefix("CPU")): index + 1
        for index, name in enumerate(header)
        if name.startswith("CPU") and name.removeprefix("CPU").isdigit()
    }
    wanted_columns = [cpu_columns[cpu] for cpu in cpus if cpu in cpu_columns]
    selected = [lines[0]]
    for line in lines[1:]:
        fields = line.split()
        if not fields:
            continue
        for column in wanted_columns:
            if column < len(fields) and fields[column].isdigit() and int(fields[column]):
                selected.append(line)
                break
    return selected


def load_json(path):
    if path is None:
        return None
    try:
        with pathlib.Path(path).open() as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return None


def write_environment(args):
    affinity_cpus = expand_cpu_list(args.cpu_affinity)
    shield_cpus = expand_cpu_list(args.cpuset_shield)
    cpus = sorted(set(affinity_cpus + shield_cpus))
    ci_flake = os.environ.get("CI_FLAKE")
    snapshot = {
        "captured_at": args.captured_at,
        "phase": args.phase,
        "toolchain": load_json(args.toolchain),
        "kernel": {
            "release": platform.release(),
            "version": platform.version(),
            "cmdline": read_text("/proc/cmdline"),
        },
        "nixos": {
            "current_system": readlink("/run/current-system"),
        },
        "nix": {
            "ci_flake": ci_flake,
            "ci_flake_lock_sha256": sha256_file(pathlib.Path(ci_flake) / "flake.lock")
            if ci_flake
            else None,
        },
        "benchmark": {
            "cpu_affinity": args.cpu_affinity,
            "cpuset_shield": args.cpuset_shield,
            "cpuset_housekeeping": args.cpuset_housekeeping,
            "boost": read_text("/sys/devices/system/cpu/cpufreq/boost"),
        },
        "cpu": {
            "isolated": read_text("/sys/devices/system/cpu/isolated"),
            "nohz_full": read_text("/sys/devices/system/cpu/nohz_full"),
            "cpus": cpu_state(cpus),
        },
        "systemd": {
            "allowed_cpus": systemd_cpu_properties(),
        },
        "proc": {
            "loadavg": read_text("/proc/loadavg"),
            "uptime": read_text("/proc/uptime"),
            "pressure": pressure_state(),
        },
        "thermal": thermal_state(),
        "interrupts": interrupt_state(cpus),
    }
    write_json(args.output, snapshot)


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


def environment_summary(before, during, after):
    primary = during or before or {}
    toolchain = primary.get("toolchain") or {}
    kernel = primary.get("kernel") or {}
    nixos = primary.get("nixos") or {}
    nix = primary.get("nix") or {}
    benchmark_before = (before or {}).get("benchmark") or {}
    benchmark_during = (during or {}).get("benchmark") or {}
    benchmark_after = (after or {}).get("benchmark") or {}
    gcc = toolchain.get("gcc") or {}
    cmake = toolchain.get("cmake") or {}
    ninja = toolchain.get("ninja") or {}
    return {
        "compiler_path": gcc.get("path"),
        "compiler_version": gcc.get("version"),
        "cmake_path": cmake.get("path"),
        "cmake_version": cmake.get("version"),
        "ninja_path": ninja.get("path"),
        "ninja_version": ninja.get("version"),
        "kernel_release": kernel.get("release"),
        "kernel_cmdline": kernel.get("cmdline"),
        "nixos_system": nixos.get("current_system"),
        "ci_flake": nix.get("ci_flake"),
        "cpu_affinity": benchmark_during.get("cpu_affinity")
        or benchmark_before.get("cpu_affinity"),
        "cpuset_shield": benchmark_during.get("cpuset_shield")
        or benchmark_before.get("cpuset_shield"),
        "boost_before": benchmark_before.get("boost"),
        "boost_during": benchmark_during.get("boost"),
        "boost_after": benchmark_after.get("boost"),
    }


def insert_environment(conn, run_id, before, during, after):
    if before is None and during is None and after is None:
        return

    before = before or {}
    during = during or {}
    after = after or {}
    summary = environment_summary(before, during, after)
    conn.execute(
        """
        INSERT INTO run_environment (
            run_id, before_json, during_json, after_json, compiler_path, compiler_version,
            cmake_path, cmake_version, ninja_path, ninja_version,
            kernel_release, kernel_cmdline, nixos_system, ci_flake,
            cpu_affinity, cpuset_shield, boost_before, boost_during, boost_after
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(run_id) DO UPDATE SET
            before_json = excluded.before_json,
            during_json = excluded.during_json,
            after_json = excluded.after_json,
            compiler_path = excluded.compiler_path,
            compiler_version = excluded.compiler_version,
            cmake_path = excluded.cmake_path,
            cmake_version = excluded.cmake_version,
            ninja_path = excluded.ninja_path,
            ninja_version = excluded.ninja_version,
            kernel_release = excluded.kernel_release,
            kernel_cmdline = excluded.kernel_cmdline,
            nixos_system = excluded.nixos_system,
            ci_flake = excluded.ci_flake,
            cpu_affinity = excluded.cpu_affinity,
            cpuset_shield = excluded.cpuset_shield,
            boost_before = excluded.boost_before,
            boost_during = excluded.boost_during,
            boost_after = excluded.boost_after
        """,
        (
            run_id,
            json.dumps(before, sort_keys=True),
            json.dumps(during, sort_keys=True),
            json.dumps(after, sort_keys=True),
            summary["compiler_path"],
            summary["compiler_version"],
            summary["cmake_path"],
            summary["cmake_version"],
            summary["ninja_path"],
            summary["ninja_version"],
            summary["kernel_release"],
            summary["kernel_cmdline"],
            summary["nixos_system"],
            summary["ci_flake"],
            summary["cpu_affinity"],
            summary["cpuset_shield"],
            summary["boost_before"],
            summary["boost_during"],
            summary["boost_after"],
        ),
    )


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
        insert_environment(
            conn,
            run_id,
            load_json(args.environment_before),
            load_json(args.environment_during),
            load_json(args.environment_after),
        )
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

    toolchain_parser = subparsers.add_parser("write-toolchain")
    toolchain_parser.add_argument("--output", type=pathlib.Path, required=True)
    toolchain_parser.set_defaults(func=write_toolchain)

    environment_parser = subparsers.add_parser("write-environment")
    environment_parser.add_argument("--output", type=pathlib.Path, required=True)
    environment_parser.add_argument("--phase", required=True)
    environment_parser.add_argument("--captured-at", required=True)
    environment_parser.add_argument("--toolchain", type=pathlib.Path)
    environment_parser.add_argument("--cpu-affinity", default="")
    environment_parser.add_argument("--cpuset-shield", default="")
    environment_parser.add_argument("--cpuset-housekeeping", default="")
    environment_parser.set_defaults(func=write_environment)

    record_parser = subparsers.add_parser("record")
    record_parser.add_argument("--db", type=pathlib.Path, required=True)
    record_parser.add_argument("--metadata", type=pathlib.Path, required=True)
    record_parser.add_argument("--bench-json", type=pathlib.Path, required=True)
    record_parser.add_argument("--environment-before", type=pathlib.Path)
    record_parser.add_argument("--environment-during", type=pathlib.Path)
    record_parser.add_argument("--environment-after", type=pathlib.Path)
    record_parser.set_defaults(func=record)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
