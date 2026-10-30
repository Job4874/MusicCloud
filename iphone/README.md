# MusicCloud for iPhone

**Version 1.6 · Build 7 · iOS 16 or later.** A native SwiftUI player for audio stored on your iPhone. Playback works offline after copying files. The source contains no music, private library fixtures, accounts, advertisements or analytics. Wi-Fi upload starts a temporary local server only when requested.

The build produces an **unsigned IPA**. It still requires device signing and installation. This release has not been claimed as signed, installed or tested on a physical iPhone.

## Build from Windows

Use the repository's manual **MusicCloud unsigned iPhone** workflow in Codemagic. Select the intended source branch and build; the macOS runner compiles with Xcode and returns `MusicCloud-unsigned.ipa` as an artifact. No local Mac is required for this route. The workflow has no signing, automatic publishing or scheduled trigger. Check the provider's remaining included allowance before starting a build; it does not require enabling a paid subscription.

Download the IPA to Windows and use your supported iPhone signing installer. Keep the existing app's bundle identifier and signing identity for an update, and preserve a verified backup before installation. Keeping the container alone does not make incompatible app data readable; the migration below handles the known 1.5 layout. Do not uninstall the existing app as an update step.

Free Apple development profiles expire after seven days. A refresh workflow renews them; it does not create a permanent free signature. Follow the official [AltStore Classic instructions](https://faq.altstore.io/altstore-classic) or [SideStore documentation](https://docs.sidestore.io/) for current installation and refresh requirements. Signing credentials are not included in this repository.

On a macOS machine with Xcode, the shared project/scheme is `MusicCloud.xcodeproj` / `MusicCloud`. From the repository root, `bash iphone/build-unsigned.sh` packages `iphone/build/MusicCloud-unsigned.ipa` with signing disabled.

## Playback and editing

- Search the local library by title, artist, album or filename; browse artists/albums, favorites and ordered playlists.
- Edit title, artist and album as display overrides. Audio bytes and path-based identities stay unchanged.
- Inspect and reorder the queue, play next, seek, shuffle and repeat. Repeated songs have separate queue-occurrence IDs.
- Queue, order, position, shuffle and repeat checkpoints survive app restarts. Reopening restores the saved position paused.
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
bash iphone/build-unsigned.sh
```

These compile the implementation and use synthetic fixtures for model/schema handling, lossless export retention, production migration, artwork, HTTP upload rules and duplicate queue recovery. They are not real-device playback, networking, signing or migration tests. The `c65bc97` baseline passed the Codemagic build and these checks; later changes require another run.

Before relying on an installed update, verify your playlist/favorite counts, missing records, artwork and edited metadata; restart to check persistence; test a duplicate-song queue and call interruption; then try a small Wi-Fi and USB transfer. Export a new backup and retain the original data until those checks pass.

