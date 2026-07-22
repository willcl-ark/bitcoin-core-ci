#!/usr/bin/env python3
import json
import os
import pathlib
import signal
import subprocess
import sys
import tempfile
import time
import unittest


RUNNER = pathlib.Path(__file__).with_name("ci_runner.py")


class RunnerReloadTest(unittest.TestCase):
    def test_reload_finishes_current_job_without_starting_next(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            queue = root / "queue"
            pending = queue / "pending"
            pending.mkdir(parents=True)
            started = root / "started"
            release = root / "release"
            second_started = root / "second-started"
            config = root / "config.json"
            config.write_text(
                json.dumps(
                    {
                        "jobs": {
                            "blocking": {
                                "command": [
                                    sys.executable,
                                    "-c",
                                    (
                                        "import pathlib, time\n"
                                        f"started = pathlib.Path({str(started)!r})\n"
                                        f"release = pathlib.Path({str(release)!r})\n"
                                        "started.touch()\n"
                                        "while not release.exists():\n"
                                        "    time.sleep(0.05)\n"
                                    ),
                                ]
                            },
                            "second": {
                                "command": [
                                    sys.executable,
                                    "-c",
                                    f"import pathlib; pathlib.Path({str(second_started)!r}).touch()",
                                ]
                            },
                        }
                    }
                )
            )
            items = [
                {
                    "id": "first",
                    "job": "blocking",
                    "kind": "test",
                    "dedupe_key": "",
                    "revision": "",
                    "created_at": "2026-01-01T00:00:00+00:00",
                },
                {
                    "id": "second",
                    "job": "second",
                    "kind": "test",
                    "dedupe_key": "",
                    "revision": "",
                    "created_at": "2026-01-01T00:00:01+00:00",
                },
            ]
            for item in items:
                (pending / f"{item['id']}.json").write_text(json.dumps(item))

            process = subprocess.Popen(
                [
                    sys.executable,
                    RUNNER,
                    "--queue-dir",
                    queue,
                    "run",
                    "--config",
                    config,
                    "--poll-interval",
                    "1",
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
            )
            try:
                deadline = time.monotonic() + 5
                while not started.exists() and time.monotonic() < deadline:
                    time.sleep(0.05)
                self.assertTrue(started.exists(), "first job did not start")

                os.kill(process.pid, signal.SIGHUP)
                release.touch()
                output, _ = process.communicate(timeout=5)
            finally:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=5)

            self.assertEqual(process.returncode, 0, output)
            self.assertIn("reload requested; stopping after the current job", output)
            self.assertTrue((queue / "done" / "first.json").exists())
            self.assertTrue((pending / "second.json").exists())
            self.assertFalse(second_started.exists())


if __name__ == "__main__":
    unittest.main()
