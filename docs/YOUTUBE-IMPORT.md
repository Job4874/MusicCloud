# Import your YouTube Music playlist list

MusicCloud's optional metadata adapter retrieves playlist **metadata**: names, order, titles, artists, IDs, and availability when YouTube returns those fields. This metadata path does not retrieve audio. Import your authorized local audio files separately for fully offline playback, then use USB transfer as described in `USB-AND-INSTALL.md`.

The adapter uses [ytmusicapi](https://github.com/sigma67/ytmusicapi), an unofficial Python client. The checked stable version is **1.12.3**, as listed in the [project's releases](https://github.com/sigma67/ytmusicapi/releases), and it requires Python 3.10 or later. The package is free; this workflow needs no paid service, API subscription, cloud hosting, or Google Cloud billing setup. Network access is needed only while retrieving metadata. Account access and a real playlist export have not been verified until you complete local authentication and run it successfully.

## Public playlists: export without credentials

For a public or accessible unlisted playlist, try the public route first. From the MusicCloud project folder, create the optional local environment and export to a folder outside the source package:

```powershell
$ytTools = Join-Path $env:LOCALAPPDATA 'MusicCloud\ytmusic-tools'
$ytExports = Join-Path $env:LOCALAPPDATA 'MusicCloud\exports'
New-Item -ItemType Directory -Force -Path $ytExports | Out-Null
py -3 -m venv $ytTools
$ytPython = Join-Path $ytTools 'Scripts\python.exe'
& $ytPython -m pip install 'ytmusicapi==1.12.3'
& $ytPython .\importer\export_playlist.py --public --playlist 'https://music.youtube.com/playlist?list=YOUR_PLAYLIST_ID' --output (Join-Path $ytExports 'my-playlist.json')
```

Replace the URL with your playlist. `--public` sends no authentication file and cannot read private account lists such as Liked Songs. Use `--auth` only when your own account access is necessary. The two flags are mutually exclusive.

## Open the report in the desktop app

1. Start MusicCloud and select **YouTube playlists** in the sidebar.
2. Choose **Import playlist JSON** and select the generated playlist manifest, up to 100 MB. The browser rejects authentication/token JSON before uploading and removes fields outside the metadata schema.
3. Open the imported report. **Extracted entries** and the **reported** source total are shown separately. Review the count status, notes, and every ordered row. Search covers titles, artists, and video IDs. Large reports use explicit Previous/Next entry pages; filtering searches the entire report.
4. Add your authorized audio files with **Add music**. Choose **Refresh matches** to compare current local metadata. A unique exact normalized title plus an exact artist match can attach local audio. Multiple candidates are marked ambiguous; missing and unavailable rows remain visible. Only a matched local file receives a **Play local file** control.
5. Choose **Create local playlist** to add uniquely matched local audio in source order. Review the preview of skipped entries and repeated matches. Duplicate rows remain in the report, while the playable local playlist includes each audio file once. No audio is downloaded or guessed.
6. Choose **Download JSON report** to save a sanitized copy containing entries, completeness notes, and local matching results. Reimporting the same source playlist updates its report in place. Local matching does not alter the source YouTube playlist.

Imported reports are stored in `desktop/data/playlist-catalogs.json` (or your configured data directory). Include that file in local backups. Reports and their matches stay on this computer; the phone's own playlists are maintained separately.

## Keep authentication on this computer

Use your own signed-in YouTube Music session. Its cookie/header file can authorize account requests: keep it private. Do not paste tokens, cookies, request headers, API keys, or the authentication file into chat. Do not put them in MusicCloud's project/output folders, a ZIP, GitHub, a screenshot, or a browser upload to MusicCloud. The desktop app needs only the sanitized playlist manifest.

The recommended credential location is `%LOCALAPPDATA%\MusicCloud\private\auth.json`, outside the source package. Keep it out of shared backups. Delete the local file when you no longer need the integration; deleting a copy does not itself revoke the underlying browser session.

A bearer token and an API key are different credentials; neither should be substituted blindly into a browser-auth file. Google's official [YouTube Data API authentication guide](https://developers.google.com/youtube/data/guides/authentication) uses OAuth for private account data. This adapter's browser route instead follows ytmusicapi's documented session-header setup and requires no developer API key.

## Create your local browser-auth file

Run these commands in your own PowerShell window. They create the optional Python environment and credential directory outside the MusicCloud source tree:

```powershell
$ytTools = Join-Path $env:LOCALAPPDATA 'MusicCloud\ytmusic-tools'
$ytPrivate = Join-Path $env:LOCALAPPDATA 'MusicCloud\private'
New-Item -ItemType Directory -Force -Path $ytPrivate | Out-Null
py -3 -m venv $ytTools
$ytPython = Join-Path $ytTools 'Scripts\python.exe'
$ytSetup = Join-Path $ytTools 'Scripts\ytmusicapi.exe'
& $ytPython -m pip install 'ytmusicapi==1.12.3'
& $ytSetup browser --file (Join-Path $ytPrivate 'auth.json')
```

If `py` is unavailable, install a supported Python first or use the full path to your Python executable instead. Do not add billing information to install this free Python package.

When the last command prompts for headers:

1. In your own browser, sign in to [YouTube Music](https://music.youtube.com/) with the account/channel whose playlist you want.
2. Open Developer Tools > Network, filter for `/browse`, then open Library or scroll until an authenticated successful POST request appears.
3. Copy that request's **request headers** using the browser's supported Copy request headers action. Firefox offers this directly; Chrome/Edge may require copying the Request headers section. Follow the project's [browser-specific instructions](https://ytmusicapi.readthedocs.io/en/stable/setup/browser.html) for your browser.
4. Paste the headers only into the local setup prompt. On Windows, finish with Enter, Ctrl+Z, Enter when instructed. The CLI writes the local JSON file; do not print or share it.

The [pinned setup implementation](https://github.com/sigma67/ytmusicapi/blob/1.12.3/ytmusicapi/setup.py) accepts `browser --file PATH` and labels this cookie-based route deprecated. It remains documented in 1.12.3 and may change. If it fails, refresh your own session/configuration using the current project instructions rather than searching for someone else's tokens. Never run a copied browser request as executable code merely to get its headers.

## Export a playlist

From the **MusicCloud project folder**, run the included `importer/export_playlist.py` with the Python environment above. Replace the playlist URL below with your own playlist URL or ID:

```powershell
$ytExports = Join-Path $env:LOCALAPPDATA 'MusicCloud\exports'
New-Item -ItemType Directory -Force -Path $ytExports | Out-Null
$ytAuth = Join-Path $ytPrivate 'auth.json'
& $ytPython .\importer\export_playlist.py --auth $ytAuth --playlist 'https://music.youtube.com/playlist?list=YOUR_PLAYLIST_ID' --output (Join-Path $ytExports 'my-playlist.json')
```

For Liked Songs, use `--liked` in place of `--playlist URL_OR_ID`:

```powershell
& $ytPython .\importer\export_playlist.py --auth $ytAuth --liked --output (Join-Path $ytExports 'liked-songs.json')
```

The adapter refuses authentication files inside the MusicCloud project. It refuses to overwrite an existing output unless you explicitly add `--overwrite`; back up the previous export first. Store sanitized exports outside the deliverable ZIP. A supplied playlist URL provides an ID; the adapter contacts its fixed service endpoint rather than fetching an arbitrary supplied host.

The authentication JSON is not the playlist JSON. Import only the generated metadata manifest into MusicCloud. Each playlist occurrence must remain a separate row so duplicates and original order survive. Unavailable entries remain placeholders when the service exposes them. Matching a row to a local audio file does not grant rights to a recording or download it.

## Check whether the export is complete

The underlying calls use `limit=None`, which requests all continuation pages rather than the default first 100 tracks. The project documents this for [playlist contents](https://ytmusicapi.readthedocs.io/en/stable/reference/playlists.html) and [library playlists](https://ytmusicapi.readthedocs.io/en/stable/reference/library.html). These requests are made sequentially; a request error or explicit safety limit must be shown as an incomplete result.

Review the exported count and audit warnings before relying on the result. An advertised playlist count, when present, can be compared with returned entries; a missing count is unknown. A matching count is useful evidence, not proof that YouTube exposed every original item.

| Exit code | Meaning |
| --- | --- |
| `0` | Export written and returned/advertised counts match, with no detected completeness issue. |
| `2` | Export written with a count mismatch; review the partial result. |
| `3` | Export written, but completeness cannot be established. |
| `1` | Fetch or local failure; no new export is written. |

The local adapter bounds requests and elapsed time to stop runaway pagination. Reaching a bound is a failure to complete the fetch, not evidence that the playlist has ended. Successful exports preserve the returned order and duplicate entries; keep their audit data with the metadata.

The upstream [1.12.3 playlist parser](https://github.com/sigma67/ytmusicapi/blob/1.12.3/ytmusicapi/parsers/playlists.py) can omit deleted entries, and YouTube may hide metadata. The adapter preserves observed deleted/unavailable positions where its pinned compatibility wrapper can do so and reports unrecognized rows. It cannot reconstruct titles, IDs, or positions that YouTube never returns. It must not invent missing songs or report a successful complete import after an error. Keep your source playlist unchanged and inspect reported mismatches.

## Authentication alternatives and maintenance

ytmusicapi also documents an [OAuth route](https://ytmusicapi.readthedocs.io/en/stable/setup/oauth.html): it needs your own OAuth client ID and secret, an `oauth.json` token file, and `OAuthCredentials` passed to `YTMusic`. This differs from browser headers and from a simple API key. The adapter's authenticated route expects the local browser file; do not paste OAuth tokens into it without an explicit implementation change. Its public route needs no authentication.

For a previously collected list of public playlist IDs, `importer/batch_export.py` accepts a discovery JSON with `complete` and a `playlists` array of `{playlistId, title, reportedCount}` records:

```powershell
& $ytPython .\importer\batch_export.py --public --discovery 'YOUR-DISCOVERY.json' --output-dir $ytExports --workers 2 --timeout 180
```

The batch writes one ID-named manifest per successful export and an `IMPORT-REPORT.json` audit covering every discovered playlist. Import the individual playlist manifests into the desktop app; the batch audit is not a playlist manifest. The batch uses at most two processes, finite per-playlist deadlines, and no automatic retries. Private account-only lists are labeled as requiring authentication. `--refresh` explicitly regenerates existing outputs; preserve a backup first. A discovery list marked incomplete cannot establish that every account playlist was discovered.

Keep the version pinned until updated parser and pagination tests pass. Recheck the primary project documentation when YouTube changes its responses. The [project FAQ](https://ytmusicapi.readthedocs.io/en/stable/faq.html) notes that server pagination can return more than a requested finite limit and that rate limits exist. Stop and retry later when rate-limited rather than repeatedly hammering the service. This metadata integration remains unofficial and can stop working independently of MusicCloud's offline player.

For maintainers, the public read methods used by the adapter are:

```python
from ytmusicapi import YTMusic

yt = YTMusic(str(auth_path))
playlist = yt.get_playlist(playlist_id, limit=None, related=False, suggestions_limit=0)
liked = yt.get_liked_songs(limit=None)
library_playlist_summaries = yt.get_library_playlists(limit=None)
```

`get_liked_songs` forwards its limit to the `LM` playlist in the pinned implementation; its annotation still says `int`. Library summaries are not full playlist entries: fetch each summary's playlist ID separately to obtain its tracks. The included CLI exports one selected playlist or Liked Songs per invocation. Do not call write methods to read or export metadata.

## Read an already captured browser playlist locally

`importer/har_playlist.py` reads playlist JSON responses from a manually exported **sanitized HAR**. It uses only Python's standard library, makes no network requests, does not read or replay authentication headers/cookies, and writes only allowlisted playlist metadata. Capture only an account you are authorized to read. A sanitized HAR can still contain private browsing/account data: keep it outside MusicCloud, GitHub, ZIPs, chat and screenshots.

Load the playlist normally in the browser, scroll to load further entries, and use the browser developer tools' sanitized HAR export. Preserve the initial response as well as later page responses. Link multiple local captures with repeated `--har` arguments:

```powershell
py -3 importer\har_playlist.py --har "C:\private\playlist-first.har" --har "C:\private\playlist-later.har" --playlist LM --output "$env:USERPROFILE\Documents\liked-music.json"
```

If the response omits its exact total, `--reported-count` can supply the count you observed in the playlist UI. Existing metadata outputs require `--overwrite`. The helper accepts pages only when the captured initial request and response identify the playlist, then links captured continuations in order. It preserves duplicate and unavailable rows and reports an absent next page. Unknown response shapes, a count mismatch, or an incomplete page chain must never be reported as complete. It does not execute captured HTML or scripts.

The final captured page can have no continuation marker while the returned row count remains below the advertised total. Keep that result explicitly partial; do not invent the missing entries, their positions or an absence reason. Metadata counts describe playlist records, not acquired recordings or playable local files. A public fetch failure does not establish that a playlist is private.

Local account-specific evidence belongs with personal manifests and import audits outside the distributable source. In this workspace, the separate `playlist-exports/VERIFICATION.md` records the current observed counts; that folder and browser captures are excluded from source/portable archives and repository payloads.

Documentation checked October 20, 2026. Automated fixture checks verify adapter behavior and do not establish a complete account export.
