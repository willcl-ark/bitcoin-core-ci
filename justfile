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

# Follow all Bitcoin Core nightly service logs
[group('live')]
logs host=default_host:
    ssh {{host}} "journalctl -f -o short-iso \
        -u ci-nightly-bitcoin-clone.service \
        -u ci-nightly-bitcoin-update.service \
        -u ci-nightly-bitcoin-gcc.service \
        -u ci-nightly-bitcoin-gcc-stdlib-debug.service \
        -u ci-nightly-bitcoin-libcxx-hardened.service \
        -u ci-nightly-bitcoin-gcc-instrumented.service \
        -u ci-bitcoin-guix.service \
        -u ci-bitcoin-valgrind-fuzz.service"

# Start the full Bitcoin Core nightly chain
[group('live')]
nightly-start host=default_host:
    ssh {{host}} "sudo systemctl start ci-nightly-bitcoin-clone.service"

# Show status for all Bitcoin Core nightly services
[group('live')]
nightly-status host=default_host:
    ssh {{host}} "systemctl --no-pager --full status \
        ci-nightly-bitcoin-clone.service \
        ci-nightly-bitcoin-update.service \
        ci-nightly-bitcoin-gcc.service \
        ci-nightly-bitcoin-gcc-stdlib-debug.service \
        ci-nightly-bitcoin-libcxx-hardened.service \
        ci-nightly-bitcoin-gcc-instrumented.service"
