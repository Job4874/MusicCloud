import Foundation

func json(_ value: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted])
}

func expectReject(_ action: () throws -> Void) {
    do { try action(); preconditionFailure("Unsafe or malformed input must be rejected.") }
    catch { }
}

func filesBelow(_ root: URL) throws -> [String: Data] {
    let fm = FileManager.default
    var result: [String: Data] = [:]
    if let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) {
        for case let url as URL in enumerator {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                result[String(url.path.dropFirst(root.path.count))] = try Data(contentsOf: url)
            }
        }
    }
    return result
}

let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("MusicCloud-production-migration-\(UUID().uuidString)", isDirectory: true)
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let docs = root.appendingPathComponent("Documents", isDirectory: true)
let support = root.appendingPathComponent("Library/Application Support/MusicCloud", isDirectory: true)
let target = support.appendingPathComponent("library-state-v3.json")
let legacy = support.appendingPathComponent("library-state.json")
let fresh = try LibraryStateReader.read(documentsURL: docs, stateURL: target, allowLegacyMigration: true, legacyStateURL: legacy)
precondition(fresh.version == 3 && fresh.playlists.isEmpty)
precondition(!fm.fileExists(atPath: docs.path) && !fm.fileExists(atPath: support.path))
try fm.createDirectory(at: docs, withIntermediateDirectories: true)

let a = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
let b = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
let original: [String: Any] = [
    "version": 1, "favoriteIDs": ["Music/a.m4a"],
    "artworkByPath": ["Music/a.m4a": "Artwork/a.jpg"],
    "futureRoot": ["nested": [true, NSNull(), "opaque"]],
    "playlists": [
        ["id": a.uuidString, "name": "Synthetic A", "trackIDs": ["Music/a.m4a"],
         "artwork": "Artwork/a.jpg", "reportedCount": 5, "observedCount": 4, "sourceComplete": false,
         "futurePlaylist": ["retained": true], "entries": [
            ["id": "same-source-id", "title": "First", "artist": "Example", "path": "Music/a.m4a", "status": "downloaded", "videoId": "synthetic-video", "artwork": "Artwork/a.jpg", "sourceAvailable": true, "sourcePosition": 1, "futureEntry": ["opaque": [1, 2, 3]]],
            ["id": "missing", "title": "Missing", "artist": "Example", "path": "Music/missing.m4a", "status": "missing", "sourceAvailable": true],
            ["id": "unavailable", "title": "Unavailable", "artist": "Example", "path": NSNull(), "status": "unavailable", "sourceAvailable": false],
            ["id": "same-source-id", "title": "Repeat", "artist": "Example", "path": "Music/a.m4a", "status": "future-status"]
         ]],
        ["id": b.uuidString, "name": "Synthetic B", "trackIDs": ["Music/b.m4a", "Music/b.m4a"]]
    ]
]
let sourceBytes = try json(original)
let olderName = "MusicCloud-playlists-live-20261001-120000000Z.json"
let newestName = "MusicCloud-playlists-live-20261002-120000000Z.json"
try json(["version": 1, "favoriteIDs": [], "playlists": []]).write(to: docs.appendingPathComponent(olderName))
try sourceBytes.write(to: docs.appendingPathComponent(newestName))
let favoritesBytes = try json(["Music/b.m4a", "Music/b.m4a"])
let orderBytes = try json([b.uuidString, "opaque-system-row", a.uuidString])
try favoritesBytes.write(to: docs.appendingPathComponent(".musiccloud-favorites.json"))
try orderBytes.write(to: docs.appendingPathComponent(".musiccloud-playlist-order.json"))
try json(["mode": "all", "playlistID": ""]).write(to: docs.appendingPathComponent(".musiccloud-view.json"))
try json(["sha256": String(repeating: "0", count: 64)]).write(to: docs.appendingPathComponent(".musiccloud-artwork-import.json"))
try json(["version": 1, "packSha256": String(repeating: "0", count: 64), "files": [["path": "Artwork/a.jpg", "offset": 0, "length": 3]]]).write(to: docs.appendingPathComponent("Artwork-index.json"))
try Data([1, 2, 3]).write(to: docs.appendingPathComponent("Artwork.pack"))
let before = try filesBelow(root)
expectReject { _ = try LibraryStateReader.read(documentsURL: docs, stateURL: target) }
var migrated = try LibraryStateReader.read(documentsURL: docs, stateURL: target, allowLegacyMigration: true)
let after = try filesBelow(root)
precondition(before == after && !fm.fileExists(atPath: support.path), "Production reader must make no writes.")
precondition(migrated.version == 3 && migrated.playlists.map(\.id) == [b, a])
precondition(migrated.favoriteIDs == ["Music/b.m4a"])
precondition(migrated.legacyArchive?.sourceFilename == newestName)
precondition(migrated.legacyArchive?.originalExportData == sourceBytes)
precondition(migrated.legacyArchive?.sidecarData[".musiccloud-favorites.json"] == favoritesBytes)
precondition(migrated.legacyArchive?.sidecarData[".musiccloud-playlist-order.json"] == orderBytes)
let rich = migrated.playlists[1]
precondition(rich.trackIDs == ["Music/a.m4a", "Music/missing.m4a", "Music/a.m4a"])
precondition(rich.entries?.map(\.status) == ["downloaded", "missing", "unavailable", "future-status"])
precondition(rich.entries?.count == 4 && Set(rich.entries!.map(\.id)).count == 4)
precondition(rich.entries?[2].trackID == nil && rich.entries?[1].trackID == "Music/missing.m4a")
precondition(rich.entries?[0].sourceVideoID == "synthetic-video")
precondition(migrated.playlists[0].entries == nil && migrated.playlists[0].trackIDs.count == 2)
let retained = try LegacyExportSnapshot(data: migrated.legacyArchive!.originalExportData)
let originalTree = try JSONDecoder().decode(JSONValue.self, from: sourceBytes)
precondition(retained.raw == originalTree && retained.artworkByPath.count == 1)
if case .object(let fields)? = rich.entries?[0].legacyData {
    precondition(fields["futureEntry"] != nil && fields["sourcePosition"] != nil)
} else { preconditionFailure("Entry raw metadata must be retained.") }

// Committing is explicitly simulated by this test, never by the reader.
let stableIDs = rich.entries!.map(\.id)
migrated.playlists[1].name = "Edited after migration"
migrated.playlists[1].entries![0].title = "Edited title"
try LibrarySchemaGuard.validateState(migrated)
let encoded = try JSONEncoder().encode(migrated)
try LibrarySchemaGuard.validate(encoded)
try fm.createDirectory(at: support, withIntermediateDirectories: true)
try encoded.write(to: target)
try json([]).write(to: docs.appendingPathComponent(".musiccloud-favorites.json"))
try json([]).write(to: docs.appendingPathComponent(".musiccloud-playlist-order.json"))
let restarted = try LibraryStateReader.read(documentsURL: docs, stateURL: target, allowLegacyMigration: true)
precondition(restarted.playlists[1].name == "Edited after migration")
precondition(restarted.playlists[1].entries?[0].title == "Edited title")
precondition(restarted.playlists[1].entries?.map(\.id) == stableIDs)
precondition(restarted.favoriteIDs == ["Music/b.m4a"], "Restart must not re-apply original favorites.")
precondition(restarted.legacyArchive?.originalExportData == sourceBytes)

// Unknown structural state fields are rejected, opaque archived fields are kept.
var unknownState = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
unknownState["futureStructuralField"] = true
let unknownBytes = try json(unknownState)
expectReject { try LibrarySchemaGuard.validate(unknownBytes) }
var duplicateIDs = migrated
duplicateIDs.playlists[1].entries![1].id = duplicateIDs.playlists[1].entries![0].id
expectReject { try LibrarySchemaGuard.validateState(duplicateIDs) }
try fm.removeItem(at: target)
try favoritesBytes.write(to: docs.appendingPathComponent(".musiccloud-favorites.json"))
try orderBytes.write(to: docs.appendingPathComponent(".musiccloud-playlist-order.json"))

let malformedNewest = docs.appendingPathComponent("MusicCloud-playlists-live-20261003-120000000Z.json")
try Data("{invalid".utf8).write(to: malformedNewest)
let malformedBefore = try filesBelow(root)
expectReject { _ = try LibraryStateReader.read(documentsURL: docs, stateURL: target, allowLegacyMigration: true) }
let malformedAfter = try filesBelow(root)
precondition(malformedBefore == malformedAfter, "Do not fall back to a stale export or alter a malformed one.")
try fm.removeItem(at: malformedNewest)
try json(["../outside.m4a"]).write(to: docs.appendingPathComponent(".musiccloud-favorites.json"))
expectReject { _ = try LibraryStateReader.read(documentsURL: docs, stateURL: target, allowLegacyMigration: true) }
try favoritesBytes.write(to: docs.appendingPathComponent(".musiccloud-favorites.json"))
try json([UUID().uuidString]).write(to: docs.appendingPathComponent(".musiccloud-playlist-order.json"))
expectReject { _ = try LibraryStateReader.read(documentsURL: docs, stateURL: target, allowLegacyMigration: true) }
try orderBytes.write(to: docs.appendingPathComponent(".musiccloud-playlist-order.json"))

// An old native state upgrades into a new destination without altering source.
let cleanDocs = root.appendingPathComponent("NativeDocuments", isDirectory: true)
try fm.createDirectory(at: cleanDocs, withIntermediateDirectories: true)
let oldBytes = try json(["version": 1, "favoriteIDs": ["Music/a.m4a"], "playlists": [["id": a.uuidString, "name": "Native", "trackIDs": ["Music/a.m4a"]]]])
try oldBytes.write(to: legacy)
let native = try LibraryStateReader.read(documentsURL: cleanDocs, stateURL: target, allowLegacyMigration: true, legacyStateURL: legacy)
precondition(native.version == 3 && native.playlists[0].entries == nil && native.legacyArchive == nil)
let oldAfter = try Data(contentsOf: legacy)
precondition(oldAfter == oldBytes && !fm.fileExists(atPath: target.path))

// A size cap is checked against metadata before attempting a large allocation.
let oversized = support.appendingPathComponent("oversized.json")
fm.createFile(atPath: oversized.path, contents: Data())
let oversizedHandle = try FileHandle(forWritingTo: oversized)
try oversizedHandle.truncate(atOffset: UInt64(LibraryStateReader.maximumStateBytes + 1))
try oversizedHandle.close()
expectReject { _ = try LibraryStateReader.read(documentsURL: cleanDocs, stateURL: oversized, allowLegacyMigration: true) }

print("Production migration checks passed: reader is read-only; rich records/raw originals/sidecars retained; v3 restarts preserve edits; unsafe and malformed inputs protect the library.")
