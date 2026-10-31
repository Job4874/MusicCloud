#!/bin/sh
set -eu
iphone_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/musiccloud-playback-checks.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT HUP INT TERM
swiftc "$iphone_dir/MusicCloud/PlaybackQueueState.swift" "$iphone_dir/PlaybackPerformanceChecks.swift" -o "$build_dir/playback-checks"
"$build_dir/playback-checks"
