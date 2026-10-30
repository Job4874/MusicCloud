#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/musiccloud-upload-checks.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT HUP INT TERM
swiftc "$script_dir/../MusicCloud/WiFiUploadServer.swift" "$script_dir/main.swift" -o "$build_dir/upload-checks"
"$build_dir/upload-checks"
