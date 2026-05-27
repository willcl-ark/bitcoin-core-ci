#!/usr/bin/env bash
set -euo pipefail

if [ ! -d "${BITCOIN_REPO}/.git" ]; then
    git clone "${BITCOIN_REPO_URL}" "${BITCOIN_REPO}"
fi

if [ ! -d "${QA_ASSETS_PATH}/.git" ]; then
    git clone "${QA_ASSETS_REPO_URL}" "${QA_ASSETS_PATH}"
fi

git -C "${BITCOIN_REPO}" fetch origin
if [ -n "${CI_REVISION:-}" ]; then
    git -C "${BITCOIN_REPO}" checkout --detach "${CI_REVISION}"
else
    git -C "${BITCOIN_REPO}" checkout -B master origin/master
fi
git -C "${BITCOIN_REPO}" reset --hard HEAD

git -C "${QA_ASSETS_PATH}" fetch origin
git -C "${QA_ASSETS_PATH}" checkout -B master origin/master

cd "${VALGRIND_FUZZ_JOB_DIR}"
nix develop "${CI_FLAKE:?}#bitcoin-core-valgrind-fuzz-gcc" \
    --system x86_64-linux \
    --no-write-lock-file \
    --command ctest --verbose -S scripts/valgrind-fuzz.cmake \
        -DCTEST_SOURCE_DIRECTORY="${BITCOIN_REPO}" \
        -DCTEST_SITE="${CTEST_SITE}"
