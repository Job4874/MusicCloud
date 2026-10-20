"""Create source/portable ZIPs from an exact allowlist. No private directory sweep."""

import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import sys
import tempfile
import zipfile

PROJECT = Path(__file__).resolve().parents[1]
ZIP_ROOT = "MusicCloud"
SCHEMA = "musiccloud.package.v1"

# Adding a new distributable file requires an explicit entry here. Writable app
# data, account exports, screenshots, device reports and credentials are absent.
SOURCE_FILES = (
    ".gitignore",
    "README.md",
    "LICENSE.txt",
    "START-MUSICCLOUD.cmd",
    "STOP-MUSICCLOUD.cmd",
    ".github/workflows/build-iphone.yml",
    "codemagic.yaml",
    "desktop/package.json",
    "desktop/server.mjs",
    "desktop/catalog-store.mjs",
    "desktop/launcher-common.mjs",
    "desktop/launch.mjs",
    "desktop/stop.mjs",
    "desktop/public/index.html",
    "desktop/public/app.js",
    "desktop/public/style.css",
    "desktop/public/icon.svg",
    "desktop/tests/server.test.mjs",
    "desktop/tests/launcher.test.mjs",
    "desktop/tests/catalog.test.mjs",
    "iphone/README.md",
    "iphone/build-unsigned.sh",
    "iphone/check-models.sh",
    "iphone/tools/check-project.cjs",
    "iphone/tools/generate-icon.cjs",
    "iphone/Tests/main.swift",
    "iphone/MusicCloud.xcodeproj/project.pbxproj",
    "iphone/MusicCloud.xcodeproj/xcshareddata/xcschemes/MusicCloud.xcscheme",
    "iphone/MusicCloud/MusicCloudApp.swift",
    "iphone/MusicCloud/Models.swift",
    "iphone/MusicCloud/LibraryStore.swift",
    "iphone/MusicCloud/LibraryViews.swift",
    "iphone/MusicCloud/PlaybackController.swift",
    "iphone/MusicCloud/PlayerViews.swift",
    "iphone/MusicCloud/PlaylistViews.swift",
    "iphone/MusicCloud/TransferView.swift",
    "iphone/MusicCloud/Info.plist",
    "iphone/MusicCloud/Assets.xcassets/Contents.json",
    "iphone/MusicCloud/Assets.xcassets/AppIcon.appiconset/Contents.json",
    "iphone/MusicCloud/Assets.xcassets/AppIcon.appiconset/AppIcon.png",
    "importer/.gitignore",
    "importer/README.md",
    "importer/requirements.txt",
    "importer/musiccloud_manifest.py",
    "importer/ytmusic_adapter.py",
    "importer/export_playlist.py",
    "importer/batch_export.py",
    "importer/har_playlist.py",
    "importer/download_audio.py",
    "importer/validate-manifest.mjs",
    "importer/tests/test_importer.py",
    "importer/tests/test_har_playlist.py",
    "importer/tests/test_download_audio.py",
    "importer/tests/manifest.test.mjs",
    "docs/USB-AND-INSTALL.md",
    "docs/MAINTENANCE.md",
    "docs/YOUTUBE-IMPORT.md",
    "docs/CODEMAGIC-FALLBACK.md",
    "runtime/LICENSE",
    "runtime/README.txt",
    "runtime/SHA256SUMS.txt",
    "tools/package.py",
    "tools/package.mjs",
)
PORTABLE_ONLY = ("runtime/node.exe",)
EXCLUDED = (
    "desktop/data and all local music, catalogs, favorites, playlists, logs and shutdown tokens",
    "playlist-exports and all personal playlist metadata/import reports",
    "docs/youtube-desktop-installed.jpg and docs/DEVICE-CHECK.md",
    "authentication/header/token files, .env files and signing credentials",
    ".git, caches, __pycache__, virtual environments, work folders and compiled builds",
    "runtime/node.exe is excluded from the source archive and included only in the portable archive",
)
SECRET_PATTERNS = (
    re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    re.compile(rb"\bAIza[0-9A-Za-z_-]{35}\b"),
    re.compile(rb"\bBearer\s+[A-Za-z0-9._~-]{40,}", re.IGNORECASE),
    re.compile(rb"\bSAPISIDHASH\s+\d{8,}_[0-9a-f]{40}\b", re.IGNORECASE),
    re.compile(rb"__Secure-3PAPISID=[A-Za-z0-9._~-]{16,}"),
)


class PackageError(RuntimeError):
    pass


def sha256(content):
    return hashlib.sha256(content).hexdigest()


def json_bytes(value):
    return (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode("utf-8")


def source_bytes(relative):
    pure = PurePosixPath(relative)
    if pure.is_absolute() or ".." in pure.parts or "\\" in relative:
        raise PackageError("The source allowlist contains an unsafe path.")
    target = PROJECT.joinpath(*pure.parts)
    if not target.resolve().is_relative_to(PROJECT):
        raise PackageError(f"An allowlisted source is outside the project: {relative}")
    for ancestor in (target, *target.parents):
        if ancestor == PROJECT.parent:
            break
        if ancestor.is_symlink():
            raise PackageError(f"An allowlisted path is a symlink: {relative}")
    try:
        info = target.stat()
        if not stat.S_ISREG(info.st_mode):
            raise PackageError(f"An allowlisted source is not an ordinary file: {relative}")
        data = target.read_bytes()
    except OSError:
        raise PackageError(f"A required source file could not be read: {relative}") from None
    if relative != "runtime/node.exe" and target.suffix.lower() not in {".png", ".jpg"}:
        for pattern in SECRET_PATTERNS:
            if pattern.search(data):
                raise PackageError(f"Possible credential material in allowlisted source {relative}; packaging stopped without printing the matching content.")
    return data


def runtime_integrity(contents):
    try:
        lines = contents["runtime/SHA256SUMS.txt"].decode("ascii").splitlines()
        expected = {}
        for line in lines:
            digest, name = line.split()
            if not re.fullmatch(r"[0-9a-fA-F]{64}", digest) or name not in {"node.exe", "LICENSE"}:
                raise ValueError
            expected[name] = digest.lower()
        if set(expected) != {"node.exe", "LICENSE"}:
            raise ValueError
        for name, digest in expected.items():
            if sha256(contents[f"runtime/{name}"]) != digest:
                raise ValueError
    except (KeyError, UnicodeError, ValueError):
        raise PackageError("The bundled Node executable/license do not match runtime/SHA256SUMS.txt.") from None


def member_record(relative, content, generated=False):
    return {"path": f"{ZIP_ROOT}/{relative}", "bytes": len(content), "sha256": sha256(content), **({"generated": True} if generated else {})}


def package_notes(kind):
    if kind == "source":
        intro = "SOURCE ARCHIVE: node.exe is intentionally omitted.\nInstall Node.js 22 or newer and run: node desktop/server.mjs\nOr use MusicCloud-Windows.zip for the included portable Windows x64 runtime.\n"
    else:
        intro = "WINDOWS PORTABLE ARCHIVE: extract the entire MusicCloud folder to a writable location.\nDouble-click START-MUSICCLOUD.cmd. No Python or npm install is required for the player.\nUse STOP-MUSICCLOUD.cmd to stop its managed local server.\n"
    return (intro + "\nThis is a clean app package. No personal audio, playlist metadata, credentials,\naccount screenshots, device report or current desktop/data is included.\nThe app creates a fresh empty library on its first launch.\n\nThe iPhone project is source code. No compiled/signed/installable IPA is included.\nSee README.md and docs/USB-AND-INSTALL.md for its separate build/sign/install steps.\n\nPACKAGE-MANIFEST.json lists hashes of the included source/runtime files.\nThe external package manifest also records this ZIP's SHA-256 hash.\n").encode("utf-8")


def atomic_json(target, content):
    descriptor, temporary = tempfile.mkstemp(prefix=".musiccloud-package-", suffix=".tmp", dir=target.parent)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(content)
        os.replace(temporary, target)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def create_package(kind, contents, output_dir, generated_at):
    selected = list(SOURCE_FILES) + (list(PORTABLE_ONLY) if kind == "windows-portable" else [])
    packaged = {relative: contents[relative] for relative in selected}
    packaged["PACKAGE-NOTES.txt"] = package_notes("source" if kind == "source" else "portable")
    records = [member_record(relative, content, relative == "PACKAGE-NOTES.txt") for relative, content in sorted(packaged.items())]
    embedded = {"schema": SCHEMA, "kind": kind, "generatedAt": generated_at, "root": ZIP_ROOT, "fileCount": len(records), "manifestSelfExcluded": True, "exclusions": list(EXCLUDED), "files": records}
    embedded_bytes = json_bytes(embedded)
    packaged["PACKAGE-MANIFEST.json"] = embedded_bytes
    archive_name = "MusicCloud-source.zip" if kind == "source" else "MusicCloud-Windows.zip"
    manifest_name = "MusicCloud-source-manifest.json" if kind == "source" else "MusicCloud-Windows-manifest.json"
    archive = output_dir / archive_name
    descriptor, temporary = tempfile.mkstemp(prefix=".musiccloud-zip-", suffix=".tmp", dir=output_dir)
    os.close(descriptor)
    try:
        with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6, allowZip64=True) as writer:
            stamp = datetime.datetime.fromisoformat(generated_at)
            date_time = (stamp.year, stamp.month, stamp.day, stamp.hour, stamp.minute, stamp.second)
            for relative, content in sorted(packaged.items()):
                info = zipfile.ZipInfo(f"{ZIP_ROOT}/{relative}", date_time=date_time)
                info.compress_type = zipfile.ZIP_DEFLATED
                info.create_system = 3
                mode = 0o755 if relative.endswith((".sh", ".exe")) else 0o644
                info.external_attr = (stat.S_IFREG | mode) << 16
                writer.writestr(info, content, compress_type=zipfile.ZIP_DEFLATED, compresslevel=6)
        with zipfile.ZipFile(temporary, "r") as reader:
            expected = {f"{ZIP_ROOT}/{relative}" for relative in packaged}
            if len(reader.namelist()) != len(expected) or set(reader.namelist()) != expected or reader.testzip() is not None:
                raise PackageError("The generated ZIP failed its file/integrity audit.")
            for record in records:
                if sha256(reader.read(record["path"])) != record["sha256"]:
                    raise PackageError("A packaged file did not match its manifest hash.")
        os.replace(temporary, archive)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    archive_bytes = archive.read_bytes()
    external = {**embedded, "fileCount": len(packaged), "manifestSelfExcluded": False, "files": [*records, member_record("PACKAGE-MANIFEST.json", embedded_bytes, True)], "archive": {"file": archive_name, "bytes": len(archive_bytes), "sha256": sha256(archive_bytes)}}
    atomic_json(output_dir / manifest_name, json_bytes(external))
    return external


def build(output_dir):
    output_dir = Path(output_dir).resolve()
    if output_dir.is_relative_to(PROJECT):
        raise PackageError("Write package outputs outside the application folder.")
    output_dir.mkdir(parents=True, exist_ok=True)
    contents = {relative: source_bytes(relative) for relative in (*SOURCE_FILES, *PORTABLE_ONLY)}
    if len(SOURCE_FILES) != len(set(SOURCE_FILES)):
        raise PackageError("The source allowlist contains duplicate paths.")
    runtime_integrity(contents)
    generated_at = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")
    manifests = [create_package(kind, contents, output_dir, generated_at) for kind in ("source", "windows-portable")]
    for manifest in manifests:
        print(f"Created {manifest['archive']['file']}: {manifest['fileCount']} files, {manifest['archive']['bytes']} bytes, SHA-256 {manifest['archive']['sha256']}")
    return manifests


def main(argv=None):
    parser = argparse.ArgumentParser(description="Build clean MusicCloud source and Windows ZIPs from a strict file allowlist.")
    parser.add_argument("--output-dir", type=Path, default=PROJECT.parent)
    args = parser.parse_args(argv)
    try:
        build(args.output_dir)
    except (PackageError, OSError, ValueError, zipfile.BadZipFile) as error:
        print(f"MusicCloud packaging failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
