# MusicCloud for iPhone

**Version 1.8 · Build 10 · iOS 16 or later.** A native SwiftUI player for audio stored on your iPhone. Playback works offline after copying files. The source contains no music, private library fixtures, accounts, advertisements or analytics. Wi-Fi upload starts a temporary local server only when requested.

The build produces an **unsigned IPA**, which requires device signing and installation. Version 1.8/build 10 was signed and updated in place through SideStore, retaining its effective bundle identifier, signing team and audited library data. Signing credentials and personal device evidence stay outside this repository.

## Build from Windows

Use the repository's manual **MusicCloud unsigned iPhone** workflow in Codemagic. Select the intended source branch and build; the macOS runner compiles with Xcode and returns `MusicCloud-unsigned.ipa` as an artifact. No local Mac is required for this route. The workflow has no signing, automatic publishing or scheduled trigger. Check the provider's remaining included allowance before starting a build; it does not require enabling a paid subscription.

Download the IPA to Windows and use your supported iPhone signing installer. Keep the existing app's bundle identifier and signing identity for an update, and preserve a verified backup before installation. Keeping the container alone does not make incompatible app data readable; the migration below handles the known 1.5 layout. Do not uninstall the existing app as an update step.

Free Apple development profiles expire after seven days. A refresh workflow renews them; it does not create a permanent free signature. Follow the official [AltStore Classic instructions](https://faq.altstore.io/altstore-classic) or [SideStore documentation](https://docs.sidestore.io/) for current installation and refresh requirements. Signing credentials are not included in this repository.

On a macOS machine with Xcode, the shared project/scheme is `MusicCloud.xcodeproj` / `MusicCloud`. From the repository root, `bash iphone/build-unsigned.sh` packages `iphone/build/MusicCloud-unsigned.ipa` with signing disabled.

## Version 1.8 changes

- One Liked Songs collection receives hearts and imported likes. First launch combines recognized historical/prepared liked collections, keeps the original collection identity and occurrence order, repairs previously unavailable entries when the import supplies a local path, and deduplicates matching source IDs or exact paths. Ordinary playlists retain their entries and duplicates. A byte-exact `library-state-before-liked-merge.json` is kept before changing existing state; original source documents and all audio are preserved.
- Artwork-led library and playlist views, a redesigned player, asynchronous thumbnail decoding/cache, cached catalog lookups and isolated playback progress updates avoid rebuilding the library on every clock tick.
- Audio file opening, queue checkpoint validation/encoding/atomic writes, and ordinary library saves run on serialized workers. Optimistic edits roll back to the last durable library if the latest save fails. User Pause, interruption, route-disconnect and superseded track requests gate playback, so late work cannot restart an old song. Deletion and backup restore require a completed durable save.
- Startup can show validated cached metadata and verified artwork while the full filesystem scan continues. This preview does not establish current file availability. Playback checks the real file path when used; the full scan matches cached records against current paths, sizes and modification times. Only a completed successful scan permits saved-queue restoration. The disposable cache never replaces playlist or audio data.

## Playback and editing

- Search the local library by title, artist, album or filename; browse artists/albums, favorites and ordered playlists.
- Search playlists by name. Compact playlist headers keep artwork, availability counts and Play/Shuffle close to the songs.
- Library, Playlists and Transfer stay accessible below the mini-player. iOS 26 uses a native tab bottom accessory; earlier systems reserve player space inside each tab's navigation content.
- Edit title, artist and album as display overrides. Audio bytes and path-based identities stay unchanged.
- Inspect and reorder the queue, play next, seek, shuffle and repeat. Repeated songs have separate queue-occurrence IDs.
- Queue, order, position, shuffle, repeat and source playlist checkpoints survive app restarts. Reopening restores the saved position paused. The player names the playlist or library view that started the queue. Older v1/v2 checkpoints remain readable and use the library title when no origin was saved.
- Background audio and lock-screen/Control Center controls use Apple's audio frameworks. Automatic interruption recovery requires prior playback intent and iOS's `shouldResume` permission; user Pause wins. If iOS omits an interruption-ended event, explicit Play requests fresh audio-session activation and clears the stale gate only on success. A refused request stays paused with its queue and position retained. Foregrounding alone does not restart playback. Headphone disconnection pauses audio. iOS can still terminate the process.

Scoped device-only unified-log diagnostics record playback/session flags, numeric interruption reasons and activation/assertion events. They omit song titles, file paths, accounts and device identifiers. There is no network telemetry or in-app debug flow.

Indexed extensions are MP3, M4A, AAC, WAV, AIF/AIFF, FLAC and CAF. Playback depends on the codec and iOS support. Protected subscription downloads are not standalone playable imports.

## Transfer music

**Wi-Fi:** open **Transfer → Start Wi-Fi transfer**, then open the displayed private link in a computer browser on the same private Wi-Fi. Choose audio files; each can be up to 512 MB. Keep the iPhone awake and the Transfer screen open. The link grants upload access while the server runs. Leaving this screen, backgrounding the app or tapping Stop ends the session and removes unfinished uploads. Completed files remain. App uploads use new filenames and preserve existing files.

**USB fallback:** connect and unlock the iPhone, trust the computer, then use **Apple Devices → your iPhone → Files → MusicCloud** on Windows. Wait for copying to finish, then pull down in Library or tap **Refresh library** in Transfer. Files in subfolders are scanned too. Library's **+** also imports audio through the iPhone Files picker; duplicate filenames receive numbered suffixes.

## Library preservation and backups

The new state file is `Library/Application Support/MusicCloud/library-state-v3.json`. The earlier `library-state.json`, original 1.5 exports, sidecars, audio and artwork files remain separate and are not overwritten by migration.

For the recognized 1.5 layout, first launch reads the newest supported timestamped saved export and the live favorites/order sidecars. It retains the original export and small sidecar bytes inside an immutable archive, including opaque fields and source metadata. Rich playlist entries keep their original order, duplicates, missing/unavailable records and per-occurrence identities. Saved artwork references read from the original verified artwork pack or loose files. Ambiguous display metadata is not guessed. A saved export cannot reconstruct changes never captured in it.

Once committed, v3 state wins on restart so older exports and sidecars do not reset new edits. Missing, malformed, unsafe or unsupported state protects the library instead of replacing it with defaults. Migration prepares data before a separate atomic save; the original files remain available for recovery.

A validated `MusicCloud-prepared-playlists-v3.json` in Documents can append prepared collections during first-start migration. It cannot replace current playlists, favorites or edits, and identity collisions reject the import. The app preserves that file and does not reapply it after the v3 state has been saved. Partial source collections retain unavailable entries and their source metadata.

Use **Transfer → Export library backup** to save JSON and copy it to your computer. Backups include favorites, ordered rich entries, display edits and the retained migration archive. Native saves/restores have a **32 MiB JSON cap** and validate schema and safe paths before replacement. Restore asks for confirmation; an older native backup preserves current display edits, while a newer-format backup replaces them as described in the app.

**Keep audio and artwork backups separately.** The JSON does not embed audio, the artwork pack or loose images. Track identity is its exact relative path under Documents. Renaming or moving a file changes that identity; returning a missing file to its original path can restore playability. Deleting the app deletes its local container.

## Checks

Run from the repository root on a host with Swift installed; artwork checks and the native build require Apple's macOS tools:

```bash
bash iphone/check-models.sh
bash iphone/Migration/run-checks.sh
bash iphone/Migration/ProductionTests/run-checks.sh
bash iphone/ArtworkTests/run-checks.sh
bash iphone/WiFiUploadTests/run-checks.sh
bash iphone/check-queue.sh
bash iphone/check-playback-performance.sh
bash iphone/check-library-persistence.sh
bash iphone/build-unsigned.sh
```

Build 10 at commit `668a24fa` passed all eight synthetic check groups and the native ARM64 Release build. These cover model/schema handling, source retention and migration, artwork, upload boundaries, duplicate queues, interruption intent, ordered persistence and durable restore/deletion barriers. They do not establish physical interruption behavior.

Completed build 9 physical iPhone checks:

- A continuous 98.997-second monitor included 82.993 seconds in the background with the 521-track Liked Songs queue. The PID stayed unchanged; average background CPU was 1.360%, with a maximum measured footprint of 118.018 MiB.
- Real iOS media controls paused, played and advanced the queue. Reversible heart and metadata edit/reset checks returned the library to its audited state; the edited test file's audio checksum stayed unchanged. A cold restart restored the paused position and playlist origin.
- Exact state audits verified 31 playlists, including 597 Liked Songs entries with 521 audio references and 76 unavailable records; all 30 ordinary playlists and both favorites remained intact. Original export/sidecar bytes, the pre-merge backup and artwork hashes were preserved. All 1,732 audio paths retained their regular-file type and byte size.
- A full local decode of the verified 1,732-file audio backup passed. This checks decodability, not Bluetooth hardware, source mastering quality or audible playback under interruption.

Completed build 10 physical checks:

- Installed version/signing identity and exact library audits passed: 31 playlists, 597 Liked Songs entries with 521 audio references and 76 unavailable entries, all 30 ordinary playlists and both favorites preserved. All 1,732 audio paths retained regular-file type and byte size; 1,807 indexed artwork ranges and 45 new cover checksums were preserved.
- The first captured screen, 4.334 seconds after launch, showed the cached library while the full scan continued. This was a usable preview, not completed filesystem validation or early saved-queue restoration.
- The phone's Developer **Fast App Termination** option was observed ON and switched OFF. Before that change, scoped system logs proved the OS deliberately killed process 8868 after suspension with the reason **BG Kill Demo**, requesting no crash report. [Apple DTS describes this testing option](https://developer.apple.com/forums/thread/840468).
- With only that setting changed, process 8891 survived the timer alarm. The interruption ended at 03:22:23.481 UTC with `shouldResume`; automatic activation succeeded and the audio player resumed in the background at 03:22:23.698 UTC, about 217 ms later. No manual Play or MusicCloud foreground launch occurred first. Independent process checks confirmed the same PID during the alarm and again at 03:22:53 UTC. This passes same-process automatic timer-interruption recovery.

- Two overlapping DVT monitors covered a combined 153.260 seconds in one process, averaging 1.757% app CPU. The 115.233-second background interval averaged 1.259% and included playback, the alarm pause and automatic resumption; it was not uninterrupted audio. Maximum measured footprint was 156.939 MiB. Returning through the actual Home-screen app icon retained playback and Liked Songs origin; the queue had advanced naturally to the following song.
- A live Wi-Fi session served its transfer page, rejected an invalid token and foreign origin with HTTP 403, and accepted a generated silent WAV with HTTP 201. Phone readback matched SHA-256. Exact test-file cleanup left existing upload entries and native library bytes unchanged; the temporary server was then stopped.

- After a complete SideStore refresh, both matching profiles had new creation/expiry dates and MusicCloud remained build 10 with a validated profile. Native library and playback files stayed byte-identical across refresh. A final reopened-app audit retained all original 48 queue occurrences, both orders and tokens, index, playlist origin, shuffle/repeat and the exact saved position; the player was visibly paused. The final library/audio/artwork audit passed again.

The physical repeat delivered an ordinary interruption-ended event. Missing-ended manual Play recovery remains covered by synthetic state tests. An actual incoming Bluetooth phone call and audible hardware quality were not tested in this run. A new process restoring a paused queue is a different result from automatic same-process resumption.

Before relying on an installed update, verify your playlist/favorite counts, missing records, artwork and edited metadata; restart to check persistence; test a duplicate-song queue and call interruption; then try a small Wi-Fi and USB transfer. Export a new backup and retain the original data until those checks pass.
