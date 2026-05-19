#!/usr/bin/env bash
set -euo pipefail

git -C "${BITCOIN_REPO}" fetch origin
git -C "${BITCOIN_REPO}" checkout master
git -C "${BITCOIN_REPO}" reset --hard origin/master

cd "${BITCOIN_REPO}"
ctest --verbose -S "${GUIX_JOB_DIR}/scripts/guix.cmake" \
    -DCTEST_SOURCE_DIRECTORY="${BITCOIN_REPO}" \
    -DCTEST_SITE="${CTEST_SITE}"
