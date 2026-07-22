#!/usr/bin/env python3
import argparse
import datetime
import fcntl
import json
import os
import pathlib
import signal
import subprocess
import sys
import time
import uuid


DEFAULT_QUEUE_DIR = pathlib.Path(os.environ.get("CI_QUEUE_DIR", "/var/lib/ci-runner/queue"))


def now():
    return datetime.datetime.now(datetime.UTC).replace(microsecond=0).isoformat()


def paths(queue_dir):
    return {
        "pending": queue_dir / "pending",
        "running": queue_dir / "running",
        "done": queue_dir / "done",
        "failed": queue_dir / "failed",
        "watch": queue_dir / "watch",
        "lock": queue_dir / "queue.lock",
    }


def ensure_queue(queue_dir):
    queue_paths = paths(queue_dir)
    for name, path in queue_paths.items():
        if name != "lock":
            path.mkdir(parents=True, exist_ok=True)
    return queue_paths


class QueueLock:
    def __init__(self, path):
        self.path = path
        self.file = None

    def __enter__(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.file = self.path.open("w")
        fcntl.flock(self.file, fcntl.LOCK_EX)

    def __exit__(self, exc_type, exc, tb):
        fcntl.flock(self.file, fcntl.LOCK_UN)
        self.file.close()


def load_json(path):
    with path.open() as f:
        return json.load(f)


def write_json(path, value):
    tmp = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
    with tmp.open("w") as f:
        json.dump(value, f, indent=2, sort_keys=True)
        f.write("\n")
    os.replace(tmp, path)


def item_file(directory, item):
    return directory / f"{item['id']}.json"


def pending_items(queue_paths):
    items = []
    for path in queue_paths["pending"].glob("*.json"):
        items.append((path, load_json(path)))
    return sorted(items, key=lambda entry: (entry[1]["created_at"], entry[1]["id"]))


def enqueue(args):
    queue_paths = ensure_queue(args.queue_dir)
    item = {
        "id": args.id or f"{args.job}-{datetime.datetime.now(datetime.UTC).strftime('%Y%m%dT%H%M%SZ')}-{uuid.uuid4().hex[:8]}",
        "job": args.job,
        "kind": args.kind,
        "dedupe_key": args.dedupe_key or "",
        "revision": args.revision or "",
        "created_at": now(),
    }

    with QueueLock(queue_paths["lock"]):
        if args.replace_pending and item["dedupe_key"]:
            for path, existing in pending_items(queue_paths):
                if existing.get("dedupe_key") == item["dedupe_key"]:
                    path.unlink()
        write_json(item_file(queue_paths["pending"], item), item)

    print(item["id"])


def load_config(path):
    config = load_json(path)
    return config["jobs"]


def run_item(config, item):
    job = config[item["job"]]
    env = os.environ.copy()
    env.update({key: str(value) for key, value in job.get("env", {}).items()})
    env.update(
        {
            "CI_JOB_ID": item["id"],
            "CI_JOB_KIND": item["kind"],
            "CI_REVISION": item.get("revision", ""),
        }
    )

    print(f"starting {item['id']}: {' '.join(job['command'])}", flush=True)
    result = subprocess.run(job["command"], cwd=job.get("cwd"), env=env)
    print(f"finished {item['id']} with exit code {result.returncode}", flush=True)
    return result.returncode


def run(args):
    stop_requested = False

    def request_stop(_signum, _frame):
        nonlocal stop_requested
        stop_requested = True
        print("reload requested; stopping after the current job", flush=True)

    signal.signal(signal.SIGHUP, request_stop)
    queue_paths = ensure_queue(args.queue_dir)
    config = load_config(args.config)
    fail_running_items(queue_paths)

    while not stop_requested:
        with QueueLock(queue_paths["lock"]):
            if stop_requested:
                break
            items = pending_items(queue_paths)
            if not items:
                item = None
            else:
                pending_path, item = items[0]
                running_path = item_file(queue_paths["running"], item)
                os.replace(pending_path, running_path)

        if item is None:
            time.sleep(args.poll_interval)
            continue

        started = time.monotonic()
        exit_code = run_item(config, item)
        item["finished_at"] = now()
        item["elapsed_seconds"] = round(time.monotonic() - started, 3)
        item["exit_code"] = exit_code
        item["result"] = "done" if exit_code == 0 else "failed"

        with QueueLock(queue_paths["lock"]):
            target = queue_paths[item["result"]]
            write_json(item_file(target, item), item)
            item_file(queue_paths["running"], item).unlink(missing_ok=True)


def fail_running_items(queue_paths):
    with QueueLock(queue_paths["lock"]):
        for path in queue_paths["running"].glob("*.json"):
            item = load_json(path)
            item["finished_at"] = now()
            item["result"] = "failed"
            item["error"] = "runner restarted while job was running"
            write_json(item_file(queue_paths["failed"], item), item)
            path.unlink()


def remote_revision(remote, ref):
    output = subprocess.check_output(["git", "ls-remote", remote, ref], text=True).strip()
    return output.split()[0]


def watch_git_ref(args):
    queue_paths = ensure_queue(args.queue_dir)
    state_file = queue_paths["watch"] / f"{args.job}.json"
    try:
        state = load_json(state_file)
        last_seen = state["last_seen"]
    except FileNotFoundError:
        last_seen = remote_revision(args.remote, args.ref)
        write_json(state_file, {"last_seen": last_seen})

    while True:
        revision = remote_revision(args.remote, args.ref)
        if revision != last_seen:
            enqueue_args = argparse.Namespace(
                queue_dir=args.queue_dir,
                job=args.job,
                kind=args.kind,
                dedupe_key=args.dedupe_key or f"{args.kind}:{args.job}",
                revision=revision,
                replace_pending=True,
                id=None,
            )
            enqueue(enqueue_args)
            last_seen = revision
            write_json(state_file, {"last_seen": last_seen, "updated_at": now()})
        else:
            print(f"{args.job}: no new revision at {revision[:12]}", flush=True)
        time.sleep(args.poll_interval)


def status(args):
    queue_paths = ensure_queue(args.queue_dir)
    for name in ["pending", "running", "done", "failed"]:
        files = sorted(queue_paths[name].glob("*.json"))
        print(f"{name}: {len(files)}")
        for path in files[-args.limit :]:
            item = load_json(path)
            revision = item.get("revision", "")
            suffix = f" {revision[:12]}" if revision else ""
            print(f"  {item['id']} {item['job']}{suffix}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--queue-dir", type=pathlib.Path, default=DEFAULT_QUEUE_DIR)
    subparsers = parser.add_subparsers(required=True)

    enqueue_parser = subparsers.add_parser("enqueue")
    enqueue_parser.add_argument("job")
    enqueue_parser.add_argument("--kind", required=True)
    enqueue_parser.add_argument("--dedupe-key")
    enqueue_parser.add_argument("--revision")
    enqueue_parser.add_argument("--replace-pending", action="store_true")
    enqueue_parser.add_argument("--id")
    enqueue_parser.set_defaults(func=enqueue)

    run_parser = subparsers.add_parser("run")
    run_parser.add_argument("--config", type=pathlib.Path, required=True)
    run_parser.add_argument("--poll-interval", type=int, default=10)
    run_parser.set_defaults(func=run)

    watch_parser = subparsers.add_parser("watch-git-ref")
    watch_parser.add_argument("job")
    watch_parser.add_argument("--remote", required=True)
    watch_parser.add_argument("--ref", default="refs/heads/master")
    watch_parser.add_argument("--kind", default="continuous")
    watch_parser.add_argument("--dedupe-key")
    watch_parser.add_argument("--poll-interval", type=int, default=60)
    watch_parser.set_defaults(func=watch_git_ref)

    status_parser = subparsers.add_parser("status")
    status_parser.add_argument("--limit", type=int, default=20)
    status_parser.set_defaults(func=status)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
