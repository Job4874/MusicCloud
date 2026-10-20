import contextlib
import io
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import download_audio as audio
from musiccloud_manifest import normalize_playlist


FIRST = "aaaaaaaaaaa"
SECOND = "bbbbbbbbbbb"
THIRD = "ccccccccccc"
TRACK = "12345678-1234-1234-1234-123456789abc"


def manifest():
    return normalize_playlist({"title": "Generated test", "trackCount": 5, "tracks": [
        {"videoId": FIRST, "title": "First", "artists": [{"name": "Original"}], "isAvailable": True},
        {"videoId": FIRST, "title": "First", "artists": [{"name": "Original"}], "isAvailable": True},
        {"videoId": SECOND, "title": "Second", "artists": [], "isAvailable": True},
        {"videoId": THIRD, "title": "Third", "artists": [], "isAvailable": True},
        {"title": "Unavailable", "isAvailable": False},
    ]}, "LM")


def previous_report(source, failures=None):
    failures = failures or {}
    rows = []
    for entry in source["entries"]:
        outcome = ({"status": "failed", "reason": failures[entry["videoId"]]}
                   if entry["videoId"] in failures else
                   {"status": "unavailable", "reason": "source-marked-unavailable"}
                   if entry["available"] is False else
                   {"status": "deferred", "reason": "outside-current-limit"})
        rows.append({key: entry[key] for key in ["position", "videoId", "title", "artists"]} | outcome)
    return {"schema": "musiccloud.audio-import.v1", "source": "youtube-music",
            "limit": 3, "sourceComplete": source["complete"], "complete": False,
            "attemptedUnique": len(failures), "importedUnique": 0, "failedUnique": len(failures),
            "paused": False, "pauseReason": None,
            "playlists": [{"playlistId": source["playlistId"], "title": source["title"],
                           "reportedCount": source["reportedCount"],
                           "extractedCount": source["extractedCount"],
                           "sourceComplete": source["complete"], "entries": rows}]}


class API:
    def __init__(self):
        self.calls = []

    def ready(self):
        pass

    def import_audio(self, path, information, entry):
        self.calls.append(path.name)
        return TRACK


class AudioTests(unittest.TestCase):
    def test_previous_failure_skips_download_without_advancing_live_failure_pause(self):
        source = manifest()
        prior = previous_report(source, {FIRST: "stream-access-denied"})
        calls = []
        api = API()

        def downloader(identifier, directory, tools, deadline):
            calls.append(identifier)
            if identifier == SECOND:
                raise audio.ImportFailure("download-failed")
            return directory / (identifier + ".m4a"), {"sha256": "a" * 64, "bytes": 12, "duration": 5}, False

        with tempfile.TemporaryDirectory() as temporary, contextlib.redirect_stdout(io.StringIO()):
            result = audio.import_manifests([source], Path(temporary), {}, api, limit=3,
                downloader=downloader, previous_report=prior, max_consecutive_failures=2, workers=1)
        self.assertEqual(calls, [SECOND, THIRD])
        self.assertEqual(api.calls, [THIRD + ".m4a"])
        self.assertEqual(result["skippedPreviousFailures"], 1)
        self.assertFalse(result["paused"], "A carried failure must not count toward this run's pause threshold.")
        rows = result["playlists"][0]["entries"]
        self.assertEqual([row["position"] for row in rows], [1, 2, 3, 4, 5])
        self.assertEqual([row["status"] for row in rows], ["failed", "failed", "failed", "imported", "unavailable"])
        for row in rows[:2]:
            self.assertEqual(row["reason"], "stream-access-denied")
            self.assertIs(row["previousFailure"], True)
        self.assertNotIn("previousFailure", rows[2])

    def test_previous_failure_does_not_trust_unknown_reason_changed_identity_or_import_conflict(self):
        source = manifest()
        for alteration in ["unknown-reason", "changed-title", "changed-artists", "imported-conflict"]:
            with self.subTest(alteration=alteration):
                prior = previous_report(source, {FIRST: "stream-access-denied", SECOND: "download-failed"})
                rows = prior["playlists"][0]["entries"]
                if alteration == "unknown-reason":
                    for row in rows[:2]:
                        row["reason"] = "https://private.invalid/?secret=injected"
                elif alteration == "changed-title":
                    for row in rows[:2]:
                        row["title"] = "Unrelated recording"
                elif alteration == "changed-artists":
                    for row in rows[:2]:
                        row["artists"] = ["Unrelated artist"]
                else:
                    rows[1] = {key: rows[1][key] for key in ["position", "videoId", "title", "artists"]} | {
                        "status": "imported", "trackId": TRACK}
                outcomes = audio.previous_failure_outcomes(prior, [source], {FIRST, SECOND})
                self.assertNotIn(FIRST, outcomes)
                self.assertEqual(outcomes[SECOND], {
                    "status": "failed", "reason": "download-failed", "previousFailure": True})
                self.assertNotIn("injected", json.dumps(outcomes))

    def test_previous_failure_respects_current_selection_availability_playlist_and_report_structure(self):
        source = manifest()
        prior = previous_report(source, {FIRST: "stream-access-denied", SECOND: "download-failed"})
        self.assertEqual(set(audio.previous_failure_outcomes(prior, [source], {SECOND})), {SECOND})
        unavailable = json.loads(json.dumps(source))
        for entry in unavailable["entries"][:2]:
            entry["available"] = False
        self.assertEqual(audio.previous_failure_outcomes(prior, [unavailable], {FIRST}), {})
        another_playlist = json.loads(json.dumps(source))
        another_playlist["playlistId"] = "DifferentPlaylist"
        self.assertEqual(audio.previous_failure_outcomes(prior, [another_playlist], {FIRST}), {})
        for alteration in ["schema", "positions", "artists"]:
            with self.subTest(malformed=alteration):
                invalid = json.loads(json.dumps(prior))
                if alteration == "schema":
                    invalid["schema"] = "untrusted-report.v1"
                elif alteration == "positions":
                    invalid["playlists"][0]["entries"][1]["position"] = 1
                else:
                    invalid["playlists"][0]["entries"][0]["artists"] = "Original"
                with self.assertRaisesRegex(audio.ImportFailure, "^invalid-previous-report$"):
                    audio.previous_failure_outcomes(invalid, [source], {FIRST, SECOND})

    def test_deduplicates_downloads_preserves_positions_failures_and_limit(self):
        calls = []

        def downloader(identifier, folder, tools, deadline):
            calls.append(identifier)
            if identifier == SECOND:
                raise audio.ImportFailure("download-failed")
            return folder / (identifier + ".m4a"), {"sha256": "a" * 64, "bytes": 12, "duration": 5}, False

        with tempfile.TemporaryDirectory() as temporary, contextlib.redirect_stdout(io.StringIO()):
            directory = Path(temporary)
            result = audio.import_manifests([manifest()], directory, {}, API(), limit=2, downloader=downloader)
            saved = json.loads((directory / "download-report.json").read_text())
        self.assertEqual(calls, [FIRST, SECOND])
        self.assertEqual(result, saved)
        self.assertEqual(result["attemptedUnique"], 2)
        self.assertEqual(result["importedUnique"], 1)
        self.assertFalse(result["complete"])
        entries = result["playlists"][0]["entries"]
        self.assertEqual([entry["position"] for entry in entries], [1, 2, 3, 4, 5])
        self.assertEqual([entry["status"] for entry in entries], ["imported", "imported", "failed", "deferred", "unavailable"])

    def test_existing_verified_file_resumes_without_downloader(self):
        calls = []

        def runner(arguments, timeout):
            calls.append(arguments)
            return subprocess.CompletedProcess(arguments, 0, json.dumps({
                "streams": [{"codec_type": "audio", "codec_name": "aac"}], "format": {"duration": "5"}}), "")

        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            path = directory / (FIRST + ".m4a")
            path.write_bytes(b"generated fixture")
            actual, info, reused = audio.download(FIRST, directory, {"ffprobe": Path("ffprobe.exe")}, 30, runner)
        self.assertTrue(reused)
        self.assertEqual(actual.name, FIRST + ".m4a")
        self.assertEqual(info["duration"], 5)
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][0], "ffprobe.exe")

    def test_repeated_failures_pause_with_remaining_rows_still_pending(self):
        calls = []

        def downloader(identifier, *args):
            calls.append(identifier)
            raise audio.ImportFailure("rate-limited")

        with tempfile.TemporaryDirectory() as temporary, contextlib.redirect_stdout(io.StringIO()):
            result = audio.import_manifests([manifest()], Path(temporary), {}, API(), limit=3,
                downloader=downloader, max_consecutive_failures=2, workers=1)
        self.assertEqual(calls, [FIRST, SECOND])
        self.assertTrue(result["paused"])
        self.assertEqual(result["pauseReason"], "rate-limited")
        self.assertEqual(result["attemptedUnique"], 2)
        remaining = result["playlists"][0]["entries"][3]
        self.assertEqual(remaining["status"], "pending")
        self.assertEqual(remaining["reason"], "paused-after-consecutive-failures")

    def test_downloads_overlap_but_api_and_report_have_one_coordinator(self):
        coordinator = threading.get_ident()
        barrier = threading.Barrier(3)
        worker_threads = set()
        recorded = []

        def downloader(identifier, directory, tools, deadline):
            worker_threads.add(threading.get_ident())
            barrier.wait(timeout=3)
            return directory / (identifier + ".m4a"), {"sha256": "a" * 64, "bytes": 12, "duration": 5}, False

        class SerialAPI(API):
            def import_audio(self, *args):
                self_thread = threading.get_ident()
                if self_thread != coordinator:
                    raise AssertionError("API mutation left the coordinator")
                return TRACK

        def writer(path, value):
            self.assertEqual(threading.get_ident(), coordinator)
            recorded.append(json.loads(json.dumps(value)))

        with tempfile.TemporaryDirectory() as temporary, contextlib.redirect_stdout(io.StringIO()):
            result = audio.import_manifests([manifest()], Path(temporary), {}, SerialAPI(), limit=3,
                downloader=downloader, writer=writer, workers=3)
        self.assertEqual(len(worker_threads), 3)
        self.assertNotIn(coordinator, worker_threads)
        self.assertEqual(result["importedUnique"], 3)
        self.assertEqual(recorded[-1], result)

    def test_process_cancellation_stops_owned_work_promptly(self):
        cancelled = threading.Event()
        timer = threading.Timer(0.1, cancelled.set)
        timer.start()
        started = time.monotonic()
        try:
            with self.assertRaisesRegex(audio.ImportFailure, "^batch-paused$"):
                audio.execute([sys.executable, "-c", "import time; time.sleep(20)"], 20, cancelled)
        finally:
            timer.cancel()
        self.assertLess(time.monotonic() - started, 3)

    def test_download_failure_never_exports_raw_diagnostics(self):
        secret = "https://example.invalid/?secret=do-not-export"

        def runner(arguments, timeout):
            self.assertIn("--ignore-config", arguments)
            self.assertIn("--no-cookies-from-browser", arguments)
            self.assertIn("--no-plugin-dirs", arguments)
            self.assertNotIn("--sleep-requests", arguments)
            self.assertNotIn("--sleep-interval", arguments)
            self.assertNotIn("--limit-rate", arguments)
            self.assertEqual(arguments[-1], "https://www.youtube.com/watch?v=" + FIRST)
            return subprocess.CompletedProcess(arguments, 1, "", "HTTP error 403 " + secret)

        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(audio.ImportFailure, "^stream-access-denied$"):
                audio.download(FIRST, Path(temporary), {name: Path(name + ".exe") for name in
                               ["yt_dlp", "node", "ffmpeg", "ffprobe"]}, 30, runner)

    def test_timeout_has_fixed_safe_reason(self):
        with self.assertRaisesRegex(audio.ImportFailure, "^process-timeout$"):
            audio.execute([sys.executable, "-c", "import time; time.sleep(10)"], 0.1)

    def test_network_failures_have_fixed_codes_without_raw_connection_details(self):
        self.assertEqual(audio.failure_reason("getaddrinfo failed: private-detail"), "dns-resolution-failed")
        self.assertEqual(audio.failure_reason("Connection reset by peer: private-detail"), "connection-reset")
        self.assertEqual(audio.failure_reason("Read timed out for https://private.invalid/?key=secret"), "network-timeout")
        self.assertEqual(audio.failure_reason("Requested format is not available"), "no-playable-stream")

    @unittest.skipUnless(os.name == "nt", "Windows process job behavior")
    def test_windows_timeout_terminates_owned_descendant(self):
        import ctypes
        from ctypes import wintypes
        with tempfile.TemporaryDirectory() as temporary:
            pid_file = Path(temporary) / "owned-child.pid"
            script = ("import subprocess,sys,time,pathlib; "
                      "child=subprocess.Popen([sys.executable,'-c','import time; time.sleep(20)']); "
                      "pathlib.Path(sys.argv[1]).write_text(str(child.pid)); time.sleep(20)")
            with self.assertRaisesRegex(audio.ImportFailure, "^process-timeout$"):
                audio.execute([sys.executable, "-c", script, str(pid_file)], 1)
            self.assertTrue(pid_file.exists(), "The harmless descendant must have started before timeout.")
            child_pid = int(pid_file.read_text())
            kernel = ctypes.WinDLL("kernel32", use_last_error=True)
            kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
            kernel.OpenProcess.restype = wintypes.HANDLE
            kernel.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
            kernel.WaitForSingleObject.restype = wintypes.DWORD
            kernel.CloseHandle.argtypes = [wintypes.HANDLE]
            handle = kernel.OpenProcess(0x100000, False, child_pid)
            if handle:
                try:
                    self.assertEqual(kernel.WaitForSingleObject(handle, 5000), 0,
                                     "The owned descendant must terminate with its timed-out parent.")
                finally:
                    kernel.CloseHandle(handle)
            else:
                self.assertEqual(ctypes.get_last_error(), 87, "A missing process ID is expected after cleanup.")

    def test_corrupt_existing_final_file_is_preserved_and_retried(self):
        calls = []
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            target = directory / (FIRST + ".m4a")
            target.write_bytes(b"damaged original fixture")

            def runner(arguments, timeout):
                calls.append(arguments)
                if arguments[0] == "yt_dlp.exe":
                    target.write_bytes(b"recovered fixture")
                    return subprocess.CompletedProcess(arguments, 0, "", "")
                if len(calls) == 1:
                    return subprocess.CompletedProcess(arguments, 1, "", "generated verification failure")
                return subprocess.CompletedProcess(arguments, 0, json.dumps({
                    "streams": [{"codec_type": "audio"}], "format": {"duration": "5"}}), "")

            path, information, reused = audio.download(FIRST, directory,
                {name: Path(name + ".exe") for name in ["yt_dlp", "node", "ffmpeg", "ffprobe"]}, 30, runner)
            quarantined = list((directory / "quarantine").iterdir())
            self.assertEqual(len(quarantined), 1)
            self.assertEqual(quarantined[0].read_bytes(), b"damaged original fixture")
            self.assertEqual(path.read_bytes(), b"recovered fixture")
            self.assertFalse(reused)
            self.assertEqual(information["duration"], 5)
            self.assertEqual(len(calls), 3)

    def test_invalid_video_id_never_runs_tool(self):
        with self.assertRaisesRegex(audio.ImportFailure, "invalid-video-id"):
            audio.download("../outside", Path("."), {}, 30, lambda *args: self.fail("Tool must not run"))

    def test_resume_after_upload_uses_existing_hash_and_patches_exact_artist(self):
        client = audio.LocalMusicCloud(4783)
        calls = []

        def request(method, route, body=None, headers=None):
            calls.append((method, route, body))
            if method == "GET":
                return {"tracks": [{"id": TRACK, "sha256": "a" * 64, "youtubeVideoIds": [SECOND]}]}
            return {"track": {"id": TRACK}}

        client.request = request
        entry = {"title": "Original song", "artists": ["First artist", "Second artist"], "videoId": FIRST}
        result = client.import_audio(Path("not-read-on-resume.m4a"), {"sha256": "a" * 64, "duration": 5}, entry)
        self.assertEqual(result, TRACK)
        self.assertEqual([item[0] for item in calls], ["GET", "PATCH"])
        self.assertEqual(json.loads(calls[1][2])["artist"], "First artist")
        self.assertEqual(json.loads(calls[1][2])["youtubeVideoIds"], [SECOND, FIRST])

    def test_verification_rejects_nan_or_missing_audio(self):
        for output in [{"streams": [], "format": {"duration": "5"}},
                       {"streams": [{"codec_type": "audio"}], "format": {"duration": "nan"}}]:
            with tempfile.TemporaryDirectory() as temporary:
                path = Path(temporary) / "original.m4a"
                path.write_bytes(b"generated fixture")
                runner = lambda *args: subprocess.CompletedProcess([], 0, json.dumps(output), "")
                with self.assertRaisesRegex(audio.ImportFailure, "audio-verification-failed"):
                    audio.verify_audio(path, "ffprobe", runner)


if __name__ == "__main__":
    unittest.main()
