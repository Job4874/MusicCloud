#!/bin/sh
set -eu
iphone_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/musiccloud-library-writer.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT HUP INT TERM
swiftc "$iphone_dir/MusicCloud/LegacyExportAdapter.swift" "$iphone_dir/MusicCloud/LegacyLibraryMigration.swift" "$iphone_dir/MusicCloud/Models.swift" "$iphone_dir/LibraryPersistenceChecks.swift" -o "$build_dir/library-persistence-checks"
"$build_dir/library-persistence-checks"
