#!/usr/bin/env bash
set -euo pipefail

git -C "${BITCOIN_REPO}" fetch origin
git -C "${BITCOIN_REPO}" checkout master
git -C "${BITCOIN_REPO}" reset --hard origin/master
git -C "${QA_ASSETS_PATH}" pull --ff-only

cd "${VALGRIND_FUZZ_JOB_DIR}"
nix develop "${VALGRIND_FUZZ_JOB_DIR}#gcc" \
    --system x86_64-linux \
    --no-write-lock-file \
    --command ctest --verbose -S scripts/valgrind-fuzz.cmake \
        -DCTEST_SOURCE_DIRECTORY="${BITCOIN_REPO}" \
        -DCTEST_SITE="${CTEST_SITE}"
