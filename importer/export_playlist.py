"""Export YouTube Music playlist metadata. No audio download or signing secrets."""

import argparse
import json
import os
import sys
import tempfile
from pathlib import Path

from musiccloud_manifest import ManifestError, normalize_playlist, playlist_id
from ytmusic_adapter import AdapterError, fetch_playlist


def inside(child, parent):
    try:
        child.relative_to(parent)
        return True
    except ValueError:
        return False


def export(auth_path, identifier, output, liked=False, overwrite=False, fetcher=fetch_playlist, public=False):
    if public and (auth_path is not None or liked):
        raise ManifestError("Public browsing supports a playlist URL/ID without authentication; liked music requires --auth.")
    if not public and auth_path is None:
        raise ManifestError("Provide --public for a public playlist, or --auth for your local browser authentication.")
    auth_path = Path(auth_path).expanduser().resolve() if auth_path is not None else None
    output = Path(output).expanduser().resolve()
    project = Path(__file__).resolve().parent.parent
    if auth_path is not None and inside(auth_path, project):
        raise ManifestError("Keep authentication outside the MusicCloud project, for example in your private LocalAppData folder.")
    if output == auth_path:
        raise ManifestError("The output must be separate from your authentication file.")
    if auth_path is not None:
        if not auth_path.is_file() or auth_path.stat().st_size > 128 * 1024:
            raise ManifestError("The local authentication file is missing or invalid. Run the browser authentication setup locally.")
        try:
            auth = json.loads(auth_path.read_text(encoding="utf-8-sig"))
            keys = {str(key).lower() for key in auth} if isinstance(auth, dict) else set()
            if not {"authorization", "cookie"}.issubset(keys):
                raise ValueError
        except (OSError, ValueError):
            raise ManifestError("Use the complete local browser authentication file. A bearer token or API key alone is insufficient.") from None
    if output.exists() and not overwrite:
        raise ManifestError("The output already exists. Choose another filename or explicitly use --overwrite.")
    if not output.parent.is_dir():
        raise ManifestError("Create the output folder first.")
    identifier = "LM" if liked else playlist_id(identifier)
    payload, warnings, uncertain = fetcher(auth_path, identifier, liked=liked)
    manifest = normalize_playlist(payload, identifier, warnings, uncertain)
    temp_name = None
    try:
        descriptor, temp_name = tempfile.mkstemp(prefix=".musiccloud-playlist-", suffix=".tmp", dir=output.parent)
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as handle:
            json.dump(manifest, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        try:
            if overwrite:
                os.replace(temp_name, output)
            elif os.name == "nt":
                # Windows rename is atomic and fails if the destination exists.
                os.rename(temp_name, output)
            else:
                # Atomic exclusive publication; a competing writer is never replaced.
                try:
                    os.link(temp_name, output)
                except FileExistsError:
                    raise
                except OSError:
                    raise ManifestError("This output filesystem does not support safe exclusive publication. Choose another folder or explicitly use --overwrite.") from None
        except FileExistsError:
            raise ManifestError("The output was created by another program during export; it was preserved.") from None
        return manifest
    finally:
        if temp_name and os.path.exists(temp_name):
            os.unlink(temp_name)


def main(argv=None):
    parser = argparse.ArgumentParser(description="Export all returned YouTube Music playlist entries as audited metadata. No audio is downloaded.")
    auth_group = parser.add_mutually_exclusive_group(required=True)
    auth_group.add_argument("--auth", type=Path, help="Local browser-auth JSON outside the project; never paste it into chat.")
    auth_group.add_argument("--public", action="store_true", help="Read a public/unlisted playlist without credentials.")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--playlist", help="YouTube Music playlist URL or ID.")
    group.add_argument("--liked", action="store_true", help="Export the authenticated account's liked music.")
    parser.add_argument("--output", required=True, type=Path, help="Destination JSON manifest.")
    parser.add_argument("--overwrite", action="store_true", help="Replace an existing metadata output.")
    args = parser.parse_args(argv)
    if args.public and args.liked:
        parser.error("--liked requires --auth; it cannot be used with --public.")
    try:
        result = export(args.auth, args.playlist, args.output, args.liked, args.overwrite, public=args.public)
    except (ManifestError, AdapterError) as error:
        print(f"MusicCloud import: {error}", file=sys.stderr)
        return 1
    except (OSError, ValueError):
        print("MusicCloud import: a local file could not be read or written. Check file permissions and available space. No authentication details were logged.", file=sys.stderr)
        return 1
    except Exception:
        print("MusicCloud import: an unexpected error stopped the export. No authentication details were logged.", file=sys.stderr)
        return 1
    status = "COMPLETE" if result["complete"] is True else "PARTIAL" if result["complete"] is False else "UNVERIFIED"
    count = result["reportedCount"] if result["reportedCount"] is not None else "unknown"
    print(f"{status}: wrote {result['extractedCount']} entries; reported total {count}. Metadata only; no audio downloaded.")
    for warning in result["warnings"]:
        print(f"Warning: {warning}")
    return 0 if result["complete"] is True else 2 if result["complete"] is False else 3


if __name__ == "__main__":
    sys.exit(main())
