"""Local-only metadata extraction from a browser's sanitized playlist HAR.

No network client is imported. Headers/cookies are never consulted, replayed,
logged or exported. Continuation values are compared only in memory to connect
captured playlist pages; they never appear in a manifest or console output.
"""

import argparse
import base64
from collections import Counter
import datetime
import json
import os
from pathlib import Path
import re
import sys
import tempfile
from urllib.parse import urlsplit

from musiccloud_manifest import ManifestError, normalize_playlist, playlist_id, validate_manifest

MAX_HAR_BYTES = 256 * 1024 * 1024
VIDEO_ID = re.compile(r"^[A-Za-z0-9_-]{11}$")
COUNT = re.compile(r"(?<![\d,])([\d]+(?:,[\d]{3})*)\s+(?:songs?|tracks?)\b", re.IGNORECASE)


def walk(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from walk(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk(child)


def nested(value, *keys):
    for key in keys:
        if not isinstance(value, dict):
            return None
        value = value.get(key)
    return value


def text(value):
    if isinstance(value, str):
        return value
    if isinstance(value, dict):
        if isinstance(value.get("simpleText"), str):
            return value["simpleText"]
        runs = value.get("runs")
        if isinstance(runs, list):
            return "".join(run.get("text", "") for run in runs if isinstance(run, dict) and isinstance(run.get("text"), str))
    return ""


def page_identity(response, identifier):
    valid = {identifier, "VL" + identifier}
    return any(node.get("playlistId") in valid or node.get("targetId") in valid for node in walk(response))


def header_metadata(response):
    title = ""
    count = None
    for node in walk(response):
        header = node.get("musicResponsiveHeaderRenderer") or node.get("musicDetailHeaderRenderer")
        if not isinstance(header, dict):
            continue
        title = title or text(header.get("title"))
        for key in ("subtitle", "secondSubtitle", "subtitleText"):
            match = COUNT.search(text(header.get(key)))
            if match:
                count = int(match[1].replace(",", ""))
    return title, count


def continuation_from(items):
    """Read only a page's explicit continuation marker, never account tokens."""
    for item in items:
        marker = item.get("continuationItemRenderer") if isinstance(item, dict) else None
        endpoint = marker.get("continuationEndpoint") if isinstance(marker, dict) else None
        for node in walk(endpoint):
            command = node.get("continuationCommand")
            if not isinstance(command, dict) or command.get("request") not in {None, "CONTINUATION_REQUEST_TYPE_BROWSE"}:
                continue
            token = command.get("token")
            if isinstance(token, str) and token:
                return token
    return None


def initial_page(response, identifier=None):
    shelves = [node["musicPlaylistShelfRenderer"] for node in walk(response) if isinstance(node.get("musicPlaylistShelfRenderer"), dict)]
    if identifier is not None:
        matching = [shelf for shelf in shelves if shelf.get("targetId") in {identifier, "VL" + identifier}]
        if matching:
            shelves = matching
        elif len(shelves) > 1:
            # Do not guess between playlist/recommendation shelves after a UI change.
            return None
    for shelf in shelves:
        items = shelf.get("contents")
        if isinstance(items, list):
            next_page = continuation_from(items)
            if next_page is None:
                for marker in shelf.get("continuations", []):
                    candidate = nested(marker, "nextContinuationData", "continuation")
                    if isinstance(candidate, str) and candidate:
                        next_page = candidate
                        break
            return items, next_page
    return None


def continuation_page(response):
    for node in walk(response):
        action = node.get("appendContinuationItemsAction")
        items = action.get("continuationItems") if isinstance(action, dict) else None
        if isinstance(items, list):
            return items, continuation_from(items)
    for node in walk(response):
        shelf = node.get("musicPlaylistShelfContinuation")
        if isinstance(shelf, dict) and isinstance(shelf.get("contents"), list):
            items = shelf["contents"]
            next_page = continuation_from(items)
            for marker in shelf.get("continuations", []):
                candidate = nested(marker, "nextContinuationData", "continuation")
                if isinstance(candidate, str) and candidate:
                    next_page = candidate
                    break
            return items, next_page
    return None


def track_from_renderer(renderer):
    columns = []
    for column in renderer.get("flexColumns", []):
        value = nested(column, "musicResponsiveListItemFlexColumnRenderer", "text")
        columns.append(value if isinstance(value, dict) else {})
    title = text(columns[0]) if columns else ""
    artist_runs = columns[1].get("runs", []) if len(columns) > 1 else []
    names = []
    for run in artist_runs:
        if not isinstance(run, dict) or not isinstance(run.get("text"), str):
            continue
        name = run["text"].strip()
        artist_endpoint = nested(run, "navigationEndpoint", "browseEndpoint")
        if name and (isinstance(artist_endpoint, dict) or not re.fullmatch(r"[\s·•,&/|–—-]+", name)):
            names.append(name)
    video = nested(renderer, "overlay", "musicItemThumbnailOverlayRenderer", "content", "musicPlayButtonRenderer", "playNavigationEndpoint", "watchEndpoint", "videoId")
    if video is None:
        video = nested(renderer, "navigationEndpoint", "watchEndpoint", "videoId")
    if video is None and columns:
        for run in columns[0].get("runs", []):
            candidate = nested(run, "navigationEndpoint", "watchEndpoint", "videoId")
            if candidate:
                video = candidate
                break
    if video is None:
        for node in walk(renderer.get("menu", {})):
            candidate = node.get("removedVideoId")
            if isinstance(candidate, str) and VIDEO_ID.fullmatch(candidate):
                video = candidate
                break
    if not isinstance(video, str) or not VIDEO_ID.fullmatch(video):
        video = None
    policy = renderer.get("musicItemRendererDisplayPolicy")
    available = False if policy == "MUSIC_ITEM_RENDERER_DISPLAY_POLICY_GREY_OUT" or video is None else True
    return {"title": title or "Deleted or unavailable entry", "artists": [{"name": name} for name in names], "videoId": video, "isAvailable": available}


def parse_items(items):
    tracks = []
    uncertain = False
    for item in items:
        if not isinstance(item, dict):
            uncertain = True
            continue
        renderer = item.get("musicResponsiveListItemRenderer")
        if isinstance(renderer, dict):
            tracks.append(track_from_renderer(renderer))
        elif "continuationItemRenderer" not in item or continuation_from([item]) is None:
            uncertain = True
    return tracks, uncertain


def browse_records(hars):
    records = []
    status_counts = Counter()
    unreadable = 0
    captured = 0
    for har in hars:
        entries = nested(har, "log", "entries")
        if not isinstance(entries, list):
            raise ManifestError("The local file is not a HAR with captured entries.")
        captured += len(entries)
        for entry in entries:
            if not isinstance(entry, dict):
                continue
            request = entry.get("request", {})
            parsed = urlsplit(request.get("url", ""))
            if parsed.hostname != "music.youtube.com" or parsed.path != "/youtubei/v1/browse":
                continue
            response = entry.get("response", {})
            status = response.get("status")
            status_counts[str(status) if type(status) is int else "unknown"] += 1
            if type(status) is not int or not 200 <= status < 300:
                continue
            try:
                body = nested(response, "content", "text")
                if not isinstance(body, str) or not body:
                    raise ValueError
                if nested(response, "content", "encoding") == "base64":
                    body = base64.b64decode(body, validate=True).decode("utf-8")
                if body.startswith(")]}'"):
                    body = body.partition("\n")[2]
                payload = json.loads(body)
                request_body = json.loads(nested(request, "postData", "text") or "{}")
                if not isinstance(payload, dict) or not isinstance(request_body, dict):
                    raise ValueError
            except (ValueError, UnicodeError, TypeError):
                unreadable += 1
                continue
            records.append({"payload": payload, "browseId": request_body.get("browseId"), "continuation": request_body.get("continuation")})
    return records, {"capturedRequestCount": captured, "browseResponseStatusCounts": dict(status_counts), "unreadableBrowseResponses": unreadable}


def extract_playlist(hars, identifier, reported_count=None):
    identifier = playlist_id(identifier)
    if reported_count is not None and (type(reported_count) is not int or reported_count < 0):
        raise ManifestError("The observed playlist count must be a nonnegative integer.")
    records, stats = browse_records(hars)
    candidates = []
    valid_ids = {identifier, "VL" + identifier}
    for index, record in enumerate(records):
        if record["browseId"] not in valid_ids or not page_identity(record["payload"], identifier):
            continue
        first = initial_page(record["payload"], identifier)
        if first is None:
            continue
        title, response_count = header_metadata(record["payload"])
        items, next_page = first
        tracks, uncertain = parse_items(items)
        page_count = 1
        seen = set()
        last_index = index
        missing_page = False
        loop = False
        while next_page:
            if next_page in seen:
                loop = True
                break
            seen.add(next_page)
            selected = None
            for candidate_index in range(last_index + 1, len(records)):
                if records[candidate_index]["continuation"] == next_page:
                    page = continuation_page(records[candidate_index]["payload"])
                    if page is not None:
                        selected = candidate_index, page
                        break
            if selected is None:
                missing_page = True
                break
            last_index, (items, next_page) = selected
            parsed_tracks, page_uncertain = parse_items(items)
            tracks.extend(parsed_tracks)
            uncertain = uncertain or page_uncertain
            page_count += 1
        candidates.append({"tracks": tracks, "title": title, "responseCount": response_count, "pages": page_count, "uncertain": uncertain, "missing": missing_page, "loop": loop, "index": index})
    if not candidates:
        raise ManifestError("No captured playlist response explicitly identifies the requested list. No manifest was written.")
    chosen = max(candidates, key=lambda candidate: (len(candidate["tracks"]), candidate["index"]))
    count = chosen["responseCount"] if chosen["responseCount"] is not None else reported_count
    warnings = [f"Metadata extracted locally from {len(hars)} browser HAR capture(s) and {chosen['pages']} linked playlist response page(s). No requests, headers, cookies or authentication values were replayed or exported."]
    if chosen["responseCount"] is None and reported_count is not None:
        warnings.append("The reported total was supplied from the observed playlist UI because no exact response-header total was available.")
    mismatch = reported_count is not None and chosen["responseCount"] is not None and reported_count != chosen["responseCount"]
    if mismatch:
        warnings.append("The observed UI total differs from the captured response total; the playlist may have changed during capture.")
    if chosen["missing"]:
        warnings.append("A captured page advertises another playlist page that is absent from these HAR files. Load more entries in the browser and export another sanitized capture.")
    if chosen["loop"]:
        warnings.append("A repeated continuation marker was detected. Page linking stopped without replaying it.")
    if count is not None and len(chosen["tracks"]) < count and not chosen["missing"] and not chosen["loop"]:
        warnings.append(f"The captured page chain ended after {chosen['pages']} page(s) with {len(chosen['tracks'])} track rows and no further continuation marker. The remaining advertised entries were not present in the captured rows; their identities and positions were not invented.")
    if stats["unreadableBrowseResponses"]:
        warnings.append("Some captured browse responses were missing readable JSON; only identified readable playlist pages were used.")
    manifest = normalize_playlist({"title": chosen["title"] or ("Liked Music" if identifier == "LM" else "Captured YouTube Music playlist"), "trackCount": count, "tracks": chosen["tracks"]}, identifier, warnings, chosen["uncertain"])
    if chosen["missing"] or chosen["loop"] or mismatch:
        manifest["complete"] = False
    validate_manifest(manifest)
    return manifest, {**stats, "identifiedPlaylistPages": chosen["pages"], "extractedCount": manifest["extractedCount"], "reportedCount": count, "complete": manifest["complete"], "missingNextPage": chosen["missing"]}


def publish_json(target, value, overwrite=False):
    target = Path(target).resolve()
    if not target.parent.is_dir():
        raise ManifestError("Create the output folder first.")
    descriptor, temporary = tempfile.mkstemp(prefix=".musiccloud-har-", suffix=".tmp", dir=target.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as handle:
            json.dump(value, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        try:
            if overwrite:
                os.replace(temporary, target)
            elif os.name == "nt":
                os.rename(temporary, target)
            else:
                os.link(temporary, target)
        except FileExistsError:
            raise ManifestError("The output exists and was preserved. Explicitly use --overwrite to replace a metadata manifest.") from None
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def update_report(target, manifest, manifest_path):
    target = Path(target)
    report = json.loads(target.read_text(encoding="utf-8"))
    if report.get("schema") != "musiccloud.import-report.v1" or not isinstance(report.get("playlists"), list):
        raise ManifestError("The existing account audit has an unsupported format.")
    matches = [entry for entry in report["playlists"] if entry.get("playlistId") == manifest["playlistId"]]
    if len(matches) != 1:
        raise ManifestError("The account audit must contain one entry for this playlist.")
    entry = matches[0]
    entry.update({"status": "complete" if manifest["complete"] is True else "partial" if manifest["complete"] is False else "unverified", "reportedCount": manifest["reportedCount"], "extractedCount": manifest["extractedCount"], "complete": manifest["complete"], "manifest": Path(manifest_path).name, "error": None, "provenance": "Local browser HAR playlist response metadata; no authentication replay."})
    report["complete"] = report.get("discoveryComplete") is True and all(item.get("status") == "complete" for item in report["playlists"])
    report["updatedAt"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    report["summary"] = dict(sorted(Counter(item.get("status", "unknown") for item in report["playlists"]).items()))
    publish_json(target, report, overwrite=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description="Extract only playlist metadata from local sanitized HAR files. No network access or authentication replay.")
    parser.add_argument("--har", action="append", required=True, type=Path, help="Local sanitized HAR outside the MusicCloud project; repeat for later captures.")
    parser.add_argument("--playlist", required=True, help="Playlist ID, for example LM.")
    parser.add_argument("--reported-count", type=int, help="Exact song count observed in the playlist UI.")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--overwrite", action="store_true")
    parser.add_argument("--report", type=Path, help="Optionally update this playlist's entry in an existing import audit.")
    args = parser.parse_args(argv)
    try:
        project = Path(__file__).resolve().parents[1]
        inputs = [value.resolve() for value in args.har]
        if any(value.is_relative_to(project) for value in inputs):
            raise ManifestError("Keep HAR files outside the application/source folder; they can contain private browser data.")
        if args.output.resolve() in inputs or args.report and args.report.resolve() in inputs:
            raise ManifestError("A HAR input cannot be used as an output.")
        if args.report and args.output.resolve() == args.report.resolve():
            raise ManifestError("The playlist output and account audit must be separate files. Both were preserved.")
        hars = []
        for value in inputs:
            if not value.is_file() or value.stat().st_size > MAX_HAR_BYTES:
                raise ManifestError("Use local HAR files no larger than 256 MB each.")
            hars.append(json.loads(value.read_text(encoding="utf-8-sig")))
        manifest, stats = extract_playlist(hars, args.playlist, args.reported_count)
        publish_json(args.output, manifest, args.overwrite)
        if args.report:
            update_report(args.report, manifest, args.output)
        print(json.dumps(stats, sort_keys=True))
        return 0 if manifest["complete"] is True else 2 if manifest["complete"] is False else 3
    except ManifestError as error:
        print(f"MusicCloud HAR import: {error}", file=sys.stderr)
    except Exception:
        print("MusicCloud HAR import failed while reading local capture/metadata files. No raw request details were logged.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
