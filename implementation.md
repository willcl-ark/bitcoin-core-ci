# Implementation Notes

## CI queue runner

- Scheduling is handled by `runner/ci_runner.py`, a generic Python filesystem
  queue runner. It knows about JSON queue items and configured commands, but
  not about Nix, Bitcoin Core, or CTest.
- Jobs are serialized by the runner itself. It starts exactly one configured
  command at a time as the `ci-runner` user.
- Continuous jobs use `watch-git-ref` and `--replace-pending`, so Guix and
  valgrind fuzz keep only the latest pending revision.
- Job behavior lives in job-local shell scripts and CTest files. Nix wires
  paths, environment, systemd services, timers, and host-specific
  configuration.
- Continuous watchers use `git ls-remote`, so they do not mutate the checkouts
  used by running jobs.

## Bitcoin Core Guix job

- The Guix dashboard build writes the full `contrib/guix/guix-build` stream to
  `guix-build.log` in the checkout and submits it to CDash as a note. CTest's
  normal build parser only reports parsed warnings/errors, which can hide the
  command output for early Guix failures.
- `run-guix.sh` prints the last 200 log lines when the CTest script fails so
  `journalctl -u ci-runner.service` has immediate failure context.
- Guix builds inherit their executable search path from `ci-runner.service`.
  Keep required host-side tools such as `make`, `getent`, and `sed` in that
  service path rather than in the job script.
- The Guix job installs a job-local `CTestCustom.cmake` into the checkout before
  `ctest_build()` so CDash ignores known Autoconf probe errors emitted inside
  the Guix container.
