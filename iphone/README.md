# MusicCloud for iPhone

**Version 1.8 · Build 10 · iOS 16 or later.** A native SwiftUI player for audio stored on your iPhone. Playback works offline after copying files. The source contains no music, private library fixtures, accounts, advertisements or analytics. Wi-Fi upload starts a temporary local server only when requested.

The build produces an **unsigned IPA**, which requires device signing and installation. The preceding version 1.7/build 8 was signed and installed over USB on an existing installation, retaining its effective bundle identifier, signing team and library data. Signing credentials and personal device evidence stay outside this repository.

## Build from Windows

Use the repository's manual **MusicCloud unsigned iPhone** workflow in Codemagic. Select the intended source branch and build; the macOS runner compiles with Xcode and returns `MusicCloud-unsigned.ipa` as an artifact. No local Mac is required for this route. The workflow has no signing, automatic publishing or scheduled trigger. Check the provider's remaining included allowance before starting a build; it does not require enabling a paid subscription.

Download the IPA to Windows and use your supported iPhone signing installer. Keep the existing app's bundle identifier and signing identity for an update, and preserve a verified backup before installation. Keeping the container alone does not make incompatible app data readable; the migration below handles the known 1.5 layout. Do not uninstall the existing app as an update step.

Free Apple development profiles expire after seven days. A refresh workflow renews them; it does not create a permanent free signature. Follow the official [AltStore Classic instructions](https://faq.altstore.io/altstore-classic) or [SideStore documentation](https://docs.sidestore.io/) for current installation and refresh requirements. Signing credentials are not included in this repository.

On a macOS machine with Xcode, the shared project/scheme is `MusicCloud.xcodeproj` / `MusicCloud`. From the repository root, `bash iphone/build-unsigned.sh` packages `iphone/build/MusicCloud-unsigned.ipa` with signing disabled.

## Version 1.8 changes

- One Liked Songs collection receives hearts and imported likes. First launch combines recognized historical/prepared liked collections, keeps the original collection identity and occurrence order, repairs previously unavailable entries when the import supplies a local path, and deduplicates matching source IDs or exact paths. Ordinary playlists retain their entries and duplicates. A byte-exact `library-state-before-liked-merge.json` is kept before changing existing state; original source documents and all audio are preserved.
- Artwork-led library and playlist views, a redesigned player, asynchronous thumbnail decoding/cache, cached catalog lookups and isolated playback progress updates avoid rebuilding the library on every clock tick.
- Audio file opening, queue checkpoint validation/encoding/atomic writes, and ordinary library saves run on serialized workers. Optimistic edits roll back to the last durable library if the latest save fails. User Pause, interruption, route-disconnect and superseded track requests gate playback, so late work cannot restart an old song. Audio session activation occurs only when playback is allowed.
- A disposable metadata cache accelerates later scans; every cached record is matched against current path, file size and modification time. The cache never replaces playlist or audio data. Cover art remains available offline.

## Playback and editing

- Search the local library by title, artist, album or filename; browse artists/albums, favorites and ordered playlists.
- Search playlists by name. Compact playlist headers keep artwork, availability counts and Play/Shuffle close to the songs.
- Library, Playlists and Transfer stay accessible below the mini-player. iOS 26 uses a native tab bottom accessory; earlier systems reserve player space inside each tab's navigation content.
- Edit title, artist and album as display overrides. Audio bytes and path-based identities stay unchanged.
- Inspect and reorder the queue, play next, seek, shuffle and repeat. Repeated songs have separate queue-occurrence IDs.
- Queue, order, position, shuffle, repeat and source playlist checkpoints survive app restarts. Reopening restores the saved position paused. The player names the playlist or library view that started the queue. Older v1/v2 checkpoints remain readable and use the library title when no origin was saved.
- Background audio and lock-screen/Control Center controls use Apple's audio frameworks. Calls pause playback; resumption requires prior playback and iOS permission to resume. Headphone disconnection pauses audio. iOS can still terminate the process.

Indexed extensions are MP3, M4A, AAC, WAV, AIF/AIFF, FLAC and CAF. Playback depends on the codec and iOS support. Protected subscription downloads are not standalone playable imports.

## Transfer music

**Wi-Fi:** open **Transfer → Start Wi-Fi transfer**, then open the displayed private link in a computer browser on the same private Wi-Fi. Choose audio files; each can be up to 512 MB. Keep the iPhone awake and the Transfer screen open. The link grants upload access while the server runs. Leaving this screen, backgrounding the app or tapping Stop ends the session and removes unfinished uploads. Completed files remain. App uploads use new filenames and preserve existing files.

**USB fallback:** connect and unlock the iPhone, trust the computer, then use **Apple Devices → your iPhone → Files → MusicCloud** on Windows. Wait for copying to finish and return to Library, or tap **Rescan music**. Files in subfolders are scanned too. Library's **+** also imports audio through the iPhone Files picker; duplicate filenames receive numbered suffixes.

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

These compile the implementation and use synthetic fixtures for model/schema handling, lossless export retention, production migration, artwork, HTTP upload rules and duplicate queue/context recovery. The [1.7/build 8 Codemagic run](https://codemagic.io/app/6ae4ccd5d705292f6c4a0ef1/build/6ae4e586efa74786046f38ab) passed all six check groups and the native ARM64 Release build at commit `25cec0a`.

Separate physical iPhone checks verified the installed version and signing identity, retained rich playlist data and artwork, visible tab navigation, playlist playback origin, playback through a short Home-screen/background interval, and exact paused track/playlist/position recovery after a full process restart. A live local-network test loaded the upload page, rejected invalid tokens and foreign origins, uploaded generated silent WAV audio, and verified its phone checksum. The generated test file was removed after exact identity checks; existing upload files and saved library state stayed unchanged. Real incoming-call interruption and hardware lock-screen controls still require device testing; synthetic queue checks do not establish those behaviors.

Before relying on an installed update, verify your playlist/favorite counts, missing records, artwork and edited metadata; restart to check persistence; test a duplicate-song queue and call interruption; then try a small Wi-Fi and USB transfer. Export a new backup and retain the original data until those checks pass.


Version 1.8 physical-device validation is recorded after installation; the historical 1.7 results above do not establish playback quality for a newly compiled update. A full local decode of the verified 1,732-file audio backup passed before the 1.8 update. This checks the files, not Bluetooth hardware, source mastering quality or an incoming-call scenario.
