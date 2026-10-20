# MusicCloud — your personal music app

An offline iPhone player and a Windows music library manager, with all application source included. No ads, analytics, hosted music service, paid API, or subscription is required by the app.

**Current delivery:** the Windows app runs locally. Original test audio and imported ordinary M4A recordings have passed actual desktop playback checks. The native iPhone project is written and statically checked. A successful macOS compilation, personal signing, installation, and real-phone acceptance test are still needed. No installable IPA is claimed to exist.

## Open the Windows app

In the **MusicCloud-Windows.zip** portable package, double-click **START-MUSICCLOUD.cmd**. It uses the included Windows x64 Node.js runtime, starts the local server, and opens **http://127.0.0.1:4783**. No npm installation or internet connection is needed for this player. Keep this folder in a writable location. The smaller **MusicCloud-source.zip** contains source without the runtime executable; use Node.js 22 or copy the portable package's runtime into it.

Double-click **STOP-MUSICCLOUD.cmd** to stop the instance started by the launcher. A repeated start reuses the running app. The stop command authenticates the exact managed instance; it does not terminate unrelated Node processes. If the port is in use by another app, the launcher reports it instead of opening or stopping that app.

Add your own audio files using **Add music** or drag-and-drop. Search, play, seek, adjust the volume, favorite tracks, edit metadata, and make playlists. **Try a soundcheck** generates an original five-second melody so you can check playback without acquiring music. The app does not come with a commercial music catalog.

The library, copied audio, favorites and playlists live under **desktop/data**. The app only listens on the computer's loopback address. It does not expose an installer or music server to your network.

## Put the app and music on your iPhone

The iPhone app is the native project in **iphone/MusicCloud.xcodeproj**, targeting iOS 16 or later. It plays local files using Apple's audio frameworks and supports background playback, lock-screen controls, search, favorites, ordered playlists, and queue controls.

Windows cannot compile this Swift/iOS project locally. The included manual **Build iPhone app** workflow at **.github/workflows/build-iphone.yml** can compile it on a standard remote macOS runner in a private GitHub repository. It uses no signing secrets and uploads only a private unsigned build artifact, **MusicCloud-unsigned-ipa**, containing **MusicCloud-unsigned.ipa**. The workflow has no automatic or scheduled trigger and retains its build for one day.

Use only available included free runner allowance, with paid overage disabled. Do not add a payment method or select a paid runner for this project. If free build allowance is unavailable, retain the source and stop before incurring charges. Keep the source repository private and dispatch the workflow manually after checking the included allowance.

An alternative manual macOS build workflow is prepared in **codemagic.yaml**; see **docs/CODEMAGIC-FALLBACK.md**. Its presence does not mean an account is connected or a build has succeeded. Either build route produces the same unsigned app for Windows USB installation; the installed player does not depend on the build service.

After a successful build, Windows AltServer can sign and install the IPA while your iPhone is connected by USB. You enter your Apple Account in that installer yourself. Apple's free personal signing requires renewal every seven days. The app's offline audio does not need another code build when you add songs.

After installation, select **USB transfer → Prepare USB folder → Open transfer folder** in the Windows app. Use **Apple Devices → iPhone → Files → MusicCloud** or iTunes File Sharing to copy the prepared audio and the named playlist-backup JSON over the cable. Keep their filenames. Open MusicCloud on the phone and use **Rescan music**, then **Transfer → Restore playlist backup** to import the Windows playlists and favorites. Review its replacement confirmation before applying. Disconnect and test playback offline.

The native source and desktop app do not offer network installation. USB is the supplied installation/transfer workflow; it is not an anti-copy lock against another authorized signer or the phone owner. The Windows USB export includes desktop playlists, favorites and imported source playlists with currently matched local audio. Source order is retained; repeated matched files occur once per playlist, as required by the phone backup format. A separate transfer report retains every observed source row and marks missing, ambiguous, repeated and unavailable entries. Copying audio alone does not apply playlists. The phone can also export its own backup before replacement.

See **docs/USB-AND-INSTALL.md** for the exact Windows signing prerequisites, free renewal, USB file copying, backup and device checks. See **iphone/README.md** for native source details and build commands.

## Import YouTube Music playlist records

The optional **importer** exports ordered playlist metadata using locally supplied account authentication. It requests all available pages, retains duplicate entries and observed unavailable/deleted placeholders, and compares extracted entries with the reported count. Unknown or missing entries are reported rather than silently marked complete.

The optional **download_audio.py** helper imports ordinary available streams using free local tools, checks each audio file, resumes existing verified downloads, and records failures and deferred rows explicitly. Actual ordinary-stream imports have succeeded without account credentials. The helper does not export or decrypt Premium offline audio caches. Personal metadata, media, and verification reports stay separately on this computer and are excluded from the source packages.

In **YouTube playlists**, import the generated JSON reports and inspect every returned row. Imported audio matches by its exact source video ID when recorded; other local files can match by title and artist. Credentials belong in a private local configuration outside this project, never in chat, a source repository, build artifacts, or the ZIP. See **docs/YOUTUBE-IMPORT.md** and **importer/README.md** for the exact free setup and commands.

The downloadable source/portable ZIPs exclude personal library data, playlist exports, phone reports, screenshots and credentials. Preserve **desktop/data** separately when updating your existing installation.

## Maintain and verify it

The desktop is plain JavaScript, HTML and CSS with Node built-ins. The iPhone app uses SwiftUI, AVFoundation and MediaPlayer without external Swift packages. Edit these source files directly. The optional YouTube importer has its own pinned free Python dependency; changes in YouTube's undocumented interface may require maintenance.

From PowerShell in this folder:

```powershell
.\runtime\node.exe --test desktop/tests/*.test.mjs importer/tests/*.test.mjs
.\runtime\node.exe iphone/tools/check-project.cjs
```

With Python 3.10 or later installed, the importer's mocked checks run without its live service dependency:

```powershell
python -m unittest discover -s importer/tests -p "test_*.py"
```

On macOS with Xcode, before claiming an iPhone build works:

```bash
bash iphone/check-models.sh
bash iphone/build-unsigned.sh
```

Then sign and install the resulting build and complete the real-device checks in the USB guide. A passing source parser or desktop playback test does not prove iPhone playback.

Back up **desktop/data** while the app is stopped, and retain your audio originals. Before a phone update or renewal, export **MusicCloud-playlists.json** from the phone's Transfer tab and copy it to your computer. Full recovery and source maintenance are documented in **docs/MAINTENANCE.md**.

## Cost and source permission

The original app source is supplied with unrestricted, no-fee use and modification permission in **LICENSE.txt**. The bundled Node.js runtime has its complete free/open-source notices in **runtime/LICENSE**. Optional dependency licenses remain their own. No third-party commercial songs or album artwork are supplied. This source permission does not change the rights attached to music files you add.

Existing hardware, storage, internet and electricity are yours. The app adds no required paid service. Initial external-tool downloads, account authentication and signing renewal need internet; playback of copied phone files works offline while its app signing remains valid.
