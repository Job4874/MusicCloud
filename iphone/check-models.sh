#!/bin/bash
set -euo pipefail
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
temp_root="$(cd -- "${TMPDIR:-/tmp}" && pwd -P)"
check_dir="$(mktemp -d "$temp_root/musiccloud-model-checks.XXXXXX")"
check_dir="$(cd -- "$check_dir" && pwd -P)"
cleanup_checks() {
  if [[ "$check_dir" == "$temp_root"/musiccloud-model-checks.* && -d "$check_dir" && ! -L "$check_dir" ]]; then
    rm -rf -- "$check_dir"
  fi
}
trap cleanup_checks EXIT
swiftc "$project_dir/MusicCloud/Models.swift" "$project_dir/Tests/main.swift" -o "$check_dir/model-checks"
"$check_dir/model-checks"
