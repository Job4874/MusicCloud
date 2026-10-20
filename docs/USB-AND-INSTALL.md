# MusicCloud: install on iPhone and add music by cable

MusicCloud has a Windows library manager and a native iPhone player. Once music has been copied to the phone, playback uses the phone's local files. Your computer can be switched off. Music playback needs no cloud service or music subscription.

## Read this before starting

The iPhone app targets **iOS 16 or later**. Building the Swift source requires Xcode on macOS. You can use a compatible Mac, or build on a remote macOS runner and download an unsigned build to Windows. The Windows library manager does not compile Swift or sign iPhone apps. Check [Apple's Xcode/macOS/device compatibility table](https://developer.apple.com/xcode/system-requirements/) when choosing build tools.

A free Apple Account appears in Xcode as a **Personal Team**. Apple says its development provisioning profiles expire seven days after issuance; rebuild and reinstall the app to renew them. Apple currently limits Personal Teams to three installed apps per device, three devices, and ten App IDs. A free installation is therefore a renewable personal development installation, rather than a permanent signed release. See [Apple's Personal Team requirements](https://developer.apple.com/help/account/basics/about-your-developer-account).

Apple Devices for Windows transfers music files **after the iPhone app has been installed**. It does not turn the Swift source into an installable iPhone app. The package contains source and build automation; an unsigned `.ipa` still needs Apple signing before the phone can run it.

## Windows installation through a remote build and AltServer

This route uses a third-party installer, **AltServer**, and Apple's free personal signing. It avoids owning a Mac by building the source on a remote macOS machine. It still needs internet for the build download, Apple authentication, and periodic signing. Neither the build nor the iPhone installation is claimed as completed until the actual tools and phone report success.

**Build status:** the native source is prepared and statically checked, but a successful macOS compilation, personal signing, USB installation, and real-phone test are still required. No compiled IPA is included. The steps below describe a reproducible setup; a repository or a submitted CI run alone does not establish a successful build.

The free route requires:

- This Windows computer and an iPhone running iOS 16 or later, a working data cable, and enough local storage for the music.
- A free Apple Account with a personal signing slot available, plus AltServer's free Windows prerequisites. No paid developer enrollment is needed for this route.
- A private GitHub repository under your control, with an available included Actions allowance for a **standard macOS runner** and paid overage disabled. No payment method needs to be added for included free use. If the account cannot run the job free, stop and retain the local app/source rather than accepting any charge.
- For a fresh setup, connect GitHub and authorize access to the private source repository. Enter your Apple login yourself in AltServer; no Apple password belongs in chat, source, or the remote build.

1. Put only the app source and `.github/workflows/build-iphone.yml` in your **private** repository, or use the existing private source repository if already configured. Never upload your music, desktop data, Apple password, certificates, or phone backups. In the repository's Actions tab, select **Build iPhone app**, choose **Run workflow**, and wait for a successful result. Download the **MusicCloud-unsigned-ipa** artifact to Windows and extract **MusicCloud-unsigned.ipa**. Keep the same source bundle identifier for later builds. This build is unsigned and needs no Apple credentials or signing certificates in GitHub.
2. Check the repository's Actions allowance before every build. [GitHub's billing documentation](https://docs.github.com/en/billing/concepts/product-billing/github-actions) says private repositories use included quotas; accounts without a valid payment method are blocked when quota runs out. **Paid overage is not allowed for this project.** Keep it disabled and use only the included free allowance. If free minutes/storage are unavailable or a payment prompt appears, stop the build. Music playback and USB file copying do not require another CI build.
3. Install AltServer from [AltStore's official Windows guide](https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows). Its Windows prerequisites currently specify **iTunes and iCloud downloaded directly from Apple**, rather than their Microsoft Store versions. Apple Devices is a separate file-transfer application and does not replace those stated AltServer prerequisites. Check the guide's current compatibility instructions before changing an existing Apple software installation.
4. Start AltServer. Connect and unlock the iPhone by USB and accept Trust if requested. For this manual cable workflow, leave Wi-Fi syncing disabled. AltServer's [connection documentation](https://faq.altstore.io/altstore-classic/altserver) supports a direct USB connection. Its full AltStore setup guide enables Wi-Fi syncing for the automatic workflow; we use manual direct installation instead.
5. Hold **Shift** while clicking AltServer's Windows tray icon, then choose **Sideload .ipa…**, your connected iPhone, and the downloaded MusicCloud IPA. Follow AltServer's Apple Account authentication prompts. Its [direct-IPA installation documentation](https://faq.altstore.io/release-notes/altserver) states that this works without installing AltStore first and requires manual reinstallation every seven days.
6. Follow any iPhone trust/signing prompt. If requested, enable Settings > Privacy & Security > Developer Mode, restart, and confirm it. Open MusicCloud from the Home Screen and complete the real-device checks below.
7. Renew before the free profile expires: connect by USB and repeat direct installation with the **same Apple Account, app identity, and IPA**. Keep the IPA on your PC; downloading/building it again is unnecessary when only renewing the same code. Back up the phone before the first renewal and confirm its library survives. Do not delete MusicCloud to renew it.

AltServer's dependency and device compatibility must be verified on this computer. A visible success notification and a working Home Screen launch establish installation; a source ZIP or an unsigned IPA alone does not. If AltServer cannot see the phone, check its current official troubleshooting guide and Apple drivers before changing applications. Do not silently uninstall existing Apple software or enable Wi-Fi syncing to work around a cable problem.

If GitHub refuses to start a build without payment, do not change its billing settings to proceed. Use an available compatible Mac or the prepared manual workflow described in [the alternative build guide](CODEMAGIC-FALLBACK.md). Preparing that workflow does not connect an account or produce an IPA.

## Install or renew the iPhone app with Xcode

1. Copy the `iphone` folder to a Mac. Install a compatible Xcode and allow its required components to finish installing.
2. Open `iphone/MusicCloud.xcodeproj`; select scheme/target **MusicCloud**. Add your Apple Account in Xcode's Settings > Accounts.
3. Select the app target, then Signing & Capabilities. Enable automatic signing, choose your Personal Team, and use a unique bundle identifier. Keep that identifier and team unchanged for future updates.
4. Connect the iPhone to the Mac with its data cable. Unlock the phone and accept its Trust prompt if shown. Select the physical iPhone as Xcode's run destination.
5. If requested, enable Settings > Privacy & Security > Developer Mode on the phone, restart it, and confirm the setting. Apple notes that this setting may only appear after initiating device pairing. See [Apple's Developer Mode instructions](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device).
6. Choose Product > Run. Resolve any signing or pairing prompt in Xcode. A successful installation launches MusicCloud on the phone; see [Apple's build/run workflow](https://help.apple.com/xcode/mac/current/en.lproj/devdc0193470.html).
7. Stop the debugging session, open MusicCloud from its Home Screen icon, and test it away from Xcode. Use the cable again when renewing the profile or installing code changes. Do not configure wireless deployment.

For this route, sign in to Apple directly in Xcode. For the Windows route, authenticate through the installer you chose. Never put your Apple Account password into MusicCloud source, its JavaScript files, a repository, or a build workflow.

**Do not delete MusicCloud to renew signing.** Rebuild onto the installed app using the same bundle identifier and team. Keep a backup before every update; this package has not been exercised on your particular iPhone, and data preservation must be checked on the device.

## Add songs from the Windows computer

1. Install Apple's Apple Devices app on Windows. Connect and unlock the iPhone, then accept its Trust prompt if shown.
2. Select the iPhone in Apple Devices. In General, clear **Show this [device] when on Wi-Fi** and select Apply. This is the reverse of [Apple's documented Wi-Fi-sync enablement setting](https://support.apple.com/guide/devices-windows/mchl388b22c3/windows). Leave it off for this cable workflow.
3. Select **Files**, then **MusicCloud**. If MusicCloud is absent, finish the native installation first. MusicCloud's file-sharing configuration exposes its Documents folder; see [Apple's file-sharing key documentation](https://developer.apple.com/documentation/BundleResources/Information-Property-List/UIFileSharingEnabled).
4. In the desktop manager's **USB transfer** view, select **Prepare USB folder**, then **Open transfer folder**. Preparation copies audio files into `desktop/data/USB-Transfer`; it does not transfer songs to the phone itself. Drag the exported audio files into MusicCloud's file area in Apple Devices. Wait for completion. These are app files: use Files, rather than the device's Music sync section. Apple describes this immediate app-file transfer in its [Windows file-transfer guide](https://support.apple.com/guide/devices-windows/transfer-files-between-your-devices-mchl4bd77d3a/windows).
5. Open MusicCloud on the phone. It rescans when returning to the foreground; you can also tap the circular-arrow **Rescan music** action in Library. Play a transferred track. Eject the phone in Apple Devices before unplugging it.

Start with MP3, unprotected AAC/M4A, or WAV files. File extension alone does not establish codec compatibility; test each format you plan to use. Streaming-service offline caches and protected downloads are not ordinary playable audio files for this app. The app does not download, convert, or remove protection from them.

For a new batch of songs, repeat the file-copy and refresh steps. You do not need to compile the app just to add music. Keep distinct filenames when transferring directly into the Documents folder so a new song does not overwrite an unrelated song with the same name. Deleting an entry in the desktop library does not automatically delete the phone's copy. Desktop playlists and iPhone playlists are independent; the desktop export copies audio, not playlists. Create phone playlists in the native app.

The native app identifies a track by its path within Documents. Keep a song at the same filename and location when updating its bytes if you want its playlist/favorite references to remain attached. Moving or renaming it creates a different track identity. Files in nested folders are scanned as well.

If you already use iTunes device management, Apple's [iTunes file-sharing guide](https://support.apple.com/120403) describes its app File Sharing controls. On current Windows installations Apple recommends Apple Devices. The correct file-management interface depends on the Apple software installed; successful AltServer signing and successful music-file transfer are separate checks.

## Back up phone playlists by cable

1. On the phone, open MusicCloud's **Transfer** tab and tap **Export playlist backup**.
2. Save **MusicCloud-playlists.json** under **On My iPhone > MusicCloud**, keeping it in the app's shared Documents area.
3. Connect by USB. In Apple Devices > Files > MusicCloud, select that JSON file and choose **Save**, then save it to your PC backup folder. Apple documents the device-to-computer Save control in its [Apple Devices file-sharing instructions](https://support.apple.com/120402).
4. Keep the matching audio files with the backup. This JSON contains favorites and ordered playlists; it contains no songs.
5. To recover, copy the JSON and matching music back by USB. In the phone's Transfer tab, choose **Restore playlist backup**, select the JSON, and review the replace confirmation. Restoration replaces the phone's current saved playlists/favorites. Song paths must match those recorded in the backup.

## Confirm fully offline operation

These checks require the actual phone and are not claimed as completed:

- Disconnect the cable, enable Airplane Mode, and explicitly turn Wi-Fi off.
- Open MusicCloud, search the library, and play multiple imported songs.
- Lock the screen while a song plays; test the Lock Screen play/pause and next controls.
- Quit and reopen the app; confirm library and playlists survive.
- Reconnect by USB, add one new track, refresh, disconnect again, and play that track offline.
- After a signing renewal, confirm existing tracks and saved playlists remain before making further changes.

Music playback can be offline while Apple's provisioning still expires. Signing renewal requires your installer and Apple's signing services; offline playback cannot bypass that expiry.

## What “only by plugging into my computer” means here

The supplied workflow installs a private development build by cable and copies songs by cable. There is no App Store release, public installation link, streaming endpoint, or in-app download service in this package. Keep the source and signing access private and use only computers you trust.

A cable is a transfer method, not an anti-copy lock. The operating system's pairing, file-sharing, backup, and signing features still control what can be copied or installed. This project does not guarantee that another authorized computer, a phone backup, or the phone's owner could never copy files or install a separately signed build.

## Music and ownership

No commercial music catalog or third-party album artwork is included. Import music you created, public-domain recordings, or files whose terms allow the use you intend. Private use alone does not erase copyright: see the [U.S. Copyright Office's explanation](https://www.copyright.gov/what-is-copyright/). The original app source is supplied for you to maintain; Apple's SDKs and tools retain their own terms.

## If something fails

| Symptom | Next action |
| --- | --- |
| iPhone never appears on Windows | Unlock it, check its Trust prompt, try a known data cable/port, then follow Apple's connection troubleshooting from the Apple Devices guide. |
| MusicCloud absent under Files | Confirm a successful native install and the correct app target's file-sharing configuration. The desktop browser page is not the iPhone app. |
| Song appears but will not play | Test a short known-good unprotected MP3; inspect the native app error and available storage. |
| App stops opening about a week later | Reinstall through AltServer or rebuild/run in Xcode using the same Apple Account and app identity. Do not remove the app as the first troubleshooting step. |
| Xcode says the phone OS is unsupported | Use a compatible Xcode/macOS combination from Apple's current requirements table. |
| Existing tracks vanish after replacement | Stop copying. Restore from your own music/library backup; inspect whether the app was deleted or its bundle identifier changed. |

See `MAINTENANCE.md` for backups and safe updates. Apple documentation above was checked on October 20, 2026; interface labels and platform requirements can change.
