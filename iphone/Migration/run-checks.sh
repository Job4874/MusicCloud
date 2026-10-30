#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/musiccloud-legacy-adapter.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT HUP INT TERM
swiftc "$script_dir/../MusicCloud/LegacyExportAdapter.swift" "$script_dir/main.swift" -o "$build_dir/legacy-adapter-checks"
"$build_dir/legacy-adapter-checks"

