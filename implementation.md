# Implementation Notes

## CI queue runner

- Scheduling is handled by `runner/ci_runner.py`, a generic Python filesystem
  queue runner. It knows about JSON queue items and configured systemd unit
  names, but not about Nix, Bitcoin Core, CTest, or job-specific commands.
- Jobs are serialized by the runner itself. It starts exactly one configured
  `systemctl --user start --wait <unit>` command at a time.
- Continuous jobs use `watch-git-ref` and `--replace-pending`, so Guix and
  valgrind fuzz keep only the latest pending revision.
- Job behavior lives in job-local shell scripts and CTest files. Nix wires
  paths, environment, user units, timers, and host-specific configuration.
- The CI services run in the `ci-runner` user manager with lingering enabled,
  so the runner can start other `ci-runner` user services without root-owned job
  processes.
