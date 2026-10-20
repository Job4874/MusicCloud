import contextlib
import importlib.util
import io
import json
import os
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from export_playlist import export, main
from batch_export import run_batch
from musiccloud_manifest import ManifestError, normalize_playlist, playlist_id, validate_manifest
from ytmusic_adapter import AdapterError, fetch_playlist, preserve_unavailable_rows


def track(title="Song", video="abcdefghijk", available=True):
    return {"title": title, "videoId": video, "artists": [{"name": "Artist", "id": "private-author-id"}], "isAvailable": available, "feedbackTokens": {"secret": "NEVER_EXPORT_THIS"}, "menu": {"token": "NEVER_EXPORT_THIS"}}


class ManifestTests(unittest.TestCase):
    def test_playlist_urls_and_ids_are_strict(self):
        self.assertEqual(playlist_id("https://music.youtube.com/playlist?list=PLexample_123&feature=share"), "PLexample_123")
        self.assertEqual(playlist_id("PLexample_123"), "PLexample_123")
        for value in ["https://evil.example/?list=PLexample", "https://music.youtube.com.evil.example/?list=PLexample", "file:///private/auth.json", "../auth", "https://music.youtube.com/playlist?list=A&list=B"]:
            with self.assertRaises(ManifestError):
                playlist_id(value)

    def test_preserves_duplicates_order_unavailable_and_allowlists_output(self):
        response = {"title": "My mix", "trackCount": 4, "tracks": [track("First"), track("Duplicate"), track("Unavailable", "lmnopqrstuv", False), None], "authorization": "DO_NOT_WRITE"}
        result = normalize_playlist(response, "PLexample")
        self.assertTrue(result["complete"])
        self.assertEqual([entry["position"] for entry in result["entries"]], [1, 2, 3, 4])
        self.assertEqual([entry["title"] for entry in result["entries"][:3]], ["First", "Duplicate", "Unavailable"])
        self.assertEqual(result["entries"][0]["videoId"], result["entries"][1]["videoId"])
        self.assertFalse(result["entries"][2]["available"])
        self.assertIsNone(result["entries"][3]["videoId"])
        serialized = json.dumps(result)
        self.assertNotIn("NEVER_EXPORT_THIS", serialized)
        self.assertNotIn("DO_NOT_WRITE", serialized)
        self.assertNotIn("private-author-id", serialized)

    def test_count_mismatch_and_unknown_totals_never_claim_complete(self):
        short = normalize_playlist({"title": "Short", "trackCount": 3, "tracks": [track()]}, "PLshort")
        self.assertFalse(short["complete"])
        self.assertEqual(short["extractedCount"], 1)
        self.assertTrue(any("Count mismatch" in warning for warning in short["warnings"]))
        unknown = normalize_playlist({"tracks": [track()]}, "LM")
        self.assertIsNone(unknown["complete"])
        self.assertIsNone(unknown["reportedCount"])
        uncertain = normalize_playlist({"trackCount": 1, "tracks": [track()]}, "PLunknown", uncertain_rows=True)
        self.assertIsNone(uncertain["complete"])
        self.assertFalse(normalize_playlist({"trackCount": 0, "tracks": [track()]}, "PLchanged")["complete"])
        self.assertTrue(normalize_playlist({"trackCount": 0, "tracks": []}, "PLempty")["complete"])

    def test_malformed_payload_fails_and_manifest_validation_catches_bad_urls(self):
        for payload in [None, {}, {"tracks": "not a list"}]:
            with self.assertRaises(ManifestError):
                normalize_playlist(payload, "PLtest")
        result = normalize_playlist({"trackCount": 1, "tracks": [track()]}, "PLtest")
        result["entries"][0]["url"] = "javascript:alert(1)"
        with self.assertRaises(ManifestError):
            validate_manifest(result)


def fake_modules():
    parser = types.SimpleNamespace()
    def parse_item(item):
        return None if item["title"] == "Song deleted" else track(item["title"])
    def parse_items(rows, *args, **kwargs):
        parsed = []
        for row in rows:
            if "musicResponsiveListItemRenderer" in row:
                value = parser.parse_playlist_item(row["musicResponsiveListItemRenderer"])
                if value is not None:
                    parsed.append(value)
        return parsed
    parser.parse_playlist_item = parse_item
    parser.parse_playlist_items = parse_items
    mixin = types.SimpleNamespace(parse_playlist_items=parse_items)
    return parser, mixin


class AdapterTests(unittest.TestCase):
    def test_deleted_placeholders_preserve_position_across_mock_pages_and_restore_hooks(self):
        parser, mixin = fake_modules()
        original_item, original_items = parser.parse_playlist_item, mixin.parse_playlist_items
        calls = []
        class Client:
            def __init__(self, auth):
                calls.append(("auth", auth))
            def _send_request(self, *args, **kwargs):
                calls.append(("request", args))
            def get_playlist(self, identifier, **kwargs):
                calls.append(("playlist", identifier, kwargs))
                self._send_request("first")
                first = mixin.parse_playlist_items([{"musicResponsiveListItemRenderer": {"title": "First"}}, {"musicResponsiveListItemRenderer": {"title": "Song deleted"}}, {"continuationItemRenderer": {}}])
                self._send_request("continuation")
                second = mixin.parse_playlist_items([{"musicResponsiveListItemRenderer": {"title": "Second"}}])
                return {"title": "Paged", "trackCount": 3, "tracks": first + second}
        payload, warnings, uncertain = fetch_playlist("PRIVATE_AUTH_PATH", "PLtest", client_factory=Client, modules=(parser, mixin))
        result = normalize_playlist(payload, "PLtest", warnings, uncertain)
        self.assertEqual([item["title"] for item in result["entries"]], ["First", "Deleted or unavailable entry", "Second"])
        self.assertTrue(result["complete"])
        self.assertFalse(result["entries"][1]["available"])
        self.assertIs(parser.parse_playlist_item, original_item)
        self.assertIs(mixin.parse_playlist_items, original_items)
        self.assertIn(("playlist", "PLtest", {"limit": None, "related": False, "suggestions_limit": 0}), calls)

    def test_unknown_renderers_audited_and_hooks_restored_after_failure(self):
        parser, mixin = fake_modules()
        original = parser.parse_playlist_item
        with preserve_unavailable_rows(parser, mixin) as audit:
            mixin.parse_playlist_items([{"unknownRenderer": {}}, {"continuationItemRenderer": {}}])
            self.assertEqual(audit["unknown"], {"unknownRenderer"})
        with self.assertRaises(RuntimeError):
            with preserve_unavailable_rows(parser, mixin):
                raise RuntimeError("test")
        self.assertIs(parser.parse_playlist_item, original)

    def test_liked_uses_no_limit_and_infinite_continuations_are_bounded(self):
        parser, mixin = fake_modules()
        class Client:
            def __init__(self, auth):
                pass
            def _send_request(self, *args, **kwargs):
                pass
            def get_liked_songs(self, limit):
                if limit is not None:
                    raise AssertionError("must fetch all pages")
                return {"trackCount": 0, "tracks": []}
            def get_playlist(self, *args, **kwargs):
                while True:
                    self._send_request("repeat-token")
        payload, _, _ = fetch_playlist("auth", "LM", liked=True, client_factory=Client, modules=(parser, mixin))
        self.assertEqual(payload["tracks"], [])
        with self.assertRaisesRegex(AdapterError, "safety limit"):
            fetch_playlist("auth", "PLtest", client_factory=Client, modules=(parser, mixin), request_limit=3)

    def test_upstream_exception_never_exposes_token_text(self):
        parser, mixin = fake_modules()
        class Client:
            def __init__(self, auth):
                raise RuntimeError("Authorization: SECRET-TEST-TOKEN")
        with self.assertRaises(AdapterError) as caught:
            fetch_playlist("auth", "PLtest", client_factory=Client, modules=(parser, mixin))
        self.assertNotIn("SECRET-TEST-TOKEN", str(caught.exception))

    def test_repeated_continuation_token_fails_explicitly_without_repeating_pages(self):
        parser, mixin = fake_modules()
        class Client:
            def __init__(self, auth):
                pass
            def _send_request(self, *args, **kwargs):
                pass
            def get_playlist(self, *args, **kwargs):
                self._send_request("browse", {"continuation": "GENERATED_TEST_TOKEN"})
                self._send_request("browse", {"continuation": "GENERATED_TEST_TOKEN"})
        with self.assertRaisesRegex(AdapterError, "pagination loop") as caught:
            fetch_playlist("auth", "PLtest", client_factory=Client, modules=(parser, mixin))
        self.assertNotIn("GENERATED_TEST_TOKEN", str(caught.exception))

    def test_synthetic_audio_playlist_count_is_not_independent_completeness_evidence(self):
        parser, mixin = fake_modules()
        def synthetic_audio(*args, **kwargs):
            return {"title": "Audio playlist", "trackCount": 1, "tracks": [track()]}
        mixin.parse_audio_playlist = synthetic_audio
        class Client:
            def __init__(self, auth):
                pass
            def _send_request(self, *args, **kwargs):
                pass
            def get_playlist(self, *args, **kwargs):
                return mixin.parse_audio_playlist({})
        payload, warnings, uncertain = fetch_playlist("auth", "OLAtest", client_factory=Client, modules=(parser, mixin))
        manifest = normalize_playlist(payload, "OLAtest", warnings, uncertain)
        self.assertIsNone(manifest["reportedCount"])
        self.assertIsNone(manifest["complete"])
        self.assertIs(mixin.parse_audio_playlist, synthetic_audio)


@unittest.skipUnless(importlib.util.find_spec("ytmusicapi"), "Optional pinned dependency is not installed; mocked tests still run.")
class PinnedParserTests(unittest.TestCase):
    def test_real_pinned_parser_retains_generated_deleted_rows_without_network(self):
        import importlib.metadata
        from ytmusicapi.parsers import playlists as parser
        from ytmusicapi.mixins import playlists as mixin
        self.assertEqual(importlib.metadata.version("ytmusicapi"), "1.12.3")
        row = {"musicResponsiveListItemRenderer": {"musicItemRendererDisplayPolicy": "MUSIC_ITEM_RENDERER_DISPLAY_POLICY_GREY_OUT", "flexColumns": [{"musicResponsiveListItemFlexColumnRenderer": {"text": {"runs": [{"text": "Song deleted"}]}}}]}}
        self.assertEqual(parser.parse_playlist_items([row]), [])
        original = parser.parse_playlist_item
        with preserve_unavailable_rows(parser, mixin) as audit:
            rows = mixin.parse_playlist_items([row, row, {"continuationItemRenderer": {}}])
            self.assertEqual(len(rows), 2)
            self.assertEqual(audit["deleted"], 2)
            self.assertTrue(all(item["isAvailable"] is False for item in rows))
        self.assertIs(parser.parse_playlist_item, original)


class ExportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)
        self.auth = self.folder / "private-auth.json"
        self.auth.write_text(json.dumps({"authorization": "SAMPLE-TEST-SECRET", "cookie": "SAMPLE-TEST-COOKIE"}), encoding="utf-8")
        self.output = self.folder / "playlist.json"

    def test_atomic_metadata_output_does_not_copy_auth_and_existing_file_is_preserved(self):
        def fetcher(auth, identifier, liked):
            return {"title": "Test", "trackCount": 2, "tracks": [track(), track()]}, [], False
        manifest = export(self.auth, "PLtest", self.output, fetcher=fetcher)
        self.assertEqual(manifest["extractedCount"], 2)
        self.assertNotIn("SAMPLE-TEST", self.output.read_text(encoding="utf-8"))
        original = self.output.read_bytes()
        with self.assertRaises(ManifestError):
            export(self.auth, "PLtest", self.output, fetcher=fetcher)
        self.assertEqual(original, self.output.read_bytes())
        self.assertEqual(list(self.folder.glob("*.tmp")), [])

    def test_fetch_failure_writes_nothing_and_never_overwrites_auth(self):
        def broken(*args, **kwargs):
            raise AdapterError("Connection failed; no manifest was written.")
        with self.assertRaises(AdapterError):
            export(self.auth, "PLtest", self.output, fetcher=broken)
        self.assertFalse(self.output.exists())
        with self.assertRaises(ManifestError):
            export(self.auth, "PLtest", self.auth, overwrite=True, fetcher=broken)

    def test_cli_exit_codes_label_complete_partial_and_unverified_without_secrets(self):
        for reported, expected in [(1, 0), (2, 2), (None, 3)]:
            manifest = normalize_playlist({"trackCount": reported, "tracks": [track()]}, "PLtest")
            output = io.StringIO()
            with patch("export_playlist.export", return_value=manifest), contextlib.redirect_stdout(output):
                code = main(["--auth", "private.json", "--playlist", "PLtest", "--output", "out.json"])
            self.assertEqual(code, expected)
            self.assertNotIn("private.json", output.getvalue())

    def test_public_export_uses_no_auth_and_cannot_export_liked_music(self):
        calls = []
        def fetcher(auth, identifier, liked):
            calls.append((auth, identifier, liked))
            return {"title": "Public playlist", "trackCount": 1, "tracks": [track()]}, [], False
        result = export(None, "PLpublic", self.output, fetcher=fetcher, public=True)
        self.assertTrue(result["complete"])
        self.assertEqual(calls, [(None, "PLpublic", False)])
        with self.assertRaises(ManifestError):
            export(None, None, self.output, liked=True, public=True, fetcher=fetcher)
        with self.assertRaises(ManifestError):
            export(self.auth, "PLpublic", self.output, public=True, fetcher=fetcher)

    def test_concurrent_writer_is_not_overwritten_without_explicit_overwrite(self):
        def fetcher(*args, **kwargs):
            return {"trackCount": 1, "tracks": [track()]}, [], False
        operation = "rename" if os.name == "nt" else "link"
        original = getattr(os, operation)
        def competitor(source, destination):
            Path(destination).write_text("OTHER WRITER DATA", encoding="utf-8")
            return original(source, destination)
        with patch(f"export_playlist.os.{operation}", side_effect=competitor):
            with self.assertRaisesRegex(ManifestError, "preserved"):
                export(self.auth, "PLtest", self.output, fetcher=fetcher)
        self.assertEqual(self.output.read_text(encoding="utf-8"), "OTHER WRITER DATA")
        self.assertEqual(list(self.folder.glob("*.tmp")), [])


class BatchTests(unittest.TestCase):
    def test_audits_every_discovered_playlist_and_retains_explicit_failures(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            discovery = folder / "discovery.json"
            discovery.write_text(json.dumps({"complete": False, "playlists": [{"playlistId": "PLgood", "title": "Good", "reportedCount": 2}, {"playlistId": "PLfailed", "title": "Failed"}, {"playlistId": "LM", "title": "Likes", "reportedCount": 3}, {"playlistId": "PLtimeout", "title": "Timed out"}]}), encoding="utf-8")
            calls = []
            def runner(command, **kwargs):
                identifier = command[command.index("--playlist") + 1]
                calls.append(identifier)
                if identifier == "PLtimeout":
                    import subprocess
                    raise subprocess.TimeoutExpired(command, kwargs["timeout"])
                if identifier == "PLfailed":
                    return types.SimpleNamespace(returncode=1)
                output = Path(command[command.index("--output") + 1])
                output.write_text(json.dumps(normalize_playlist({"trackCount": 1, "tracks": [track()]}, identifier)), encoding="utf-8")
                return types.SimpleNamespace(returncode=0)
            with contextlib.redirect_stdout(io.StringIO()):
                report = run_batch(discovery, folder / "exports", workers=2, seconds=10, runner=runner)
            self.assertEqual(report["playlistCount"], 4)
            self.assertEqual({entry["playlistId"]: entry["status"] for entry in report["playlists"]}, {"PLgood": "partial", "PLfailed": "failed", "LM": "requires-auth", "PLtimeout": "timeout"})
            self.assertNotIn("LM", calls)
            self.assertFalse(report["complete"])
            self.assertEqual(len(json.loads((folder / "exports" / "IMPORT-REPORT.json").read_text(encoding="utf-8"))["playlists"]), 4)
            manifest = json.loads((folder / "exports" / "PLgood.json").read_text(encoding="utf-8"))
            self.assertFalse(manifest["complete"])
            self.assertTrue(any("Library UI count" in warning for warning in manifest["warnings"]))


if __name__ == "__main__":
    unittest.main()
