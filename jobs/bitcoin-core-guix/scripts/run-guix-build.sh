#!/usr/bin/env bash
set -euo pipefail

repo_dir=$1
log_file=$2

cd "${repo_dir}"
unset SOURCE_DATE_EPOCH

"${repo_dir}/contrib/guix/guix-build" 2>&1 | tee "${log_file}"
exit "${PIPESTATUS[0]}"
