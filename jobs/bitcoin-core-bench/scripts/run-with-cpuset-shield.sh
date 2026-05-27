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

governor_files=()
governor_values=()
min_freq_files=()
min_freq_values=()

set_slice_cpus() {
    local cpus=$1
    systemctl set-property --runtime -- system.slice "AllowedCPUs=${cpus}"
    systemctl set-property --runtime -- user.slice "AllowedCPUs=${cpus}"
    systemctl set-property --runtime -- init.scope "AllowedCPUs=${cpus}"
}

save_cpufreq_state() {
    local policy governor_file min_freq_file
    for policy in /sys/devices/system/cpu/cpufreq/policy*; do
        [ -d "${policy}" ] || continue

        governor_file="${policy}/scaling_governor"
        if [ -w "${governor_file}" ]; then
            governor_files+=("${governor_file}")
            governor_values+=("$(<"${governor_file}")")
        fi

        min_freq_file="${policy}/scaling_min_freq"
        if [ -w "${min_freq_file}" ] && [ -r "${policy}/scaling_max_freq" ]; then
            min_freq_files+=("${min_freq_file}")
            min_freq_values+=("$(<"${min_freq_file}")")
        fi
    done
}

tune_cpufreq() {
    local file policy max_freq
    for file in "${governor_files[@]}"; do
        if ! echo performance >"${file}"; then
            echo "failed to set ${file} to performance" >&2
        fi
    done

    for file in "${min_freq_files[@]}"; do
        policy=${file%/*}
        max_freq=$(<"${policy}/scaling_max_freq")
        if ! echo "${max_freq}" >"${file}"; then
            echo "failed to set ${file} to ${max_freq}" >&2
        fi
    done
}

restore_cpufreq() {
    local index
    for index in "${!min_freq_files[@]}"; do
        echo "${min_freq_values[$index]}" >"${min_freq_files[$index]}" 2>/dev/null
    done
    for index in "${!governor_files[@]}"; do
        echo "${governor_values[$index]}" >"${governor_files[$index]}" 2>/dev/null
    done
}

restore_system() {
    set +e
    restore_cpufreq
    set_slice_cpus 0-23
    systemctl set-property --runtime -- ci-bitcoin-bench.slice AllowedCPUs=0-23
}
trap restore_system EXIT

save_cpufreq_state
systemctl set-property --runtime -- ci-bitcoin-bench.slice "AllowedCPUs=${shield_cpus}"
set_slice_cpus "${housekeeping_cpus}"
tune_cpufreq

systemd-run \
    --wait \
    --collect \
    --quiet \
    --pipe \
    --slice=ci-bitcoin-bench.slice \
    --property "WorkingDirectory=/var/lib/ci-runner" \
    --property "User=ci-runner" \
    --property "Group=ci-runner" \
    -- "$@"
