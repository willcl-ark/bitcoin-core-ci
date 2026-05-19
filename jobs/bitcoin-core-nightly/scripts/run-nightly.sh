#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
run_one="${script_dir}/run-nightly-one.sh"

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
git -C "${BITCOIN_REPO}" rev-parse HEAD

status=0

bash "${run_one}" gcc gcc gcc default "" 1 0 || status=$?
bash "${run_one}" gcc-stdlib-debug gcc gcc gcc-stdlib-debug gcc-stdlib-debug 1 0 || status=$?
bash "${run_one}" libcxx-hardened libcxx clang libcxx-hardened libcxx-hardened 1 0 || status=$?
bash "${run_one}" gcc-instrumented gcc gcc gcc-instrumented instrumented 0 1 || status=$?

exit "${status}"
