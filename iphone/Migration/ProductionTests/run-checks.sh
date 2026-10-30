#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
iphone_dir=$(CDPATH= cd -- "$script_dir/../.." && pwd)
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/musiccloud-production-migration.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT HUP INT TERM
swiftc "$iphone_dir/MusicCloud/LegacyExportAdapter.swift" "$iphone_dir/MusicCloud/Models.swift" "$iphone_dir/MusicCloud/LegacyLibraryMigration.swift" "$script_dir/main.swift" -o "$build_dir/production-migration-checks"
"$build_dir/production-migration-checks"
