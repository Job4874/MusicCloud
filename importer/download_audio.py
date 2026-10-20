"""Optional ordinary-stream import. No account, browser, DRM or cache access."""

import argparse
from concurrent.futures import FIRST_COMPLETED, ThreadPoolExecutor, wait
import hashlib
import http.client
import json
import math
import os
import re
import signal
import subprocess
import sys
import threading
import time
import uuid
from pathlib import Path
from urllib.parse import quote

from musiccloud_manifest import VIDEO_ID, validate_manifest

RELEASE = "2026.08.19"
OFFICIAL_SHA256 = "66674953fe251b89f4d08c5f0e35e0728679bd67ab3d7d05c0562af101dd3e7a"
MAX_AUDIO_BYTES = 256 * 1024 * 1024
UUID = re.compile(r"^[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$")


class ImportFailure(Exception):
    """Only fixed, non-sensitive reason codes leave process boundaries."""


def file_hash(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def read_json(path, maximum=100 * 1024 * 1024):
    if path.is_symlink() or not path.is_file() or path.stat().st_size > maximum:
        raise ImportFailure("invalid-input-file")
    try:
        return json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, ValueError):
        raise ImportFailure("invalid-input-json") from None


def atomic_json(path, value):
    temporary = path.with_name(path.name + ".tmp")
    if path.is_symlink() or temporary.is_symlink():
        raise ImportFailure("unsafe-output-path")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


class WindowsJob:
    """An anonymous job owns only this invocation and its descendants."""

    def __init__(self):
        import ctypes
        from ctypes import wintypes as types

        class Basic(ctypes.Structure):
            _fields_ = [("processTime", ctypes.c_int64), ("jobTime", ctypes.c_int64),
                        ("flags", types.DWORD), ("minWorkingSet", ctypes.c_size_t),
                        ("maxWorkingSet", ctypes.c_size_t), ("activeProcesses", types.DWORD),
                        ("affinity", ctypes.c_size_t), ("priority", types.DWORD), ("scheduling", types.DWORD)]

        class Counters(ctypes.Structure):
            _fields_ = [(name, ctypes.c_uint64) for name in
                        ["readOps", "writeOps", "otherOps", "readBytes", "writeBytes", "otherBytes"]]

        class Extended(ctypes.Structure):
            _fields_ = [("basic", Basic), ("io", Counters), ("processMemory", ctypes.c_size_t),
                        ("jobMemory", ctypes.c_size_t), ("peakProcessMemory", ctypes.c_size_t),
                        ("peakJobMemory", ctypes.c_size_t)]

        self.ctypes = ctypes
        self.types = types
        self.kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel = self.kernel
        kernel.CreateJobObjectW.argtypes = [ctypes.c_void_p, types.LPCWSTR]
        kernel.CreateJobObjectW.restype = types.HANDLE
        kernel.SetInformationJobObject.argtypes = [types.HANDLE, ctypes.c_int, ctypes.c_void_p, types.DWORD]
        kernel.SetInformationJobObject.restype = types.BOOL
        kernel.AssignProcessToJobObject.argtypes = [types.HANDLE, types.HANDLE]
        kernel.AssignProcessToJobObject.restype = types.BOOL
        kernel.TerminateJobObject.argtypes = [types.HANDLE, types.UINT]
        kernel.TerminateJobObject.restype = types.BOOL
        kernel.CloseHandle.argtypes = [types.HANDLE]
        kernel.CloseHandle.restype = types.BOOL
        self.handle = kernel.CreateJobObjectW(None, None)
        if not self.handle:
            raise ImportFailure("process-job-unavailable")
        limits = Extended()
        limits.basic.flags = 0x2000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        if not kernel.SetInformationJobObject(self.handle, 9, ctypes.byref(limits), ctypes.sizeof(limits)):
            self.close()
            raise ImportFailure("process-job-unavailable")

    def start(self, process):
        # Popen starts the root suspended. Assign the job before allowing any
        # instructions, so it cannot spawn a child outside the owned job.
        c, t, kernel = self.ctypes, self.types, self.kernel
        if not kernel.AssignProcessToJobObject(self.handle, int(process._handle)):
            raise ImportFailure("process-job-unavailable")

        class ThreadEntry(c.Structure):
            _fields_ = [("size", t.DWORD), ("usage", t.DWORD), ("threadId", t.DWORD),
                        ("ownerPid", t.DWORD), ("basePriority", t.LONG), ("deltaPriority", t.LONG),
                        ("flags", t.DWORD)]

        kernel.CreateToolhelp32Snapshot.argtypes = [t.DWORD, t.DWORD]
        kernel.CreateToolhelp32Snapshot.restype = t.HANDLE
        kernel.Thread32First.argtypes = [t.HANDLE, c.POINTER(ThreadEntry)]
        kernel.Thread32First.restype = t.BOOL
        kernel.Thread32Next.argtypes = [t.HANDLE, c.POINTER(ThreadEntry)]
        kernel.Thread32Next.restype = t.BOOL
        kernel.OpenThread.argtypes = [t.DWORD, t.BOOL, t.DWORD]
        kernel.OpenThread.restype = t.HANDLE
        kernel.ResumeThread.argtypes = [t.HANDLE]
        kernel.ResumeThread.restype = t.DWORD
        snapshot = kernel.CreateToolhelp32Snapshot(4, 0)  # TH32CS_SNAPTHREAD
        if snapshot in {None, c.c_void_p(-1).value}:
            raise ImportFailure("process-job-unavailable")
        resumed = False
        try:
            entry = ThreadEntry()
            entry.size = c.sizeof(entry)
            valid = kernel.Thread32First(snapshot, c.byref(entry))
            while valid:
                if entry.ownerPid == process.pid:
                    thread = kernel.OpenThread(2, False, entry.threadId)  # THREAD_SUSPEND_RESUME
                    if thread:
                        try:
                            resumed = kernel.ResumeThread(thread) != 0xffffffff
                        finally:
                            kernel.CloseHandle(thread)
                    break
                valid = kernel.Thread32Next(snapshot, c.byref(entry))
        finally:
            kernel.CloseHandle(snapshot)
        if not resumed:
            raise ImportFailure("process-job-unavailable")

    def terminate(self):
        self.kernel.TerminateJobObject(self.handle, 1)

    def close(self):
        if self.handle:
            self.kernel.CloseHandle(self.handle)
            self.handle = None


def execute(arguments, timeout, cancel_event=None):
    job = WindowsJob() if os.name == "nt" else None
    process = None
    try:
        process = subprocess.Popen(arguments, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, encoding="utf-8", errors="replace", shell=False,
                                   creationflags=4 if job else 0, start_new_session=not bool(job))
        if job:
            job.start(process)
        expires = time.monotonic() + timeout
        while True:
            cancelled = cancel_event is not None and cancel_event.is_set()
            remaining = expires - time.monotonic()
            if cancelled or remaining <= 0:
                if job:
                    job.terminate()
                else:
                    os.killpg(process.pid, signal.SIGKILL)
                process.communicate(timeout=10)
                raise ImportFailure("batch-paused" if cancelled else "process-timeout") from None
            try:
                stdout, stderr = process.communicate(timeout=min(remaining, 0.25) if cancel_event else remaining)
                break
            except subprocess.TimeoutExpired:
                continue
        return subprocess.CompletedProcess(arguments, process.returncode, stdout, stderr)
    except OSError:
        raise ImportFailure("tool-start-failed") from None
    finally:
        if job:
            job.close()
        if process and process.poll() is None:
            process.kill()
            process.wait(timeout=10)


def verify_audio(path, ffprobe, runner=execute):
    if path.is_symlink() or not path.is_file() or not 0 < path.stat().st_size <= MAX_AUDIO_BYTES:
        raise ImportFailure("missing-or-invalid-audio-file")
    result = runner([str(ffprobe), "-v", "error", "-select_streams", "a:0", "-show_entries",
                     "stream=codec_type,codec_name,duration:format=duration", "-of", "json", str(path)], 25)
    if result.returncode:
        raise ImportFailure("audio-verification-failed")
    try:
        value = json.loads(result.stdout)
        streams = value.get("streams", [])
        duration = float(value.get("format", {}).get("duration", 0))
        if not streams or streams[0].get("codec_type") != "audio" or not math.isfinite(duration) or not 0 < duration <= 604800:
            raise ValueError()
    except (ValueError, TypeError, AttributeError, IndexError):
        raise ImportFailure("audio-verification-failed") from None
    return {"sha256": file_hash(path), "bytes": path.stat().st_size, "duration": duration}


def failure_reason(stderr):
    # Never copy the tool's raw diagnostics, URLs, headers or response bodies.
    text = stderr.lower()
    for needle, reason in [("getaddrinfo failed", "dns-resolution-failed"), ("no such host", "dns-resolution-failed"),
                           ("timed out", "network-timeout"), ("connection reset", "connection-reset"),
                           ("connection refused", "connection-refused"), ("network is unreachable", "network-unreachable"),
                           ("remote end closed connection", "remote-disconnected"),
                           ("certificate_verify_failed", "certificate-validation-failed"),
                           ("requested format is not available", "no-playable-stream"),
                           ("not a bot", "interactive-verification-required"),
                           ("drm", "protected-stream"), ("private video", "private-video"),
                           ("sign in", "sign-in-required"), ("not available", "unavailable-stream"),
                           ("removed", "removed-video"), ("429", "rate-limited"),
                           ("403", "stream-access-denied"), ("no video formats", "no-playable-stream")]:
        if needle in text:
            return reason
    return "download-failed"


def download(video_id, directory, tools, deadline, runner=execute):
    if not VIDEO_ID.fullmatch(video_id):
        raise ImportFailure("invalid-video-id")
    if runner is execute and tools.get("cancel_event") is not None:
        runner = lambda arguments, timeout: execute(arguments, timeout, tools["cancel_event"])
    target = directory / (video_id + ".m4a")
    if target.exists() or target.is_symlink():
        if target.is_symlink() or not target.is_file():
            raise ImportFailure("unsafe-existing-audio-path")
        try:
            information = verify_audio(target, tools["ffprobe"], runner)
        except ImportFailure as error:
            if str(error) not in {"audio-verification-failed", "missing-or-invalid-audio-file"}:
                raise
            # Preserve damaged final output instead of replacing it or trapping
            # every future resume in the same failed verification.
            quarantine = directory / "quarantine"
            if quarantine.is_symlink():
                raise ImportFailure("unsafe-output-path")
            quarantine.mkdir(exist_ok=True)
            target.rename(quarantine / (video_id + "." + uuid.uuid4().hex + ".m4a"))
        else:
            return target, information, True
    arguments = [str(tools["yt_dlp"]), "--ignore-config", "--no-plugin-dirs", "--no-remote-components",
                 "--no-cookies-from-browser", "--no-cache-dir", "--no-playlist", "--no-color", "--no-progress",
                 "--no-warnings", "--no-overwrites", "--no-post-overwrites", "--windows-filenames",
                 "--no-js-runtimes", "--js-runtimes", "node:" + str(tools["node"]),
                 "--ffmpeg-location", str(tools["ffmpeg"].parent), "--retries", "2", "--fragment-retries", "2",
                 "--extractor-retries", "2", "--socket-timeout", "20", "--abort-on-unavailable-fragments",
                 "--max-filesize", str(MAX_AUDIO_BYTES),
                 "-f", "ba[ext=m4a]/ba", "-x", "--audio-format", "m4a", "--audio-quality", "192K",
                 "--embed-metadata", "--no-write-info-json", "--no-write-thumbnail",
                 "-P", str(directory), "-P", "temp:" + str(directory / "partial"), "-o", "%(id)s.%(ext)s",
                 "--", "https://www.youtube.com/watch?v=" + video_id]
    result = runner(arguments, deadline)
    if result.returncode:
        raise ImportFailure(failure_reason(result.stderr))
    return target, verify_audio(target, tools["ffprobe"], runner), False


class LocalMusicCloud:
    def __init__(self, port):
        self.port = port

    def request(self, method, route, body=None, headers=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=60)
        try:
            connection.request(method, route, body=body, headers={"X-MusicCloud": "1", **(headers or {})})
            response = connection.getresponse()
            payload = response.read(20 * 1024 * 1024 + 1)
            if not 200 <= response.status < 300 or len(payload) > 20 * 1024 * 1024:
                raise ImportFailure("local-api-request-failed")
            return json.loads(payload)
        except (OSError, ValueError, http.client.HTTPException):
            raise ImportFailure("local-api-unavailable") from None
        finally:
            connection.close()

    def ready(self):
        health = self.request("GET", "/api/health")
        if health.get("name") != "MusicCloud" or health.get("localOnly") is not True or health.get("ok") is not True:
            raise ImportFailure("wrong-local-server")

    def import_audio(self, path, information, entry):
        # Hash lookup also resumes after upload succeeded but the process ended
        # before writing its report. The server independently deduplicates hashes.
        library = self.request("GET", "/api/library")
        existing = next((track for track in library.get("tracks", [])
                         if track.get("sha256") == information["sha256"]), None)
        if existing:
            track = existing
        else:
            with path.open("rb") as source:
                result = self.request("POST", "/api/tracks", source,
                                      {"X-File-Name": quote(path.name, safe=""), "Content-Type": "audio/mp4",
                                       "Content-Length": str(path.stat().st_size)})
            track = result.get("track", {})
        identifier = track.get("id", "")
        if not isinstance(identifier, str) or not UUID.fullmatch(identifier):
            raise ImportFailure("invalid-local-track-response")
        # An exact individual artist matches the catalog's artist alternatives.
        # Do not concatenate all artists into an unmatched synthetic artist name.
        artist = next((name for name in entry["artists"] if name.strip()), "Unknown artist")
        title = entry["title"].strip() or "Untitled entry"
        if len(title) > 300 or len(artist) > 200:
            raise ImportFailure("metadata-exceeds-local-library-limits")
        video_ids = [identifier for identifier in track.get("youtubeVideoIds", [])
                     if isinstance(identifier, str) and VIDEO_ID.fullmatch(identifier)]
        if entry["videoId"] not in video_ids:
            video_ids.append(entry["videoId"])
        payload = json.dumps({"title": title, "artist": artist, "album": "YouTube Music import",
                              "duration": information["duration"], "youtubeVideoIds": list(dict.fromkeys(video_ids))},
                             ensure_ascii=False).encode("utf-8")
        self.request("PATCH", "/api/tracks/" + identifier, payload,
                     {"Content-Type": "application/json", "Content-Length": str(len(payload))})
        return identifier


def import_manifests(manifests, directory, tools, api, limit=1, deadline=240,
                     downloader=download, writer=atomic_json, max_consecutive_failures=5, workers=4):
    for manifest in manifests:
        validate_manifest(manifest)
    selected = {}
    for manifest in manifests:
        for entry in manifest["entries"]:
            identifier = entry["videoId"]
            if identifier and entry["available"] is not False and identifier not in selected and len(selected) < limit:
                selected[identifier] = entry
    outcomes = {}
    report = {"schema": "musiccloud.audio-import.v1", "source": "youtube-music", "limit": limit, "workers": workers,
              "sourceComplete": all(item["complete"] is True for item in manifests), "complete": False,
              "attemptedUnique": 0, "importedUnique": 0, "failedUnique": 0, "paused": False,
              "pauseReason": None, "playlists": []}
    consecutive_failures = 0

    def snapshot():
        playlists = []
        for manifest in manifests:
            rows = []
            for entry in manifest["entries"]:
                identifier = entry["videoId"]
                if entry["available"] is False:
                    result = {"status": "unavailable", "reason": "source-marked-unavailable"}
                elif not identifier:
                    result = {"status": "unavailable", "reason": "no-video-id"}
                else:
                    default = {"status": "pending", "reason": "paused-after-consecutive-failures" if report["paused"]
                               else "selected-for-current-run"} if identifier in selected else {
                        "status": "deferred", "reason": "outside-current-limit"}
                    result = outcomes.get(identifier, default)
                rows.append({"position": entry["position"], "videoId": identifier, "title": entry["title"],
                             "artists": entry["artists"], **result})
            playlists.append({"playlistId": manifest["playlistId"], "title": manifest["title"],
                              "reportedCount": manifest["reportedCount"], "extractedCount": manifest["extractedCount"],
                              "sourceComplete": manifest["complete"], "entries": rows})
        report["playlists"] = playlists
        report["attemptedUnique"] = len(outcomes)
        report["importedUnique"] = sum(value["status"] == "imported" for value in outcomes.values())
        report["failedUnique"] = sum(value["status"] == "failed" for value in outcomes.values())
        report["complete"] = report["sourceComplete"] and all(
            row["status"] == "imported" for playlist in playlists for row in playlist["entries"])
        writer(directory / "download-report.json", report)

    api.ready()
    snapshot()
    cancel_event = threading.Event()
    worker_tools = {**tools, "cancel_event": cancel_event}
    remaining = iter(selected)
    pending = {}
    pool = ThreadPoolExecutor(max_workers=workers, thread_name_prefix="musiccloud-download")

    def fill_workers():
        while len(pending) < workers and not cancel_event.is_set():
            identifier = next(remaining, None)
            if identifier is None:
                break
            future = pool.submit(downloader, identifier, directory, worker_tools, deadline)
            pending[future] = identifier

    try:
        fill_workers()
        while pending and not report["paused"]:
            completed, _ = wait(pending, return_when=FIRST_COMPLETED)
            for future in completed:
                identifier = pending.pop(future)
                entry = selected[identifier]
                try:
                    path, information, reused = future.result()
                    # This coordinator alone mutates the API, source-ID union,
                    # outcomes and report. Workers only download/verify files.
                    track_id = api.import_audio(path, information, entry)
                    outcomes[identifier] = {"status": "imported", "fileName": path.name, "sha256": information["sha256"],
                                            "duration": information["duration"], "bytes": information["bytes"],
                                            "reusedDownload": reused, "trackId": track_id}
                    consecutive_failures = 0
                except ImportFailure as error:
                    outcomes[identifier] = {"status": "failed", "reason": str(error)}
                    consecutive_failures += 1
                except (OSError, ValueError, TypeError, KeyError):
                    outcomes[identifier] = {"status": "failed", "reason": "local-processing-failed"}
                    consecutive_failures += 1
                if consecutive_failures >= max_consecutive_failures:
                    report["paused"] = True
                    report["pauseReason"] = outcomes[identifier]["reason"]
                    cancel_event.set()
                snapshot()
                print(json.dumps({"videoId": identifier, "status": outcomes[identifier]["status"],
                                  "importedUnique": report["importedUnique"], "failedUnique": report["failedUnique"]}), flush=True)
                if report["paused"]:
                    break
            fill_workers()
    finally:
        cancel_event.set()
        for future in pending:
            future.cancel()
        pool.shutdown(wait=True, cancel_futures=True)
    return report


def tool_file(value):
    path = Path(value).absolute()
    if path.is_symlink() or not path.is_file():
        raise ImportFailure("missing-or-unsafe-tool")
    return path.resolve()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", action="append", required=True, help="Validated playlist JSON; may be repeated.")
    parser.add_argument("--download-dir", required=True, help="Private local media/report folder outside source archives.")
    parser.add_argument("--yt-dlp", required=True, help="Official Windows executable, pinned to " + RELEASE)
    parser.add_argument("--node", required=True)
    parser.add_argument("--ffmpeg", required=True)
    parser.add_argument("--ffprobe", required=True)
    parser.add_argument("--port", type=int, default=4783)
    parser.add_argument("--limit", type=int, default=1, help="First N unique available IDs, including resumed files. Default 1.")
    parser.add_argument("--deadline", type=int, default=240, help="Seconds allowed per download process.")
    parser.add_argument("--max-consecutive-failures", type=int, default=5,
                        help="Pause rather than make further requests after this many consecutive failed IDs.")
    parser.add_argument("--workers", type=int, default=4, help="Concurrent download workers; API/report writes stay serial.")
    args = parser.parse_args(argv)
    try:
        if not 1 <= args.port <= 65535 or not 1 <= args.limit <= 10000 or not 30 <= args.deadline <= 1800 or not 1 <= args.max_consecutive_failures <= 100 or not 1 <= args.workers <= 32:
            raise ImportFailure("invalid-run-bounds")
        tools = {name: tool_file(getattr(args, name)) for name in ["yt_dlp", "node", "ffmpeg", "ffprobe"]}
        if file_hash(tools["yt_dlp"]) != OFFICIAL_SHA256:
            raise ImportFailure("official-downloader-checksum-mismatch")
        version = execute([str(tools["node"]), "--version"], 10)
        if version.returncode or not re.match(r"^v(?:2[2-9]|[3-9][0-9])\.", version.stdout.strip()):
            raise ImportFailure("node-22-or-newer-required")
        directory = Path(args.download_dir).absolute()
        if directory.is_symlink():
            raise ImportFailure("unsafe-output-path")
        directory.mkdir(parents=True, exist_ok=True)
        directory = directory.resolve()
        partial = directory / "partial"
        if partial.is_symlink():
            raise ImportFailure("unsafe-output-path")
        partial.mkdir(exist_ok=True)
        inputs = [Path(value).absolute() for value in args.manifest]
        if any(path.resolve() in {directory / "download-report.json", directory / "download-report.json.tmp"} for path in inputs):
            raise ImportFailure("manifest-output-collision")
        manifests = [validate_manifest(read_json(path)) for path in inputs]
        report = import_manifests(manifests, directory, tools, LocalMusicCloud(args.port), args.limit, args.deadline,
                                  max_consecutive_failures=args.max_consecutive_failures, workers=args.workers)
        print(json.dumps({key: report[key] for key in ["attemptedUnique", "importedUnique", "failedUnique", "complete", "paused", "pauseReason"]}))
        if report["paused"]:
            return 3
        return 0 if report["failedUnique"] == 0 else 2
    except (ImportFailure, ValueError, OSError):
        # No arbitrary exception text: libraries may include remote signed URLs.
        print("Audio import could not start. Check the manifest, official tool checksum, local server and paths.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
