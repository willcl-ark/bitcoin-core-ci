#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "run-with-cpuset-shield.sh must run as root" >&2
    exit 1
fi

if [ "$#" -lt 2 ]; then
    echo "usage: run-with-cpuset-shield.sh <shield-cpus> <housekeeping-cpus> -- <command> [args...]" >&2
    exit 1
fi

shield_cpus=$1
housekeeping_cpus=$2
shift 2
if [ "${1:-}" = "--" ]; then
    shift
fi

set_slice_cpus() {
    local cpus=$1
    systemctl set-property --runtime -- system.slice "AllowedCPUs=${cpus}"
    systemctl set-property --runtime -- user.slice "AllowedCPUs=${cpus}"
    systemctl set-property --runtime -- init.scope "AllowedCPUs=${cpus}"
}

restore_cpus() {
    set +e
    set_slice_cpus 0-23
}
trap restore_cpus EXIT

set_slice_cpus "${housekeeping_cpus}"

systemd-run \
    --wait \
    --collect \
    --quiet \
    --pipe \
    --same-dir \
    --property "AllowedCPUs=${shield_cpus}" \
    --property "User=ci-runner" \
    --property "Group=ci-runner" \
    -- "$@"
