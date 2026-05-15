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
