set shell := ["bash", "-uc"]

default_host := 'beelink'

[private]
default:
    just --list

# Build configuration without deploying
[group('test')]
build type=default_host:
    nixos-rebuild build --flake .#{{type}} --show-trace

# Build VM for testing
[group('test')]
build-vm type=default_host:
    nixos-rebuild build-vm --flake .#{{type}} --show-trace

# Show what would change without building
[group('test')]
dry-run type=default_host:
    nixos-rebuild dry-run --flake .#{{type}} --show-trace

# Copy flake to remote for remote building
[group('live')]
sync host=default_host:
    rsync -av --delete --exclude=.git --exclude=result* . {{host}}:/etc/nixos/

# Rebuild configuration on remote machine
[group('live')]
rebuild type=default_host host=default_host:
    ssh {{host}} "nixos-rebuild switch --flake /etc/nixos#{{type}}"

# Sync and rebuild on remote machine
[group('live')]
sync-rebuild type=default_host host=default_host:
    just sync {{host}}
    just rebuild {{type}} {{host}}

# Follow CI service logs
[group('live')]
logs host=default_host:
    ssh {{host}} "journalctl -f -o short-iso \
        -u ci-runner.service \
        -u ci-nightly-bitcoin-enqueue.service \
        -u ci-watch-bitcoin-guix.service \
        -u ci-watch-bitcoin-valgrind-fuzz.service"

# Enqueue the full Bitcoin Core nightly job
[group('live')]
nightly-start host=default_host:
    ssh {{host}} "systemctl start ci-nightly-bitcoin-enqueue.service"

# Show status for CI services
[group('live')]
status host=default_host:
    ssh {{host}} "systemctl --no-pager --full status \
        ci-runner.service \
        ci-nightly-bitcoin-enqueue.service \
        ci-watch-bitcoin-guix.service \
        ci-watch-bitcoin-valgrind-fuzz.service"

# Backward-compatible alias for the old nightly status helper
[group('live')]
nightly-status host=default_host:
    just status {{host}}

# Show queued CI jobs
[group('live')]
queue-status host=default_host:
    ssh {{host}} "sudo -u ci-runner ci-runner status"
