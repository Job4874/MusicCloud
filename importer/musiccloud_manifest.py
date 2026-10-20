"""Pure, credential-free playlist normalization. This module never makes requests."""

import re
from collections.abc import Mapping
from urllib.parse import parse_qs, urlparse

SCHEMA = "musiccloud.playlist.v1"
VIDEO_ID = re.compile(r"^[A-Za-z0-9_-]{11}$")
PLAYLIST_ID = re.compile(r"^[A-Za-z0-9_-]{2,200}$")


class ManifestError(ValueError):
    pass


def playlist_id(value):
    """Accept a playlist ID or a YouTube playlist URL, never arbitrary request URLs."""
    if not isinstance(value, str):
        raise ManifestError("Provide a playlist ID or a YouTube playlist URL.")
    value = value.strip()
    if "://" in value:
        parsed = urlparse(value)
        if parsed.scheme != "https" or parsed.hostname not in {
            "music.youtube.com", "www.youtube.com", "youtube.com"
        } or parsed.username or parsed.password or parsed.port not in {None, 443}:
            raise ManifestError("Use an https://music.youtube.com/playlist?list=... URL or a playlist ID.")
        values = parse_qs(parsed.query).get("list", [])
        if len(values) != 1:
            raise ManifestError("The playlist URL needs one list parameter.")
        value = values[0]
    if not PLAYLIST_ID.fullmatch(value):
        raise ManifestError("The playlist ID is invalid.")
    return value


def _text(value, default=""):
    return value if isinstance(value, str) else default


def _count(value):
    if isinstance(value, bool):
        return None
    if isinstance(value, int) and value >= 0:
        return value
    if isinstance(value, str) and re.fullmatch(r"\d+(?:,\d{3})*", value.strip()):
        return int(value.replace(",", ""))
    return None


def normalize_playlist(payload, identifier, adapter_warnings=(), uncertain_rows=False):
    """Keep one output entry per returned row, in order, including duplicate IDs."""
    if not isinstance(payload, Mapping) or not isinstance(payload.get("tracks"), list):
        raise ManifestError("The service returned an unexpected playlist format; no manifest was written.")
    identifier = playlist_id(identifier)
    warnings = list(dict.fromkeys(str(warning) for warning in adapter_warnings))
    reported = _count(payload.get("trackCount"))
    entries = []
    unavailable = 0
    for position, raw in enumerate(payload["tracks"], 1):
        if not isinstance(raw, Mapping):
            raw = {}
            warnings.append(f"Entry {position} had an unrecognized format and was retained as a placeholder.")
        video_id = raw.get("videoId")
        if not isinstance(video_id, str) or not VIDEO_ID.fullmatch(video_id):
            video_id = None
        artists = raw.get("artists", [])
        if not isinstance(artists, list):
            artists = []
        names = []
        for artist in artists:
            name = artist.get("name") if isinstance(artist, Mapping) else artist
            if isinstance(name, str) and name:
                names.append(name)
        available = raw.get("isAvailable")
        if not isinstance(available, bool):
            available = raw.get("available")
        if not isinstance(available, bool):
            available = None if video_id else False
        if not video_id:
            available = False
        if available is False:
            unavailable += 1
        entries.append({
            "position": position,
            "title": _text(raw.get("title"), "Deleted or unavailable entry") or "Untitled entry",
            "artists": names,
            "videoId": video_id,
            "url": f"https://music.youtube.com/watch?v={video_id}" if video_id else None,
            "available": available,
        })
    extracted = len(entries)
    if reported is None:
        complete = None
        warnings.append("The service did not report an exact total. Completeness cannot be verified.")
    elif extracted != reported:
        complete = False
        warnings.append(f"Count mismatch: the service reported {reported} entries but returned {extracted}. This manifest is incomplete or the playlist changed during export.")
    elif uncertain_rows:
        complete = None
        warnings.append("An unfamiliar service row was observed. All recognized entries are retained, but completeness cannot be verified.")
    else:
        complete = True
    if unavailable:
        warnings.append(f"{unavailable} unavailable or unidentified entries were retained. No audio was requested.")
    result = {
        "schema": SCHEMA,
        "source": "youtube-music",
        "playlistId": identifier,
        "title": _text(payload.get("title"), "Liked music" if identifier == "LM" else "YouTube Music playlist"),
        "reportedCount": reported,
        "extractedCount": extracted,
        "complete": complete,
        "warnings": list(dict.fromkeys(warnings)),
        "entries": entries,
    }
    validate_manifest(result)
    return result


def validate_manifest(value):
    if not isinstance(value, dict) or value.get("schema") != SCHEMA or value.get("source") != "youtube-music":
        raise ManifestError("Unsupported MusicCloud playlist manifest.")
    if not {"playlistId", "title", "reportedCount", "extractedCount", "complete", "warnings", "entries"}.issubset(value):
        raise ManifestError("Required manifest fields are missing.")
    playlist_id(value.get("playlistId"))
    if not isinstance(value.get("title"), str) or not isinstance(value.get("warnings"), list) or not all(isinstance(item, str) for item in value["warnings"]):
        raise ManifestError("Invalid playlist metadata.")
    entries = value.get("entries")
    if not isinstance(entries, list) or type(value.get("extractedCount")) is not int or value["extractedCount"] != len(entries):
        raise ManifestError("The manifest entry count does not match its entries.")
    reported = value.get("reportedCount")
    if reported is not None and (type(reported) is not int or reported < 0):
        raise ManifestError("Invalid reported playlist count.")
    if value.get("complete") is not None and type(value.get("complete")) is not bool:
        raise ManifestError("Invalid completeness value.")
    if value.get("complete") is True and (reported is None or reported != len(entries)):
        raise ManifestError("A complete manifest needs matching known counts.")
    if reported is not None and len(entries) < reported and value.get("complete") is not False:
        raise ManifestError("A short manifest must be marked incomplete.")
    for position, entry in enumerate(entries, 1):
        if not isinstance(entry, dict) or entry.get("position") != position or type(entry.get("position")) is not int or not isinstance(entry.get("title"), str) or not isinstance(entry.get("artists"), list) or not all(isinstance(artist, str) for artist in entry["artists"]):
            raise ManifestError("Invalid playlist entry or sequence.")
        if not {"videoId", "url", "available"}.issubset(entry):
            raise ManifestError("Required entry fields are missing.")
        video_id = entry.get("videoId")
        if video_id is not None and (not isinstance(video_id, str) or not VIDEO_ID.fullmatch(video_id)):
            raise ManifestError("Invalid video ID.")
        expected_url = f"https://music.youtube.com/watch?v={video_id}" if video_id else None
        if entry.get("url") != expected_url or entry.get("available") is not None and type(entry.get("available")) is not bool:
            raise ManifestError("Invalid entry URL or availability.")
    return value
