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
