#!/bin/sh
set -eu
iphone_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/musiccloud-queue-checks.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT HUP INT TERM
swiftc "$iphone_dir/MusicCloud/PlaybackQueueState.swift" "$iphone_dir/PlaybackQueueChecks.swift" -o "$build_dir/queue-checks"
"$build_dir/queue-checks"
