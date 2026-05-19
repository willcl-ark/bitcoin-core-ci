# AGENTS.md

This is a living document. Keep it concise, practical, and current. After each
change, consider whether these instructions need a small update.

## Project Goal

This repo defines a NixOS-based home CI lab for running queued, self-contained
CMake/CTest jobs, starting with Bitcoin Core dashboard builds.

## Working Rules

- Think before coding and state assumptions when they affect the design.
- Keep changes minimal and surgical.
- Prefer one clear NixOS configuration file until repeated structure justifies
  modules.
- Keep generated machine hardware configuration in a separate
  `machines/<name>/hardware-configuration.nix` file.
- Keep machine setup small; put build tools and project dependencies in job
  flakes.
- Prefer the generic Python queue runner plus simple systemd units for job
  scheduling.
- Preserve a simple manual workflow using `systemctl` and `journalctl`.
- Sync the machine flake to `/etc/nixos` for remote rebuilds.
- Keep CI-owned mutable state under `/var/lib/ci-runner`.
- Keep queue state under `/var/lib/ci-runner/queue`.
- Keep the shared CI ccache under `/var/cache/ci-runner/ccache`.
- Let timing/instrumentation jobs opt out of ccache when cached timings would
  hide useful build-cost data.
- Do not lock `jobs/bitcoin-core-nightly`; it should follow nightly nixpkgs.
- Treat VMs as a future job implementation detail, not a first requirement.
- Do not commit secrets, tokens, private machine data, or CDash credentials.
- Review diffs before presenting work.
- Use small atomic commits with concise titles and rationale-focused bodies.

## Repository Shape

- `PLAN.md` records the current architecture and open decisions.
- `flake.nix` should contain the initial NixOS configuration.
- `machines/` should contain generated per-machine hardware configuration.
- `jobs/` should contain job-owned flakes, CTest scripts, presets, and helpers.
- `runner/` should contain generic queue orchestration only; keep
  project-specific job behavior in job scripts and systemd unit wiring.

## When To Update This File

Update this file when the project gains a durable convention, such as a new job
layout, service naming rule, secret handling approach, or verification command.
