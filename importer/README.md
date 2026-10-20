This optional adapter exports YouTube Music playlist metadata into a MusicCloud manifest. It requests all continuation pages and preserves returned order, duplicates and unavailable placeholders. It downloads no audio.

Follow [the local authentication and export guide](../docs/YOUTUBE-IMPORT.md). Keep authentication outside the MusicCloud folder. A bearer token or API key alone is insufficient; never paste credentials into chat or commit them.

Public or unlisted playlists can be exported without credentials using `--public --playlist URL_OR_ID --output FILE.json`. Private playlists and liked music require the local `--auth` route.

The only direct Python dependency is pinned in `requirements.txt`. This adapter uses ytmusicapi's undocumented service interface and a small, version-checked parser hook to retain deleted entries. Service changes can require maintenance. Counts are audited and exports with missing or unverifiable totals are labelled explicitly.

Run the credential-free tests from the MusicCloud folder:

```powershell
py -3 -m unittest discover -s importer/tests -v
runtime\node.exe --test importer\tests\manifest.test.mjs
```

The Python tests use generated responses and make no account requests. Installing the pinned dependency also enables a generated-fixture check against its actual parser.

Validate an exported manifest with the bundled runtime:

```powershell
runtime\node.exe importer\validate-manifest.mjs "C:\path\playlist.json"
```

Successful count-matched exports exit `0`; partial exports exit `2`; unverifiable totals exit `3`. Failures exit `1` and do not write an output. Existing outputs require `--overwrite`. A matching count verifies returned metadata rows; it does not make inaccessible or unavailable recordings playable.

For a previously discovered account playlist list, export its public playlists with a per-playlist audit:

```powershell
py -3 importer\batch_export.py --public --discovery "C:\path\discovery.json" --output-dir "C:\path\playlist-exports" --workers 2 --timeout 180
```

The discovery JSON contains `complete` and a `playlists` array of objects with `playlistId`, `title` and optional `reportedCount`. The batch writes one manifest per playlist ID and an `IMPORT-REPORT.json` entry for every discovery item. Account-only lists are marked as requiring authentication. Each public playlist gets one attempt, with at most two simultaneous processes and a finite per-playlist deadline. Existing validated manifests are reused unless `--refresh` is supplied. A failed or timed-out playlist stays visible in the report. Discovering some account playlists never implies the account library is complete.

If you manually export a **sanitized HAR** from the signed-in browser's developer tools, the optional local decoder can read already-captured playlist response metadata without credentials or network requests:

```powershell
py -3 importer\har_playlist.py --har "$env:LOCALAPPDATA\MusicCloud\private\playlist-sanitized.har" --playlist LM --output "$env:USERPROFILE\Documents\liked-music.json"
```

Keep HAR files outside MusicCloud and source archives: even a sanitized capture can contain private browsing/account data. This decoder never reads request headers/cookies or replays requests. It writes only the manifest's allowlisted song metadata. Load more songs normally in the browser before exporting additional captures; repeat `--har` for the initial and later files so captured continuation pages can be linked in order. It does not invent uncaptured songs, deduplicate playlist entries, or treat a truncated capture as complete. An optional `--reported-count` accepts the exact count you observed in the playlist UI when a response total is missing. Existing metadata outputs require `--overwrite`.

The separate optional `download_audio.py` helper imports ordinary playable YouTube streams into the running Windows library. It uses exact video IDs from validated manifests and makes no browser-profile, cookie, account, protected-cache or key requests. Deleted, private, restricted, protected or unavailable recordings remain explicit failures; a metadata export does not guarantee that every recording can be retrieved.

Downloads run with four parallel workers by default (`--workers 4`). There is no configured download rate cap or artificial request/download sleep. One coordinator performs all local uploads, source-ID updates and report writes, so concurrent downloads cannot lose source aliases or race report updates. This helper runs on your own computer with free software; it needs no subscription, paid API or hosted service.

Install the official Windows `yt-dlp.exe` from its [2026.08.19 release](https://github.com/yt-dlp/yt-dlp/releases/tag/2026.08.19) outside this source folder. The helper verifies its SHA-256 against the release checksum `66674953fe251b89f4d08c5f0e35e0728679bd67ab3d7d05c0562af101dd3e7a` before running it. This executable includes the matching EJS component. Supply Node 22 or newer and installed FFmpeg/FFprobe executables explicitly. These tools are free and do not require paid services. Updating the downloader requires reviewing a new official release and updating the helper's pinned checksum. See [upstream runtime setup](https://github.com/yt-dlp/yt-dlp/wiki/EJS).

Start MusicCloud, then begin with one recording:

```powershell
py -3 importer\download_audio.py --manifest "C:\private\LM.json" --download-dir "C:\private\MusicCloud-audio" --yt-dlp "C:\tools\yt-dlp.exe" --node "C:\tools\node.exe" --ffmpeg "C:\tools\ffmpeg.exe" --ffprobe "C:\tools\ffprobe.exe" --limit 1
```

`--limit` selects the first N unique available video IDs, including existing downloads. Repeat with a larger limit to continue; a verified existing M4A is reused, and the local library deduplicates content by SHA-256. Repeated playlist positions retain their order and share one downloaded recording. Damaged final M4A files are preserved in a quarantine subfolder and their exact video ID is retried. The helper checks each audio file with FFprobe before uploading it, then stores its source video ID, source title and first individual artist. Existing source IDs are retained when identical audio is shared by several videos. Catalog matching prefers this exact source identity. It connects only to `127.0.0.1` for local library changes; `--port` defaults to `4783`.

Every download has a finite deadline (240 seconds by default), bounded retries, and a 256 MB file limit. Windows subprocesses start suspended inside an owned process job, so a timeout terminates their Node/FFmpeg descendants as well. `download-report.json` in the chosen private download folder records every manifest position as imported, failed, unavailable, pending in the current run or deferred outside the current limit. It retains source completeness separately and never turns a partial source manifest into a complete library. A report is updated after each recording. Raw process diagnostics and signed stream URLs are not written to the report. Audio files, temporary fragments and this personal report must stay outside source archives and GitHub uploads. Exit `0` means the selected IDs imported without failures; it does not mean that all playlist entries were retrieved. Exit `2` records per-entry failures; exit `1` means the run could not start.

Five consecutive failed video IDs pause the coordinator, stop scheduling new work and cancel active owned download processes. The report retains the last fixed failure reason and all unattempted rows as pending; exit `3` indicates this pause. Check that reason before resuming after network, access or rate-limit problems. `--max-consecutive-failures` adjusts the finite pause threshold; a successful import resets the consecutive count. Repeat `--manifest` to include additional playlist exports in the same deduplicated run. If the local MusicCloud server stops, already verified audio remains on disk and is reused when the server is available again.
