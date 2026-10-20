"""Bounded public-playlist metadata exports with an entry for every discovered list."""

import argparse
import concurrent.futures
import datetime
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

from musiccloud_manifest import ManifestError, playlist_id, validate_manifest


def timestamp():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def write_json(target, value):
    descriptor, temp = tempfile.mkstemp(prefix=".musiccloud-audit-", suffix=".tmp", dir=target.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as handle:
            json.dump(value, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
        os.replace(temp, target)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def run_batch(discovery_path, output_dir, workers=1, seconds=180, refresh=False, runner=subprocess.run):
    if workers not in (1, 2) or not 10 <= seconds <= 900:
        raise ManifestError("Use one or two workers and a per-playlist timeout from 10 to 900 seconds.")
    discovery = json.loads(Path(discovery_path).read_text(encoding="utf-8-sig"))
    if not isinstance(discovery, dict) or not isinstance(discovery.get("playlists"), list):
        raise ManifestError("Use a discovery JSON with a playlists array.")
    output_dir = Path(output_dir).resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    report_path = output_dir / "IMPORT-REPORT.json"
    entries = []
    seen = set()
    for descriptor in discovery["playlists"]:
        if not isinstance(descriptor, dict):
            raise ManifestError("Every discovery entry needs a playlist ID.")
        identifier = playlist_id(descriptor.get("playlistId"))
        if identifier in seen:
            raise ManifestError("The discovery contains duplicate playlist IDs; resolve them before batching.")
        seen.add(identifier)
        observed_count = descriptor.get("reportedCount")
        if type(observed_count) is not int or observed_count < 0:
            observed_count = None
        entries.append({"playlistId": identifier, "title": descriptor.get("title") if isinstance(descriptor.get("title"), str) else identifier, "observedReportedCount": observed_count, "status": "requires-auth" if identifier in {"LM", "SE"} else "pending", "reportedCount": None, "extractedCount": None, "complete": None, "manifest": None, "error": "This account-only list requires locally supplied authentication; no unauthenticated request was attempted." if identifier in {"LM", "SE"} else None})
    report = {"schema": "musiccloud.import-report.v1", "source": "youtube-music", "discoveryComplete": discovery.get("complete") is True, "complete": False, "startedAt": timestamp(), "updatedAt": timestamp(), "finishedAt": None, "playlistCount": len(entries), "playlists": entries}
    write_json(report_path, report)

    def process(entry):
        identifier = entry["playlistId"]
        target = output_dir / f"{identifier}.json"
        if not target.exists() or refresh:
            command = [sys.executable, str(Path(__file__).with_name("export_playlist.py")), "--public", "--playlist", identifier, "--output", str(target)]
            if refresh:
                command.append("--overwrite")
            try:
                result = runner(command, capture_output=True, text=True, timeout=seconds, check=False)
            except subprocess.TimeoutExpired:
                return {**entry, "status": "timeout", "error": "The public export exceeded its per-playlist deadline. No retry was attempted."}
            except OSError:
                return {**entry, "status": "failed", "error": "The local export process could not start. No retry was attempted."}
            if result.returncode not in (0, 2, 3) or not target.is_file():
                # Never persist raw exception text or upstream request details.
                return {**entry, "status": "failed", "error": "The public metadata export failed. Playlist access, network conditions, or the service response may require attention. No retry was attempted."}
        try:
            manifest = validate_manifest(json.loads(target.read_text(encoding="utf-8")))
            if manifest["playlistId"] != identifier:
                raise ManifestError("Wrong playlist ID.")
        except (OSError, ValueError):
            return {**entry, "status": "invalid-manifest", "error": "The existing/exported file did not pass metadata validation and was preserved for review."}
        observed = entry["observedReportedCount"]
        if observed is not None and manifest["extractedCount"] != observed:
            manifest["complete"] = False
            warning = f"Library UI count audit: observed {observed} entries but exported {manifest['extractedCount']}. Review for missing entries or playlist changes."
            if warning not in manifest["warnings"]:
                manifest["warnings"].append(warning)
            write_json(target, manifest)
        status = "complete" if manifest["complete"] is True else "partial" if manifest["complete"] is False else "unverified"
        return {**entry, "status": status, "reportedCount": manifest["reportedCount"], "extractedCount": manifest["extractedCount"], "complete": manifest["complete"], "manifest": target.name, "error": None}

    pending = [(index, entry) for index, entry in enumerate(entries) if entry["status"] == "pending"]
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as executor:
        futures = {executor.submit(process, entry): index for index, entry in pending}
        for future in concurrent.futures.as_completed(futures):
            index = futures[future]
            try:
                entries[index] = future.result()
            except Exception:
                entries[index] = {**entries[index], "status": "failed", "error": "A local export error occurred. No request details were logged and no retry was attempted."}
            report["updatedAt"] = timestamp()
            write_json(report_path, report)
            print(f"{entries[index]['playlistId']}: {entries[index]['status']}", flush=True)
    report["complete"] = report["discoveryComplete"] and all(entry["status"] == "complete" for entry in entries)
    report["finishedAt"] = timestamp()
    report["updatedAt"] = report["finishedAt"]
    report["summary"] = {status: sum(entry["status"] == status for entry in entries) for status in sorted({entry["status"] for entry in entries})}
    write_json(report_path, report)
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description="Export discovered public playlist metadata with a complete per-playlist audit. No credentials or audio downloads.")
    parser.add_argument("--public", required=True, action="store_true", help="Explicitly use unauthenticated public browsing only.")
    parser.add_argument("--discovery", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--workers", type=int, choices=(1, 2), default=1)
    parser.add_argument("--timeout", type=int, default=180, help="Per-playlist process deadline in seconds; no automatic retries.")
    parser.add_argument("--refresh", action="store_true", help="Re-fetch existing metadata manifests.")
    args = parser.parse_args(argv)
    try:
        report = run_batch(args.discovery, args.output_dir, args.workers, args.timeout, args.refresh)
    except (OSError, ValueError):
        print("MusicCloud batch export could not read or write its local discovery/report files. No request details were logged.", file=sys.stderr)
        return 1
    print(f"Audited {report['playlistCount']} discovered playlists. Report completeness: {report['complete']}.")
    return 0 if report["complete"] else 2


if __name__ == "__main__":
    sys.exit(main())
