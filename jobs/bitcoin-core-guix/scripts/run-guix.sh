#!/usr/bin/env bash
set -euo pipefail

if [ ! -d "${BITCOIN_REPO}/.git" ]; then
    git clone "${BITCOIN_REPO_URL}" "${BITCOIN_REPO}"
fi

if [ ! -d "${SDK_PATH}/Xcode-26.1.1-17B100-extracted-SDK-with-libcxx-headers" ]; then
    curl -fL https://bitcoincore.org/depends-sources/sdks/Xcode-26.1.1-17B100-extracted-SDK-with-libcxx-headers.tar |
        tar -xf - -C "${SDK_PATH}"
fi

git -C "${BITCOIN_REPO}" fetch origin
if [ -n "${CI_REVISION:-}" ]; then
    git -C "${BITCOIN_REPO}" checkout --detach "${CI_REVISION}"
else
    git -C "${BITCOIN_REPO}" checkout -B master origin/master
fi
git -C "${BITCOIN_REPO}" reset --hard HEAD

cd "${BITCOIN_REPO}"
ctest --verbose -S "${GUIX_JOB_DIR}/scripts/guix.cmake" \
    -DCTEST_SOURCE_DIRECTORY="${BITCOIN_REPO}" \
    -DCTEST_SITE="${CTEST_SITE}"
