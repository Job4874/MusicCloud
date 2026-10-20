import base64
import copy
import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from har_playlist import extract_playlist, publish_json, update_report, main
from musiccloud_manifest import ManifestError


def row(title="Generated song", video="abcdefghijk", unavailable=False):
    data = {"flexColumns": [{"musicResponsiveListItemFlexColumnRenderer": {"text": {"runs": [{"text": title}]}}}, {"musicResponsiveListItemFlexColumnRenderer": {"text": {"runs": [{"text": "First Artist"}, {"text": " & "}, {"text": "Second Artist"}]}}}], "menu": {"privateFeedbackToken": "SAMPLE_SECRET_MUST_NOT_EXPORT"}}
    if unavailable:
        data["musicItemRendererDisplayPolicy"] = "MUSIC_ITEM_RENDERER_DISPLAY_POLICY_GREY_OUT"
    else:
        data["overlay"] = {"musicItemThumbnailOverlayRenderer": {"content": {"musicPlayButtonRenderer": {"playNavigationEndpoint": {"watchEndpoint": {"videoId": video}}}}}}
    return {"musicResponsiveListItemRenderer": data}


def marker(token):
    return {"continuationItemRenderer": {"continuationEndpoint": {"continuationCommand": {"token": token}}}}


def capture(body, request=None, encoded=False, status=200):
    value = json.dumps(body)
    content = {"text": base64.b64encode(value.encode()).decode() if encoded else value, **({"encoding": "base64"} if encoded else {})}
    return {"request": {"url": "https://music.youtube.com/youtubei/v1/browse?hidden=DO_NOT_EXPORT", "headers": [{"name": "authorization", "value": "SAMPLE_AUTH_NEVER_EXPORT"}], "cookies": [{"name": "private", "value": "SAMPLE_COOKIE_NEVER_EXPORT"}], "postData": {"text": json.dumps(request or {})}}, "response": {"status": status, "content": content}}


def first(items, count=3, identifier="LM"):
    return {"header": {"musicResponsiveHeaderRenderer": {"title": {"runs": [{"text": "Liked Music"}]}, "secondSubtitle": {"runs": [{"text": f"{count} songs"}]}, "play": {"playlistId": identifier}}}, "contents": {"musicPlaylistShelfRenderer": {"targetId": identifier, "contents": items}}}


def har(entries):
    return {"log": {"entries": entries}}


class HarTests(unittest.TestCase):
    def test_linked_pages_preserve_duplicates_and_unavailable_without_secrets(self):
        initial = capture(first([row("First"), marker("GENERATED_CONTINUATION")]), {"browseId": "VLLM"})
        continuation = capture({"onResponseReceivedActions": [{"appendContinuationItemsAction": {"continuationItems": [row("Duplicate"), row("Unavailable", unavailable=True)]}}]}, {"continuation": "GENERATED_CONTINUATION"}, encoded=True)
        manifest, stats = extract_playlist([har([initial]), har([continuation])], "LM", 3)
        self.assertTrue(manifest["complete"])
        self.assertEqual(manifest["extractedCount"], 3)
        self.assertEqual(stats["identifiedPlaylistPages"], 2)
        self.assertEqual([entry["position"] for entry in manifest["entries"]], [1, 2, 3])
        self.assertEqual(manifest["entries"][0]["videoId"], manifest["entries"][1]["videoId"])
        self.assertFalse(manifest["entries"][2]["available"])
        self.assertEqual(manifest["entries"][0]["artists"], ["First Artist", "Second Artist"])
        serialized = json.dumps(manifest)
        for secret in ["SAMPLE_SECRET", "SAMPLE_AUTH", "SAMPLE_COOKIE", "GENERATED_CONTINUATION", "DO_NOT_EXPORT"]:
            self.assertNotIn(secret, serialized)

    def test_missing_pages_are_partial_and_wrong_list_cannot_be_guessed(self):
        initial = capture(first([row(), marker("MISSING_PAGE")], count=589), {"browseId": "VLLM"})
        manifest, stats = extract_playlist([har([initial])], "LM", 589)
        self.assertFalse(manifest["complete"])
        self.assertEqual(manifest["reportedCount"], 589)
        self.assertTrue(stats["missingNextPage"])
        with self.assertRaises(ManifestError):
            extract_playlist([har([initial])], "PLanother")
        initial["request"]["postData"]["text"] = json.dumps({"browseId": "PLanother"})
        with self.assertRaises(ManifestError):
            extract_playlist([har([initial])], "LM")

    def test_ended_chain_with_count_shortfall_stays_partial_without_inventing_rows(self):
        manifest, stats = extract_playlist([har([capture(first([row()], count=3), {"browseId": "VLLM"})])], "LM", 3)
        self.assertFalse(manifest["complete"])
        self.assertFalse(stats["missingNextPage"])
        self.assertEqual(len(manifest["entries"]), 1)
        self.assertTrue(any("no further continuation marker" in warning for warning in manifest["warnings"]))

    def test_reload_pages_not_concatenated_and_unrelated_continuation_not_used(self):
        initial = capture(first([row(), marker("WANTED")], count=2), {"browseId": "VLLM"})
        wrong = capture({"onResponseReceivedActions": [{"appendContinuationItemsAction": {"continuationItems": [row("Wrong list")]}}]}, {"continuation": "UNRELATED"})
        manifest, _ = extract_playlist([har([initial, copy.deepcopy(initial), wrong])], "LM", 2)
        self.assertEqual(manifest["extractedCount"], 1)
        self.assertFalse(manifest["complete"])

    def test_selects_explicit_playlist_shelf_instead_of_recommendations(self):
        payload = first([row("Correct list")], count=1)
        payload["recommendations"] = {"musicPlaylistShelfRenderer": {"targetId": "PLother", "contents": [row("Wrong list")]}}
        manifest, _ = extract_playlist([har([capture(payload, {"browseId": "VLLM"})])], "LM", 1)
        self.assertEqual(manifest["entries"][0]["title"], "Correct list")

    def test_nested_and_unrecognized_continuation_markers_never_claim_complete(self):
        nested_marker = {"continuationItemRenderer": {"continuationEndpoint": {"commandExecutorCommand": {"commands": [{"playlistVotingRefreshPopupCommand": {}}, {"continuationCommand": {"token": "GENERATED_NEXT", "request": "CONTINUATION_REQUEST_TYPE_BROWSE"}}]}}}}
        payload = first([row(), nested_marker], count=1)
        manifest, stats = extract_playlist([har([capture(payload, {"browseId": "VLLM"})])], "LM", 1)
        self.assertFalse(manifest["complete"])
        self.assertTrue(stats["missingNextPage"])
        payload = first([row(), {"continuationItemRenderer": {"newUnknownCommand": {}}}], count=1)
        manifest, _ = extract_playlist([har([capture(payload, {"browseId": "VLLM"})])], "LM", 1)
        self.assertIsNone(manifest["complete"])

    def test_unknown_count_unrecognized_rows_and_loop_are_not_complete(self):
        payload = first([row(), {"newUnknownRenderer": {}}], count=1)
        manifest, _ = extract_playlist([har([capture(payload, {"browseId": "VLLM"})])], "LM")
        self.assertIsNone(manifest["complete"])
        payload["header"]["musicResponsiveHeaderRenderer"].pop("secondSubtitle")
        manifest, _ = extract_playlist([har([capture(payload, {"browseId": "VLLM"})])], "LM")
        self.assertIsNone(manifest["reportedCount"])
        initial = capture(first([row(), marker("REPEATED")], count=3), {"browseId": "VLLM"})
        repeated = capture({"onResponseReceivedActions": [{"appendContinuationItemsAction": {"continuationItems": [row(), marker("REPEATED")]}}]}, {"continuation": "REPEATED"})
        manifest, _ = extract_playlist([har([initial, repeated])], "LM", 3)
        self.assertFalse(manifest["complete"])
        self.assertEqual(manifest["extractedCount"], 2)

    def test_report_update_changes_only_requested_entry_and_preserves_observed_count(self):
        manifest, _ = extract_playlist([har([capture(first([row()], count=2), {"browseId": "VLLM"})])], "LM", 2)
        with tempfile.TemporaryDirectory() as temp:
            report_path = Path(temp) / "audit.json"
            other = {"playlistId": "PLother", "status": "complete", "extractedCount": 5}
            report_path.write_text(json.dumps({"schema": "musiccloud.import-report.v1", "discoveryComplete": False, "playlists": [{"playlistId": "LM", "observedReportedCount": 2, "status": "requires-auth"}, other]}), encoding="utf-8")
            update_report(report_path, manifest, "LM.json")
            report = json.loads(report_path.read_text())
            self.assertEqual(report["playlists"][0]["status"], "partial")
            self.assertEqual(report["playlists"][0]["observedReportedCount"], 2)
            self.assertEqual(report["playlists"][1], other)
            self.assertFalse(report["complete"])
            output = Path(temp) / "out.json"
            publish_json(output, manifest)
            with self.assertRaises(ManifestError):
                publish_json(output, manifest)

    def test_cli_rejects_output_report_alias_before_writing_either(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            source = folder / "generated.har"
            source.write_text(json.dumps(har([capture(first([row()], count=1), {"browseId": "VLLM"})])), encoding="utf-8")
            audit = folder / "audit.json"
            original = '{"schema":"musiccloud.import-report.v1","playlists":[]}'
            audit.write_text(original, encoding="utf-8")
            with contextlib.redirect_stderr(io.StringIO()):
                code = main(["--har", str(source), "--playlist", "LM", "--output", str(audit), "--report", str(audit), "--overwrite"])
            self.assertEqual(code, 1)
            self.assertEqual(audit.read_text(encoding="utf-8"), original)


if __name__ == "__main__":
    unittest.main()
