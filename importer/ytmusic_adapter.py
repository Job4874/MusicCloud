"""Pinned ytmusicapi adapter. No credentials or raw responses leave this module."""

import importlib.metadata
import time
from contextlib import contextmanager

SUPPORTED_VERSION = "1.12.3"


class AdapterError(RuntimeError):
    pass


@contextmanager
def preserve_unavailable_rows(parser_module, mixin_module):
    """Retain deleted rows the pinned parser otherwise omits; restore all hooks."""
    original_item = parser_module.parse_playlist_item
    original_parser_items = parser_module.parse_playlist_items
    original_mixin_items = mixin_module.parse_playlist_items
    original_audio = getattr(mixin_module, "parse_audio_playlist", None)
    audit = {"deleted": 0, "unknown": set(), "synthetic_count": False}

    def retained_item(*args, **kwargs):
        result = original_item(*args, **kwargs)
        if result is not None:
            return result
        audit["deleted"] += 1
        return {"videoId": None, "title": "Deleted or unavailable entry", "artists": [], "isAvailable": False}

    def audited_items(results, *args, **kwargs):
        if isinstance(results, list):
            for item in results:
                if isinstance(item, dict):
                    kinds = set(item) - {"musicResponsiveListItemRenderer", "continuationItemRenderer"}
                    audit["unknown"].update(kinds)
                else:
                    audit["unknown"].add("unrecognized-row")
        return original_parser_items(results, *args, **kwargs)

    def audited_audio(*args, **kwargs):
        # This pinned helper calculates trackCount = len(tracks), not a server total.
        audit["synthetic_count"] = True
        return original_audio(*args, **kwargs)

    parser_module.parse_playlist_item = retained_item
    parser_module.parse_playlist_items = audited_items
    mixin_module.parse_playlist_items = audited_items
    if original_audio is not None:
        mixin_module.parse_audio_playlist = audited_audio
    try:
        yield audit
    finally:
        parser_module.parse_playlist_item = original_item
        parser_module.parse_playlist_items = original_parser_items
        mixin_module.parse_playlist_items = original_mixin_items
        if original_audio is not None:
            mixin_module.parse_audio_playlist = original_audio


def fetch_playlist(auth_path, identifier, liked=False, client_factory=None, modules=None, request_limit=10000, seconds_limit=900):
    """Fetch all continuations with finite request/time bounds and no adapter retries."""
    if client_factory is None:
        try:
            if importlib.metadata.version("ytmusicapi") != SUPPORTED_VERSION:
                raise AdapterError(f"Install the pinned ytmusicapi {SUPPORTED_VERSION}; its parser interface is required.")
            from ytmusicapi import YTMusic
            from ytmusicapi.parsers import playlists as parser_module
            from ytmusicapi.mixins import playlists as mixin_module
        except importlib.metadata.PackageNotFoundError:
            raise AdapterError("Install importer/requirements.txt in the private Python environment first.") from None
        except ImportError:
            raise AdapterError("The installed ytmusicapi does not match the supported parser interface.") from None
        client_factory = YTMusic
        modules = parser_module, mixin_module
    if modules is None:
        raise AdapterError("The parser audit modules are missing.")
    try:
        # The pinned release's default session uses a 30-second request timeout.
        client = client_factory() if auth_path is None else client_factory(str(auth_path))
        original_request = client._send_request
        start = time.monotonic()
        requests = 0
        seen_continuations = set()

        def bounded_request(*args, **kwargs):
            nonlocal requests
            requests += 1
            if requests > request_limit or time.monotonic() - start > seconds_limit:
                raise AdapterError("Export stopped at its request/time safety limit; no manifest was written. Try the playlist again later.")
            body = args[1] if len(args) > 1 else kwargs.get("body")
            continuation = body.get("continuation") if isinstance(body, dict) else None
            if isinstance(continuation, str) and continuation:
                if continuation in seen_continuations:
                    raise AdapterError("The service repeated a playlist continuation token. Export stopped to prevent a pagination loop; no manifest was written.")
                seen_continuations.add(continuation)
            return original_request(*args, **kwargs)

        client._send_request = bounded_request
        with preserve_unavailable_rows(*modules) as audit:
            payload = client.get_liked_songs(limit=None) if liked else client.get_playlist(identifier, limit=None, related=False, suggestions_limit=0)
        warnings = []
        if audit["synthetic_count"]:
            payload = dict(payload)
            payload["trackCount"] = None
            warnings.append("The upstream audio-playlist parser derived its count from returned entries rather than a reported total. Completeness cannot be independently verified.")
        if audit["deleted"]:
            warnings.append(f"Retained {audit['deleted']} deleted/unavailable rows that the upstream parser normally omits.")
        if audit["unknown"]:
            # Renderer names are implementation details, not request headers or account data.
            warnings.append("Unfamiliar playlist row formats were observed; verify this export against YouTube Music.")
        return payload, warnings, bool(audit["unknown"])
    except AdapterError:
        raise
    except Exception as error:
        # Upstream exception strings can contain request details. Never print them.
        reason = {
            "ReadTimeout": "A service request timed out.",
            "ConnectTimeout": "The service connection timed out.",
            "ConnectionError": "The connection to the service failed.",
            "SSLError": "The secure service connection failed.",
            "KeyError": "The service response did not match the expected playlist format.",
            "IndexError": "The service response did not match the expected playlist format.",
            "JSONDecodeError": "The service did not return readable playlist data.",
            "YTMusicServerError": "The service refused the playlist request.",
            "YTMusicUserError": "The account or playlist could not be accessed.",
        }.get(type(error).__name__, "The service could not be read.")
        raise AdapterError(f"YouTube Music export failed. {reason} Check your connection, playlist access, and local browser authentication if required. No manifest was written.") from None
