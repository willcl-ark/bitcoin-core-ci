#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
job_dir=$(cd -- "${script_dir}/.." && pwd)
job_work_dir="${WORK_DIR}/bitcoin-bench"
worktree="${job_work_dir}/bitcoin"
commit=""

cleanup() {
    set +e
    if [ -n "${commit}" ]; then
        git -C "${BITCOIN_REPO}" worktree remove --force "${worktree}" 2>/dev/null
        git -C "${BITCOIN_REPO}" worktree prune 2>/dev/null
    fi
    rm -rf -- "${job_work_dir}"
}
trap cleanup EXIT

if [ ! -d "${BITCOIN_REPO}/.git" ]; then
    git clone --depth=1 "${BITCOIN_REPO_URL}" "${BITCOIN_REPO}"
fi

if [ -n "${CI_REVISION:-}" ]; then
    git -C "${BITCOIN_REPO}" fetch --depth=1 origin "${CI_REVISION}"
    git -C "${BITCOIN_REPO}" checkout --detach "${CI_REVISION}"
else
    git -C "${BITCOIN_REPO}" fetch --depth=1 origin master
    git -C "${BITCOIN_REPO}" checkout -B master FETCH_HEAD
fi

git -C "${BITCOIN_REPO}" reset --hard HEAD
git -C "${BITCOIN_REPO}" clean -dfx
commit=$(git -C "${BITCOIN_REPO}" rev-parse HEAD)
commit_short=$(git -C "${BITCOIN_REPO}" rev-parse --short=12 HEAD)
run_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
safe_run_time=${run_time//:/}

cleanup
mkdir -p "${job_work_dir}"
git -C "${BITCOIN_REPO}" worktree add --detach "${worktree}" HEAD
git -C "${worktree}" clean -dfx

artifact_dir="${BENCHMARK_ARTIFACT_ROOT}/${safe_run_time}-${commit_short}"
mkdir -p "${artifact_dir}"

metadata_file="${artifact_dir}/metadata.json"
bench_json="${artifact_dir}/bench.json"
bench_log="${artifact_dir}/bench.log"
bench_csv="${artifact_dir}/bench.csv"

export CCACHE_DIR
export CCACHE_MAXSIZE
export CMAKE_C_COMPILER_LAUNCHER=ccache
export CMAKE_CXX_COMPILER_LAUNCHER=ccache
export CTEST_CMAKE_GENERATOR=Ninja
export CTEST_CONFIGURE_PRESET=bench
export BENCHMARK_ARTIFACT_DIR="${artifact_dir}"
export BENCHMARK_JSON="${bench_json}"
export BENCHMARK_LOG="${bench_log}"
export BENCHMARK_CSV="${bench_csv}"
export BENCHMARK_METADATA="${metadata_file}"
export BENCHMARK_CPU_AFFINITY="${BENCHMARK_CPU_AFFINITY:-}"
export BENCHMARK_MIN_TIME_MS="${BENCHMARK_MIN_TIME_MS:-1000}"
export CDASH_BUILD_NAME_PREFIX
export CDASH_BUILD_NAME_SUFFIX=bench

python3 "${script_dir}/record-bench-results.py" write-metadata \
    --metadata "${metadata_file}" \
    --job-id "${CI_JOB_ID}" \
    --commit "${commit}" \
    --run-time "${run_time}" \
    --host "${CTEST_SITE}" \
    --compiler gcc \
    --preset bench \
    --min-time-ms "${BENCHMARK_MIN_TIME_MS}" \
    --artifact-dir "${artifact_dir}" \
    --cpu-affinity "${BENCHMARK_CPU_AFFINITY}" \
    --command "bin/bench_bitcoin -min-time=${BENCHMARK_MIN_TIME_MS} -output-json=${bench_json} -output-csv=${bench_csv}"

cd "${job_dir}"
nix develop "${job_dir}#gcc" \
    --system x86_64-linux \
    --no-write-lock-file \
    --command bash -euo pipefail -c '
        export CC=gcc
        ctest --verbose -S scripts/bench.cmake \
            -DCTEST_SOURCE_DIRECTORY="$1" \
            -DCTEST_SITE="$2"
    ' bash "${worktree}" "${CTEST_SITE}"

if [ ! -s "${bench_json}" ]; then
    echo "benchmark JSON was not produced: ${bench_json}" >&2
    exit 1
fi

python3 "${script_dir}/record-bench-results.py" record \
    --db "${BENCHMARK_DB}" \
    --metadata "${metadata_file}" \
    --bench-json "${bench_json}"

python3 "${script_dir}/generate-site.py" \
    --db "${BENCHMARK_DB}" \
    --output-dir "${BENCHMARK_SITE_DIR}" \
    --generated-at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
