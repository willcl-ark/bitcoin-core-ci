# Home CI Lab Plan

## Assumptions

- This repo owns the NixOS machine configuration for the Beelink SER10 Max.
- CI job definitions can live here while the setup is small and local.
- Initial jobs are nightly CMake/CTest dashboard runs for Bitcoin Core.
- Jobs should be self-contained: each job should provide a flake, CTest script,
  presets, and any small helper scripts it needs.
- The first implementation should favor debuggability over isolation.

## Initial Direction

Start with a single NixOS configuration file that defines:

- the base machine setup;
- a dedicated CI user;
- shared build/cache directories;
- one systemd service per nightly job;
- one systemd timer that starts the first job in the sequence.

Run jobs on the host at first, not in VMs. Host execution is easier to inspect,
shares `ccache` naturally, keeps CTest/CDash behavior close to local developer
runs, and avoids deciding VM boundaries before there is operational experience.

Use systemd chaining for sequential execution:

- timer starts `ci-nightly-a.service` at 00:00;
- `ci-nightly-a.service` uses `OnSuccess=` and `OnFailure=` to start
  `ci-nightly-b.service`;
- each job starts the next job regardless of success or failure;
- job failure state remains visible in `systemctl status` and the journal.

This gives a simple "run all jobs in order" model without introducing a queue
daemon, scheduler, or CI server.

## Repository Layout

Keep one giant Nix file initially. Split modules only when the file has clear
repeated shapes or unrelated concerns.

Proposed first layout:

```text
.
├── AGENTS.md
├── PLAN.md
├── flake.nix
├── flake.lock
└── jobs/
    └── bitcoin-core-nightly/
        ├── flake.nix
        ├── CMakeUserPresets.json
        └── scripts/
            └── build-unit-test.cmake
```

The machine configuration should know how to schedule and run jobs. The job
directory should know how to build and test its project.

## Job Model

Each job should have:

- a stable job name;
- a working directory under a CI-owned state path;
- a source checkout path or fetch/update step;
- a flake dev shell or package environment;
- a `ctest -S ...` command;
- logs in the systemd journal;
- any external submission credentials passed through systemd credentials or
  root-owned environment files, not committed to the repo.

The service command should be close to:

```sh
nix develop /etc/ci/jobs/bitcoin-core-nightly#gcc \
  --command ctest -S scripts/build-unit-test.cmake -V
```

Exact paths can change once the NixOS config is written.

## Manual Operation

Manual testing should use normal systemd commands:

```sh
sudo systemctl start ci-nightly-bitcoin-gcc.service
sudo systemctl status ci-nightly-bitcoin-gcc.service
journalctl -u ci-nightly-bitcoin-gcc.service -f
```

To test the full sequence, start the first service manually:

```sh
sudo systemctl start ci-nightly-first.service
```

To inspect timers:

```sh
systemctl list-timers 'ci-*'
```

## Open Questions

### Should CTest Scripts Live Here?

For now, yes. The CI lab should be reproducible from this repo, and the current
nightly scripts are CI-specific rather than upstream project code.

Revisit this if scripts become generally useful to developers or if multiple
machines need to share them independently of machine configuration.

### How Should Jobs Run?

Start with sequential systemd oneshot services. Avoid VMs until there is a
specific need such as kernel variation, distribution variation, destructive
tests, privilege isolation, or reproducing a platform that cannot be expressed
cleanly in a Nix shell.

### How Are Nightlies Tested Manually?

Expose each job as a normal service and document the `systemctl start`,
`systemctl status`, and `journalctl -u` workflow. This is also the operational
debugging interface.

### How Minimal Should System Setup Be?

The host should provide only durable infrastructure:

- Nix;
- systemd scheduling;
- CI user and permissions;
- storage paths;
- cache directories;
- optional monitoring/remote access.

Compilers, CMake, Ninja, and project dependencies should come from each job's
flake.

### What About Future VM Jobs?

Keep the service boundary stable so a future job can replace `nix develop` with
`nixos-rebuild build-vm`, `nix run`, `systemd-nspawn`, or a QEMU wrapper without
changing the scheduler model.

## Success Criteria For The First Implementation

- A fresh NixOS install can use this repo as its system configuration.
- At least one nightly job can be run manually through systemd.
- A timer can start the nightly chain automatically.
- Jobs share a persistent `ccache`.
- Job dependencies come from the job flake, not ad hoc host packages.
- Failures are visible through systemd state and the journal.

