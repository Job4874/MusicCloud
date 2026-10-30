import Foundation

// Entirely synthetic. No device data, private filenames or user fixtures.
let source = Data(#"""
{
  "version": 1,
  "favoriteIDs": ["Music/a.m4a", "Music/a.m4a"],
  "artworkByPath": {"Music/a.m4a": "Artwork/a.jpg"},
  "futureRoot": {"nested": [null, true, {"preciseInteger": 9007199254740993}]},
  "playlists": [{
    "id": "synthetic-opaque-id", "name": "Example",
    "trackIDs": ["Music/a.m4a", "Music/a.m4a", "Music/b.m4a"],
    "artwork": "Artwork/a.jpg", "sourceComplete": false,
    "observedCount": 4, "reportedCount": 7,
    "downloadedCount": 1, "missingCount": 1, "unavailableCount": 1,
    "futurePlaylist": {"value": "preserved"},
    "entries": [
      {"id":"one", "title":"First", "artist":"Example", "videoId":"synthetic-video", "path":"Music/a.m4a", "status":"downloaded", "artwork":"Artwork/a.jpg", "sourceAvailable":true, "sourcePosition":2, "futureEntry":{"opaque":[1,2,3]}},
      {"id":"two", "title":"Second", "artist":"Example", "path":"", "status":"missing", "sourceAvailable":true, "sourcePosition":4},
      {"id":"three", "title":"Third", "artist":"Example", "path":null, "status":"unavailable", "sourceAvailable":false},
      {"id":"one", "title":"Duplicate retained", "artist":"Example", "path":"Music/a.m4a", "status":"future-status", "artwork":null}
    ]
  }]
}
"""#.utf8)

let snapshot = try LegacyExportSnapshot(data: source)
precondition(snapshot.originalData == source, "Original export bytes are authoritative and retained exactly.")
precondition(snapshot.favoriteIDs.count == 2 && snapshot.favoriteIDs[0] == snapshot.favoriteIDs[1])
let playlist = snapshot.playlists[0]
precondition(playlist.trackIDs.map(\.rawValue) == ["Music/a.m4a", "Music/a.m4a", "Music/b.m4a"])
precondition(playlist.entries.map(\.status) == ["downloaded", "missing", "unavailable", "future-status"])
precondition(playlist.entries.map(\.id) == ["one", "two", "three", "one"])
precondition(playlist.entries[1].path == nil && playlist.entries[2].path == nil)
precondition(playlist.entries[0].sourcePosition == 2 && playlist.entries[0].sourceAvailable == true)
precondition(playlist.entries[2].sourceAvailable == false)
precondition(playlist.reportedCount == 7 && playlist.observedCount == 4 && playlist.sourceComplete == false)
precondition(playlist.downloadedCount == 1 && playlist.missingCount == 1 && playlist.unavailableCount == 1)
let firstPath = try LegacyRelativePath("Music/a.m4a")
precondition(snapshot.artworkByPath[firstPath]?.rawValue == "Artwork/a.jpg")
let decodedAgain = try JSONDecoder().decode(JSONValue.self, from: snapshot.diagnosticTreeData())
precondition(decodedAgain == snapshot.raw, "Every nested unknown field must survive semantic round trip.")
precondition(snapshot.originalData == source)

// Legacy exports without entry metadata are valid too.
let old = try LegacyExportSnapshot(data: Data(#"{"version":1,"favoriteIDs":[],"playlists":[{"id":"old","name":"Old","trackIDs":["one.m4a"]}]}"#.utf8))
precondition(old.playlists[0].entries.isEmpty && old.playlists[0].trackIDs.count == 1)

func rejectUnsafe(_ path: String) {
    do {
        _ = try LegacyRelativePath(path)
        preconditionFailure("Unsafe or ambiguous path structure must be rejected.")
    } catch LegacyAdapterError.unsafePath { }
    catch { preconditionFailure("Unexpected path error.") }
}
for path in ["", "/absolute.m4a", "../escape.m4a", "a/../b.m4a", "a/./b.m4a", "a//b.m4a", "a/", "a\\b.m4a", "C:/b.m4a", "a\u{0}b.m4a"] {
    rejectUnsafe(path)
}
let unsafeExport = Data(#"{"version":1,"favoriteIDs":["../outside.m4a"],"playlists":[]}"#.utf8)
do {
    _ = try LegacyExportSnapshot(data: unsafeExport)
    preconditionFailure("Unsafe references must reject the whole projection.")
} catch LegacyAdapterError.unsafePath { }

let inventory = try LegacyPathInventory(paths: ["Music/a.m4a", "Folder A/Same.m4a", "Folder B/Same.m4a", "Artwork/a.jpg"])
let firstResolution = try inventory.resolve(playlist.entries[0].path)
let missingResolution = try inventory.resolve(playlist.entries[1].path)
let sameNamePath = try LegacyRelativePath("Same.m4a")
let sameNameResolution = try inventory.resolve(sameNamePath)
let foldedPath = try LegacyRelativePath("music/a.m4a")
let foldedResolution = try inventory.resolve(foldedPath)
precondition(firstResolution == .present(firstPath))
precondition(missingResolution == .noLocalPath)
precondition(sameNameResolution == .missing(sameNamePath), "Never choose the first filename match.")
precondition(foldedResolution == .missing(foldedPath), "Never fold case.")
let duplicateInventory = try LegacyPathInventory(paths: ["Music/a.m4a", "Music/a.m4a"])
do {
    _ = try duplicateInventory.resolve(playlist.entries[0].path)
    preconditionFailure("A duplicate exact inventory mapping must not choose a first match.")
} catch LegacyAdapterError.ambiguousPath { }

let composed = try LegacyRelativePath("Music/\u{00e9}.m4a")
let decomposed = try LegacyRelativePath("Music/e\u{0301}.m4a")
precondition(composed != decomposed, "Path matching must compare bytes, not Unicode-equivalent filenames.")
let unicodeInventory = try LegacyPathInventory(paths: [composed.rawValue])
let unicodeResolution = try unicodeInventory.resolve(decomposed)
precondition(unicodeResolution == .missing(decomposed))

print("Legacy adapter checks passed: original bytes, rich/unknown fields, entry ordering/duplicates, statuses, exact safe path resolution.")
