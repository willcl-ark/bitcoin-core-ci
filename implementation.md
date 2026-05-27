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
- NetworkManager inserts `1.1.1.1` and `8.8.8.8` before DHCP-provided DNS
  servers so CI jobs do not depend on the router's resolver.
- Job flakes stay in their job directories, but CI enters them through dev
  shells exposed by the root flake. The root `flake.lock` owns the nixpkgs pins;
  runtime scripts use `CI_FLAKE` instead of resolving job-local flakes.
- Job-specific NixOS wiring lives in `jobs/*/module.nix`. The root flake owns
  the shared runner substrate and exposes `ci.runner.jobs`, while job modules
  register queue commands, timers, watchers, state directories, and auxiliary
  services.

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
- The Guix wrapper fetches and checks out the revision before invoking CTest, so
  its dashboard script uses `CTEST_UPDATE_VERSION_ONLY` to report the current
  revision without letting `ctest_update()` run a second network fetch.

## Bitcoin Core benchmark job

- `bitcoin-bench` is a separate continuous queue item so benchmark runtime and
  failures do not affect the existing unit/functional nightly variants.
- The benchmark job submits update/configure/build status to CDash, but stores
  benchmark measurements locally. CDash notes include the metadata file so the
  dashboard points back to the local artifact directory and command.
- Raw artifacts live under
  `/var/lib/ci-runner/benchmarks/bitcoin-core/artifacts/<time>-<commit>/`.
  The SQLite index lives at
  `/var/lib/ci-runner/benchmarks/bitcoin-core/benchmarks.sqlite`.
- The SQLite database is an index over the raw `bench.json` artifact, not the
  only source of truth. Each result row stores the raw benchmark JSON object so
  parser changes can be audited later.
- The benchmark dashboard is generated as static files under the benchmark
  state directory and served only on `127.0.0.1:8080`. Cloudflare Tunnel uses a
  remotely managed tunnel token from SOPS, decrypted on Beelink by its host SSH
  key.
- `bench_bitcoin` runs under a root wrapper that applies `pyperf system tune`,
  moves normal system/user/init cgroups to housekeeping CPUs `0,1,4-13,16-23`,
  runs the benchmark in a transient unit limited to CPUs `2,3,14,15`, and pins
  the benchmark process itself to CPUs `2,3`. The wrapper resets pyperf and
  restores cgroup CPU access to `0-23` on exit.
- Benchmark state initialization is shared by the dashboard and tuned benchmark
  runner. It creates the base, artifact, and site directories as `ci-runner` so
  root-owned parent directories do not block artifact writes.
- The benchmark CTest script submits only update/configure/build completion to
  CDash. `run-bench.sh` runs `bench_bitcoin` afterward so local benchmark,
  parser, database, or dashboard failures fail the queue job without reporting a
  failed CDash test for Bitcoin Core.
- The benchmark queue command writes `CI_JOB_ID`, `CI_JOB_KIND`, and
  `CI_REVISION` to a CI-owned environment file, then starts the root systemd
  unit. The unit owns benchmark configuration and host-tool `PATH`, while the
  queue item only contributes revision identity.
- The static benchmark dashboard computes overview tables client-side from
  `results.json`. It shows latest values immediately, but rolling trend
  heatmaps stay in an explicit "need 7 runs" placeholder state until there is
  enough nightly history to make the scan view useful.
- The benchmark dashboard keeps Largest Changes and Run Heatmap stacked at full
  page width. The table and heatmap hide useful scan data when constrained to
  half-width columns.
- The bottom benchmark chart defaults to an `All` selection that renders one
  Plotly series per benchmark. Selecting a table row switches back to the
  individual benchmark view.
- The benchmark dashboard HTML, CSS, and JavaScript live under
  `jobs/bitcoin-core-bench/site/`. `generate-site.py` owns SQLite-to-JSON
  export and copies those static assets into the served site directory.
