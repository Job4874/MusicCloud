# Maintaining your MusicCloud

You maintain the source code, library files, backups, and signing renewals. There is no hosted music account, paid API, server subscription, or remote music service to administer. A remote build uses your chosen build-service account; local playback does not. Keep the original music files on the computer even after copying them to the phone.

## Routine use

- Start `START-MUSICCLOUD.cmd` or follow the project README. The manager runs `desktop/server.mjs` at `http://127.0.0.1:4783` on this computer.
- Add music you are authorized to use, verify playback, and organize the library before exporting files to the phone.
- In **USB transfer**, choose **Prepare USB folder**, then **Open transfer folder** to reach the audio copies for the phone.
- Copy new songs through Apple Devices > Files > MusicCloud using USB, then refresh the phone's library. Treat the phone and desktop as separate copies of your files.
- Use the same Apple Account and app identity when renewing through AltServer or Xcode. The seven-day renewal requirement is described in `USB-AND-INSTALL.md`. Desktop and iPhone playlists remain separate.

## Keep two kinds of backup

**Project and desktop library backup.** Stop the desktop manager before copying its writable library data. Copy the whole MusicCloud project folder and your original audio collection to a different drive. The default desktop library lives in `desktop/data/library.json`, imported audio in `desktop/data/audio`, and phone export copies in `desktop/data/USB-Transfer`. If you set a custom data directory, back up that directory instead. A metadata export alone is not a music backup. Name each backup with its date and keep the previous working version until the new one has been checked. Store Apple signing credentials separately; do not add them to source control or backups you share.

**Phone backup.** Before native app updates or signing changes, connect the iPhone by USB and make a local computer backup. Apple Devices > General offers “Back up all of the data on your [device] to this computer” and Backup Now. Encrypt the backup if desired and retain its password; Apple cannot use an encrypted backup without that password. Apple's [Windows backup and restore instructions](https://support.apple.com/guide/devices-windows/mchla3c8ed03/windows) explain those controls. Verify the backup's completion/date in Manage Backups.

For independently recoverable music, your PC copy of every track remains essential. A phone backup does not replace the Xcode source, a valid signing profile, or a verified copy of the music library. In the phone's Transfer tab, use **Export playlist backup** to save `MusicCloud-playlists.json` under On My iPhone > MusicCloud, then save that shared file to the PC over USB as described in `USB-AND-INSTALL.md`. Keep it alongside the matching audio paths. The export contains favorites and ordered playlists, not audio. Native working state remains private at `Application Support/MusicCloud/library-state.json`; its export makes playlist recovery possible without a whole-device restore.

Deleting an app can delete its shared files and their backup entries; see [Apple's file-sharing and deletion guidance](https://support.apple.com/119585). Back up before removing MusicCloud, changing its bundle identifier, or resetting a device.

## Change the app safely

1. Stop the desktop manager and copy the working project and data to a dated backup on another drive.
2. Make the code change in a separate copy or source-control branch. Keep the previous working source.
3. Run the checks included with the project. Read any errors; a passing syntax test does not establish iPhone playback.
4. Test the desktop manager with a small library: import, search, playback, playlist editing, and persistence after restart.
5. Build the native app on a compatible Mac or, after GitHub setup is authorized, run **Build iPhone app** from `.github/workflows/build-iphone.yml` in your private repository. Use only its included free standard-runner allowance; paid overage is not allowed, and no payment method needs to be added. The **MusicCloud-unsigned-ipa** artifact contains **MusicCloud-unsigned.ipa**, which must still be signed/installed by AltServer on Windows. With a local Mac, prefer the simulator for an initial visual check, then test the physical iPhone by USB with the same signing identity.
6. Before using the changed app with your main library, perform the offline and data-preservation checks in `USB-AND-INSTALL.md`.
7. Keep both the working source and backups until the updated version has been used successfully.

Changing the displayed app name does not require changing its bundle identifier. Treat a bundle identifier change as a separate app installation with separate storage. Do not delete the installed app simply because Xcode asks for a new provisioning profile.

## Recover from a bad update

For a desktop problem, stop the manager, keep a copy of the damaged/current data for inspection, and restore the previous project and data together from a known-good backup. Restart with the same documented command and test a small selection of tracks before importing more files.

For an iPhone app-code problem, build the previous known-good source and sign/install it using the same Apple Account and app identity. Confirm the phone's existing files before doing anything destructive. If local tracks are missing, reinstall a valid signed build if necessary, then copy the retained PC music files back over USB. Restore `MusicCloud-playlists.json` through the phone's **Restore playlist backup** action, reviewing its replace confirmation; matching relative audio paths restore playlist membership. The desktop audio export does not contain phone playlists. A whole-device Restore Backup affects the phone beyond MusicCloud; use Apple's documented restore procedure only when you intend that wider restore.

If a file becomes corrupt, preserve the original and try a known-good copy rather than renaming an unsupported format to another extension. Keep at least one backup disconnected while editing or cleaning the library.

## Verify privacy after changes

Keep the desktop manager bound to its documented loopback address and avoid adding public hosting or port forwarding. Keep Wi-Fi syncing disabled in Apple Devices for the cable workflow. When changing code or adding dependencies, inspect any new network requests, account requirements, and license terms; the supplied design needs none of those for local playback.

The app can avoid its own networking while the phone or computer still uses Apple's services for provisioning, operating-system updates, or configured backups. Review device backup settings if your own policy is to keep music out of cloud backups. The supplied app does not silently change those settings.

## Record your checks

Keep a simple text log with app version, build date, desktop runtime version, iPhone/iOS version, Xcode/macOS version, backup date, and which acceptance checks passed. Record unresolved problems and the exact file/format involved. This is more useful than assuming a build that compiles has passed a real device test.

No physical iPhone installation, Lock Screen behavior, cable transfer, or signing renewal has been verified merely by generating this source package. Complete those checks on your own device before treating it as your only music copy.
