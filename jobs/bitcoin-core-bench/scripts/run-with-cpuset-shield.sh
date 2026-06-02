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
freq_state_dir=$(mktemp -d /tmp/ci-bitcoin-bench-freq.XXXXXX)

expand_cpu_list() {
    local cpu_list=$1
    local part start end cpu
    IFS=',' read -ra parts <<< "${cpu_list}"
    for part in "${parts[@]}"; do
        if [[ "${part}" =~ ^[0-9]+-[0-9]+$ ]]; then
            start=${part%-*}
            end=${part#*-}
            for ((cpu = start; cpu <= end; cpu++)); do
                echo "${cpu}"
            done
        elif [[ "${part}" =~ ^[0-9]+$ ]]; then
            echo "${part}"
        fi
    done
}

set_slice_cpus() {
    local cpus=$1
    systemctl set-property --runtime -- system.slice "AllowedCPUs=${cpus}"
    systemctl set-property --runtime -- user.slice "AllowedCPUs=${cpus}"
    systemctl set-property --runtime -- init.scope "AllowedCPUs=${cpus}"
}

pin_cpu_min_freqs() {
    local cpu base min_file max_file max_freq
    for cpu in $(expand_cpu_list "${shield_cpus}"); do
        base="/sys/devices/system/cpu/cpu${cpu}/cpufreq"
        min_file="${base}/scaling_min_freq"
        max_file="${base}/scaling_max_freq"
        if [ ! -w "${min_file}" ] || [ ! -r "${max_file}" ]; then
            continue
        fi
        cat "${min_file}" > "${freq_state_dir}/cpu${cpu}.scaling_min_freq"
        max_freq=$(cat "${max_file}")
        echo "${max_freq}" > "${min_file}"
    done
}

restore_cpu_min_freqs() {
    local state cpu min_file
    for state in "${freq_state_dir}"/cpu*.scaling_min_freq; do
        [ -e "${state}" ] || continue
        cpu=${state##*/cpu}
        cpu=${cpu%.scaling_min_freq}
        min_file="/sys/devices/system/cpu/cpu${cpu}/cpufreq/scaling_min_freq"
        [ -w "${min_file}" ] || continue
        cat "${state}" > "${min_file}"
    done
    rm -rf "${freq_state_dir}"
}

restore_system() {
    set +e
    restore_cpu_min_freqs
    set_slice_cpus 0-23
    systemctl set-property --runtime -- ci-bitcoin-bench.slice AllowedCPUs=0-23
}
trap restore_system EXIT

pin_cpu_min_freqs
systemctl set-property --runtime -- ci-bitcoin-bench.slice "AllowedCPUs=${shield_cpus}"
set_slice_cpus "${housekeeping_cpus}"

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
