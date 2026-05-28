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
commit_time=$(date -u -d "@$(git -C "${BITCOIN_REPO}" show -s --format=%ct HEAD)" +"%Y-%m-%dT%H:%M:%SZ")
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
export BENCHMARK_RUN_COUNT="${BENCHMARK_RUN_COUNT:-5}"
export CDASH_BUILD_NAME_PREFIX
export CDASH_BUILD_NAME_SUFFIX=bench

if [ "${BENCHMARK_RUN_COUNT}" -lt 1 ]; then
    echo "BENCHMARK_RUN_COUNT must be at least 1" >&2
    exit 1
fi

python3 "${script_dir}/record-bench-results.py" write-metadata \
    --metadata "${metadata_file}" \
    --job-id "${CI_JOB_ID}" \
    --commit "${commit}" \
    --commit-time "${commit_time}" \
    --run-time "${run_time}" \
    --sample-index 0 \
    --sample-count "${BENCHMARK_RUN_COUNT}" \
    --host "${CTEST_SITE}" \
    --compiler gcc \
    --preset bench \
    --min-time-ms "${BENCHMARK_MIN_TIME_MS}" \
    --artifact-dir "${artifact_dir}" \
    --cpu-affinity "${BENCHMARK_CPU_AFFINITY}" \
    --cpuset-shield "${BENCHMARK_CPUSET_SHIELD:-}" \
    --cpuset-housekeeping "${BENCHMARK_CPUSET_HOUSEKEEPING:-}" \
    --command "${BENCHMARK_RUN_COUNT} x bench_bitcoin -min-time=${BENCHMARK_MIN_TIME_MS}"

cd "${job_dir}"
nix develop "${CI_FLAKE:?}#bitcoin-core-bench-gcc" \
    --system x86_64-linux \
    --no-write-lock-file \
    --command bash -euo pipefail -c '
        export CC=gcc
        ctest --verbose -S scripts/bench.cmake \
            -DCTEST_SOURCE_DIRECTORY="$1" \
            -DCTEST_SITE="$2"
    ' bash "${worktree}" "${CTEST_SITE}"

bench_binary=""
for candidate in \
    "${worktree}/build-bench/bin/bench_bitcoin" \
    "${worktree}/build-bench/src/bench/bench_bitcoin"
do
    if [ -x "${candidate}" ]; then
        bench_binary="${candidate}"
        break
    fi
done
if [ -z "${bench_binary}" ]; then
    echo "bench_bitcoin binary was not produced in a known output path" >&2
    exit 1
fi

bench_command=("${bench_binary}")
if [ -n "${BENCHMARK_CPU_AFFINITY}" ]; then
    bench_command=(taskset -c "${BENCHMARK_CPU_AFFINITY}" "${bench_command[@]}")
fi

if [ -n "${BENCHMARK_CPUSET_SHIELD:-}" ]; then
    bench_command=(
        /run/wrappers/bin/sudo "${script_dir}/run-with-cpuset-shield.sh"
        "${BENCHMARK_CPUSET_SHIELD}"
        "${BENCHMARK_CPUSET_HOUSEKEEPING}"
        --
        "${bench_command[@]}"
    )
fi

for sample_index in $(seq 1 "${BENCHMARK_RUN_COUNT}"); do
    sample_name=$(printf "sample-%02d" "${sample_index}")
    sample_dir="${artifact_dir}/${sample_name}"
    mkdir -p "${sample_dir}"
    sample_metadata="${sample_dir}/metadata.json"
    sample_json="${sample_dir}/bench.json"
    sample_log="${sample_dir}/bench.log"
    sample_csv="${sample_dir}/bench.csv"

    python3 "${script_dir}/record-bench-results.py" write-metadata \
        --metadata "${sample_metadata}" \
        --job-id "${CI_JOB_ID}-${sample_name}" \
        --commit "${commit}" \
        --commit-time "${commit_time}" \
        --run-time "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        --sample-index "${sample_index}" \
        --sample-count "${BENCHMARK_RUN_COUNT}" \
        --host "${CTEST_SITE}" \
        --compiler gcc \
        --preset bench \
        --min-time-ms "${BENCHMARK_MIN_TIME_MS}" \
        --artifact-dir "${artifact_dir}" \
        --cpu-affinity "${BENCHMARK_CPU_AFFINITY}" \
        --cpuset-shield "${BENCHMARK_CPUSET_SHIELD:-}" \
        --cpuset-housekeeping "${BENCHMARK_CPUSET_HOUSEKEEPING:-}" \
        --command "bench_bitcoin -min-time=${BENCHMARK_MIN_TIME_MS} -output-json=${sample_json} -output-csv=${sample_csv}"

    {
        printf '== %s/%s %s ==\n' "${sample_index}" "${BENCHMARK_RUN_COUNT}" "${sample_name}"
        "${bench_command[@]}" \
            -min-time="${BENCHMARK_MIN_TIME_MS}" \
            -output-json="${sample_json}" \
            -output-csv="${sample_csv}"
    } 2>&1 | tee "${sample_log}" | tee -a "${bench_log}"

    if [ ! -s "${sample_json}" ]; then
        echo "benchmark JSON was not produced: ${sample_json}" >&2
        exit 1
    fi

    if [ "${sample_index}" -eq 1 ]; then
        cp "${sample_json}" "${bench_json}"
        cp "${sample_csv}" "${bench_csv}"
    fi

    python3 "${script_dir}/record-bench-results.py" record \
        --db "${BENCHMARK_DB}" \
        --metadata "${sample_metadata}" \
        --bench-json "${sample_json}"
done

python3 "${script_dir}/generate-site.py" \
    --db "${BENCHMARK_DB}" \
    --output-dir "${BENCHMARK_SITE_DIR}" \
    --generated-at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
