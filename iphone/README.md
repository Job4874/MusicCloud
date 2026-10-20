# MusicCloud for iPhone

An original, private offline audio player. The app contains no server, analytics, advertisements, account system, streaming API, external Swift packages, or bundled third-party music. Audio stays in its own iPhone Documents folder and plays without the computer or internet.

**Delivery status:** complete source project, not an installed or verified iPhone binary. This package was created on Windows, where Apple's iOS SDK and Xcode are unavailable. Project/configuration checks and the exact device acceptance steps are provided below. A successful macOS build and a real-iPhone playback/USB test are still required. An unsigned IPA is not installable by itself.

## Build and installation

The project is `MusicCloud.xcodeproj`; its shared scheme and target are both `MusicCloud`. It targets **iPhone, iOS 16.0 and later**, with Swift 5 language mode. Use Xcode 16 or later. There is no XcodeGen, CocoaPods, or Swift Package Manager setup step.

On a Mac with Xcode:

1. Open `MusicCloud.xcodeproj`.
2. Select the MusicCloud target, Signing & Capabilities, then your personal development team. Choose a bundle identifier unique to you instead of `com.personal.musiccloud` if necessary. Keep the same identifier and signing identity for later updates so the existing app's data can be retained.
3. Connect and trust the iPhone, select it as the run destination, enable Developer Mode if iOS requests it, and press Run.
4. Follow the signing/renewal instructions in [the installation guide](../docs/USB-AND-INSTALL.md), if that guide is present in the full package. Free personal provisioning has restrictions and is not a permanent unsigned-install mechanism.

You can build the source on a remote macOS machine or private CI runner while continuing to use Windows for device installation and USB music transfers. The full package's installation documentation covers the available route and its current limitations. The app itself does not require a Mac after installation.

For a reproducible unsigned device build on macOS:

```bash
cd iphone
bash check-models.sh
bash build-unsigned.sh
```

`build-unsigned.sh` runs:

```bash
xcodebuild -project MusicCloud.xcodeproj -scheme MusicCloud \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
```

It packages the resulting app at `build/MusicCloud-unsigned.ipa`. This is deliberately unsigned. It must be signed for your device through the selected personal installation workflow. No signing credentials are in this project. There is no App Store submission or public download service.

For a simulator build, which does not test real-device file sharing or audio routes:

```bash
xcodebuild -project MusicCloud.xcodeproj -scheme MusicCloud \
  -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build-simulator CODE_SIGNING_ALLOWED=NO build
```

## Copy music from Windows over USB

Install the app first so that its shared Documents folder exists. Connect and unlock the iPhone, trust the computer, and open **Apple Devices → your iPhone → Files → MusicCloud**. Add audio files there and wait for copying to finish. In MusicCloud, return to **Library**; scanning runs when the app opens or returns to the foreground. The circular-arrow button is **Rescan music**.

The app scans Documents recursively. Directly transferred files and files in subfolders are recognized. The `+` button in Library also imports audio already accessible through the iPhone Files picker; it copies the selected files into `Documents/Music`. Duplicate names get a numbered suffix. App imports do not overwrite existing audio.

Indexed extensions: `.mp3`, `.m4a`, `.aac`, `.wav`, `.aif`, `.aiff`, `.flac`, `.caf`, case-insensitively. Extensions describe containers, not a guarantee that every codec variant decodes. Actual playback uses Apple's AVAudioPlayer and reports unsupported, damaged, missing, incomplete, or protected files. Protected subscription-service downloads cannot be imported as playable standalone audio. The app does not download or bypass protection on music.

Wait until a USB copy finishes before scanning; a partially copied file may have no metadata or fail to play. Rescan after the transfer completes. The app does not operate or automate Apple Devices itself.

## What works in the implementation

- Local library, metadata and embedded artwork, search by song/artist/album/filename, album/artist collections, and favorites.
- Create, rename, and delete playlists. Add/remove songs and drag them into order using Edit. Removing a playlist or its entries does not delete audio.
- Play/pause, previous/next, seeking, play-next insertion, an inspectable queue with removal, shuffle, repeat-all, and repeat-one.
- Background audio, lock-screen/Control Center playback metadata, remote play/pause/next/previous/seek, audio interruptions, and pausing when headphones disconnect.
- Explicit confirmation before an app-initiated audio-file deletion. A deleted file is also removed from its favorites/playlist entries.
- Visible copy, scan, save, and playback errors. No sample catalog or fake tracks are shown.

Queue, shuffle, repeat, playback position, and last-played song are session state; they do not automatically resume after the app is terminated. Favorites and ordered playlists persist across launches.

## Backups and data identity

**Transfer → Export playlist backup** exports `MusicCloud-playlists.json`. Save it in **On My iPhone → MusicCloud**, then copy that JSON to your computer through Apple Devices. It contains favorites and playlists, not audio. **Restore playlist backup** asks before replacing saved favorites/playlists. It validates the schema, version, unique playlist identities, ordered track entries, safe paths, and a 10 MB size cap before atomically replacing saved state.

Keep separate copies of your audio originals. Deleting the app deletes its local audio and settings. Export lists before reinstalling or changing the signing identity/bundle identifier. A normal signed update using the same app identity should retain the container, but always back up first.

Track identity is the case-sensitive relative path under Documents (for example `Music/Artist/Track.m4a`). Rescans and replacements at that same path keep memberships. Moving or renaming a file creates a new identity. Missing files remain as visibly missing entries in playlists so a later transfer to the original path restores the entry. Files removed with the app's explicit delete action are removed from playlists. Favorites for externally missing files are retained but hidden until the path returns.

Persistent state lives in `Application Support/MusicCloud/library-state.json`, outside USB-visible Documents. A corrupt or unknown-version state file is preserved instead of silently overwritten. Use a valid exported backup in the Transfer tab to restore it.

## Source map

| File | Responsibility |
| --- | --- |
| `MusicCloudApp.swift` | App entry, shared state, amber/dark colors |
| `Models.swift` | Track, ordered playlist, persisted state and repeat/time types |
| `LibraryStore.swift` | Recursive metadata scanning, imports, stable IDs, persistence, backup validation |
| `PlaybackController.swift` | AVAudioPlayer, queue, audio session, remote commands and interruptions |
| `LibraryViews.swift` | Library, search, grouped collections, per-song actions and artwork |
| `PlaylistViews.swift` | Playlist management, selection and ordering |
| `PlayerViews.swift` | Mini player, full player and queue |
| `TransferView.swift` | USB instructions, storage, export/restore |
| `Info.plist` | File sharing, audio document opening, background audio |
| `tools/generate-icon.cjs` | Original icon generator, using Node.js built-ins only |
| `tools/check-project.cjs` | Cross-platform project, source membership, scheme and icon checks |

The source uses system frameworks and system-provided icons. Owning this app's source does not remove rights attached to recordings you import; use audio you are authorized to copy. The full package's license covers its original source code.

## Verification

Run `node tools/check-project.cjs` from the iphone directory on Windows or macOS to check the parsed OpenStep project structure, object references, source memberships, shared scheme, target settings, sharing/background flags, and RGB icon. This check passed on Windows; the Info.plist and scheme also parsed as XML, all Swift files parsed with a Swift syntax grammar, and both Bash scripts passed syntax checks. Syntax parsing is not Swift type checking.

The model script checks ordered playlist/favorite JSON round trips (including Unicode paths), safe time formatting, and the repeat-mode cycle. It needs a Swift compiler and remains unrun here; it does not test AVFoundation or the interface. No native build, simulator run, or device test has been claimed on Windows.

After a successful build, verify on your own iPhone:

1. Connect over USB. Copy two playable audio files with different names, plus one tagged song with artwork. Rescan and verify metadata, counts, artwork, and search.
2. Disconnect the cable, turn off Wi-Fi and cellular data (or enable Airplane Mode), and confirm playback and seeking work.
3. Lock the phone. Verify continued audio and play/pause, next/previous, seek, title, artist, and artwork in Control Center/lock screen.
4. Verify pause/resume, previous restarting a song after three seconds, next at queue end, shuffle on/off, repeat-one, and repeat-all.
5. Create a playlist, select songs, reorder them in Edit, favorite a track, force-quit/reopen, and verify persistence.
6. Export the playlist backup. Create a temporary playlist, restore the exported backup with confirmation, and verify the previous order and favorites return. Cancel a restore and confirm nothing changes.
7. Add another file over USB, foreground the app, and verify it appears without losing existing playlists/favorites. Import a same-named file with `+` and check that it receives a numbered suffix.
8. Start a track and disconnect its headphones/Bluetooth device. It should pause. Check interruption behavior with a phone call; automatic resumption depends on iOS allowing it.
9. Remove an upcoming track from the queue, inspect the queue, and use Play next from a song menu. Verify ordered playlist editing affects playlists rather than audio files.
10. Cancel an audio deletion. Then confirm deletion for a disposable test file. Verify the physical file and its entries are gone, while other audio remains.
11. Place a damaged audio file in Documents and try playing it. Verify a readable error and that another valid song still plays. Check a partly copied file again after the copy completes and a rescan.

Large libraries are scanned sequentially off the main actor and cached in memory while the process lives. Very large collections and unusual codecs still require device profiling. The UI has no network or account dependency, but the signing/install tools and initial setup may require an internet connection.

Apple framework references: [AVAudioPlayer](https://developer.apple.com/documentation/avfaudio/avaudioplayer), [media metadata](https://developer.apple.com/documentation/avfoundation/retrieving-media-metadata), [audio sessions](https://developer.apple.com/documentation/avfaudio/avaudiosession), and [document opening/file-sharing behavior](https://developer.apple.com/documentation/bundleresources/information-property-list/lssupportsopeningdocumentsinplace).
