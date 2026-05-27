#!/usr/bin/env bash
set -euo pipefail

name=$1
dev_shell=$2
cc=$3
preset=$4
build_name_suffix=$5
enable_ccache=$6
use_instrumentation=$7

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
job_dir=$(cd -- "${script_dir}/.." && pwd)
job_work_dir="${WORK_DIR}/${name}"
worktree="${job_work_dir}/bitcoin"

cleanup() {
    set +e
    git -C "${BITCOIN_REPO}" worktree remove --force "${worktree}" 2>/dev/null
    git -C "${BITCOIN_REPO}" worktree prune 2>/dev/null
    rm -rf -- "${job_work_dir}"
}
trap cleanup EXIT

cleanup
mkdir -p "${job_work_dir}"
git -C "${BITCOIN_REPO}" clean -dfx
git -C "${BITCOIN_REPO}" worktree add --detach "${worktree}" HEAD
git -C "${worktree}" clean -dfx

cd "${job_dir}"

if [ "${enable_ccache}" = 1 ]; then
    export CCACHE_DIR
    export CCACHE_MAXSIZE
    export CMAKE_C_COMPILER_LAUNCHER=ccache
    export CMAKE_CXX_COMPILER_LAUNCHER=ccache
else
    unset CCACHE_DIR CCACHE_MAXSIZE CMAKE_C_COMPILER_LAUNCHER CMAKE_CXX_COMPILER_LAUNCHER
fi

export CDASH_BUILD_NAME_PREFIX
if [ -n "${build_name_suffix}" ]; then
    export CDASH_BUILD_NAME_SUFFIX="${build_name_suffix}"
else
    unset CDASH_BUILD_NAME_SUFFIX
fi

if [ "${use_instrumentation}" = 1 ]; then
    export CTEST_USE_INSTRUMENTATION=1
else
    unset CTEST_USE_INSTRUMENTATION
fi

export CTEST_CMAKE_GENERATOR=Ninja
export CTEST_CONFIGURE_PRESET="${preset}"

nix develop "${CI_FLAKE:?}#bitcoin-core-nightly-${dev_shell}" \
    --system x86_64-linux \
    --no-write-lock-file \
    --command bash -euo pipefail -c '
        export CC="$1"
        ctest --verbose -S scripts/build-unit-test.cmake \
            -DCTEST_SOURCE_DIRECTORY="$2" \
            -DCTEST_SITE="$3"
    ' bash "${cc}" "${worktree}" "${CTEST_SITE}"
