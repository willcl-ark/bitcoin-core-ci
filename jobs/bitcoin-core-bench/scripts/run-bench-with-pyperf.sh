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

reset_pyperf() {
    set +e
    python3 -m pyperf system reset >"${pyperf_prefix}-reset.log" 2>&1
    python3 -m pyperf system show >"${pyperf_prefix}-after.log" 2>&1
}
trap reset_pyperf EXIT

python3 -m pyperf system show >"${pyperf_prefix}-before.log" 2>&1
python3 -m pyperf system tune >"${pyperf_prefix}-tune.log" 2>&1

runuser -u ci-runner -- \
    env \
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
        CI_JOB_KIND="${CI_JOB_KIND:-nightly}" \
        CI_REVISION="${CI_REVISION:-}" \
        CTEST_SITE="${CTEST_SITE}" \
        WORK_DIR="${WORK_DIR}" \
        bash "${script_dir}/run-bench.sh"
