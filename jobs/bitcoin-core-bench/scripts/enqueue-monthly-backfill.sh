#!/usr/bin/env bash
set -euo pipefail

queue_dir="${CI_QUEUE_DIR:-/var/lib/ci-runner/queue}"
job="${CI_JOB:-bitcoin-bench}"
kind="${CI_JOB_KIND:-backfill}"

run_as=()
if [ "$(id -u)" -eq 0 ]; then
    run_as=(sudo -u ci-runner)
fi

targets=(
    "2025-06 b3bb4031ab32a1306c610f8683b25b8459b21dbc"
    "2025-07 1bed0f734b3f2dd876193b5cad303bfab1d250d5"
    "2025-08 509ffea40abbc706ef8b8fc449b7de8677fc5096"
    "2025-09 dda5228e02ca6a839bf87ae7dbd133547563816a"
    "2025-10 80bb7012be8e917e76af14af784e9199752abedb"
    "2025-11 b5a7a685bba312a780eddcb4a53ce2c26a937854"
    "2025-12 337b4a23690bd20eaf513aa29e8d5122f6b8a129"
    "2026-01 3400db80401d65ba16b52e5055486c75cd1412ff"
    "2026-02 779e7825dbfba6a1ebd6ad62a8b2f312bd2c6b5f"
    "2026-03 fae807ed25561bab7148c5a0d7bd847314c79d88"
    "2026-04 859215218667ca9f35d5adae0289e4a125798087"
    "2026-05 e69ea029955ceaa87e2d7121425e5adb093154e8"
)

for target in "${targets[@]}"; do
    read -r month revision <<< "${target}"
    item_id="bitcoin-bench-backfill-${month}"
    dedupe_key="${kind}:${job}:${month}"
    echo "enqueue ${item_id} ${revision}"
    "${run_as[@]}" ci-runner --queue-dir "${queue_dir}" enqueue "${job}" \
        --kind "${kind}" \
        --revision "${revision}" \
        --dedupe-key "${dedupe_key}" \
        --replace-pending \
        --id "${item_id}"
done
