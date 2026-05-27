#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

if [ "$(id -u)" -ne 0 ]; then
    echo "run-bench-with-pyperf.sh must run as root" >&2
    exit 1
fi

mkdir -p "${BENCHMARK_ARTIFACT_ROOT}/system"
run_id="${CI_JOB_ID:-bitcoin-bench-$(date -u +"%Y%m%dT%H%M%SZ")}"
pyperf_prefix="${BENCHMARK_ARTIFACT_ROOT}/system/${run_id}"
wrapper_log="${pyperf_prefix}-wrapper.log"

exec > >(tee -a "${wrapper_log}") 2>&1
PS4='+ ${BASH_SOURCE##*/}:${LINENO}: '
set -x

on_error() {
    local status=$?
    echo "run-bench-with-pyperf failed at line ${BASH_LINENO[0]}: ${BASH_COMMAND} (status ${status})" >&2
    exit "${status}"
}
trap on_error ERR

reset_pyperf() {
    set +e
    echo "resetting pyperf state"
    "${PYPERF_PYTHON:-python3}" -m pyperf system reset >"${pyperf_prefix}-reset.log" 2>&1
    echo "$?" >"${pyperf_prefix}-reset.status"
    "${PYPERF_PYTHON:-python3}" -m pyperf system show >"${pyperf_prefix}-after.log" 2>&1
    echo "$?" >"${pyperf_prefix}-after.status"
}
trap reset_pyperf EXIT

echo "writing benchmark system logs to ${pyperf_prefix}-*.log"
if "${PYPERF_PYTHON:-python3}" -m pyperf system show >"${pyperf_prefix}-before.log" 2>&1; then
    echo 0 >"${pyperf_prefix}-before.status"
else
    show_status=$?
    echo "${show_status}" >"${pyperf_prefix}-before.status"
    echo "pyperf system show exited with ${show_status}; see ${pyperf_prefix}-before.log" >&2
fi
if "${PYPERF_PYTHON:-python3}" -m pyperf system tune --affinity="${BENCHMARK_CPU_AFFINITY}" >"${pyperf_prefix}-tune.log" 2>&1; then
    echo 0 >"${pyperf_prefix}-tune.status"
else
    tune_status=$?
    echo "${tune_status}" >"${pyperf_prefix}-tune.status"
    echo "pyperf system tune exited with ${tune_status}; see ${pyperf_prefix}-tune.log" >&2
fi

"${BENCHMARK_RUNUSER:-runuser}" -u ci-runner -- \
    "${BENCHMARK_ENV:-env}" \
        BENCHMARK_CPU_AFFINITY="${BENCHMARK_CPU_AFFINITY}" \
        BENCHMARK_CPUSET_HOUSEKEEPING="${BENCHMARK_CPUSET_HOUSEKEEPING}" \
        BENCHMARK_CPUSET_SHIELD="${BENCHMARK_CPUSET_SHIELD}" \
        BENCHMARK_ARTIFACT_ROOT="${BENCHMARK_ARTIFACT_ROOT}" \
        BENCHMARK_DB="${BENCHMARK_DB}" \
        BENCHMARK_MIN_TIME_MS="${BENCHMARK_MIN_TIME_MS}" \
        BENCHMARK_SITE_DIR="${BENCHMARK_SITE_DIR}" \
        BITCOIN_REPO="${BITCOIN_REPO}" \
        BITCOIN_REPO_URL="${BITCOIN_REPO_URL}" \
        CCACHE_DIR="${CCACHE_DIR}" \
        CCACHE_MAXSIZE="${CCACHE_MAXSIZE}" \
        CDASH_BUILD_NAME_PREFIX="${CDASH_BUILD_NAME_PREFIX}" \
        CI_JOB_ID="${run_id}" \
        CI_JOB_KIND="${CI_JOB_KIND:-continuous}" \
        CI_REVISION="${CI_REVISION:-}" \
        CTEST_SITE="${CTEST_SITE}" \
        WORK_DIR="${WORK_DIR}" \
        "${BENCHMARK_BASH:-bash}" "${script_dir}/run-bench.sh"
