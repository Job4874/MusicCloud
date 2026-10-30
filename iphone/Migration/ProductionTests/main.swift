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

// Display metadata must be path-exact and unambiguous across every occurrence.
let originalDisplay = try LegacyLibraryMigration.displayMetadata(in: migrated.legacyArchive)
let conflictPath = try LegacyRelativePath("Music/a.m4a")
let knownMissingPath = try LegacyRelativePath("Music/missing.m4a")
precondition(originalDisplay[conflictPath] == nil, "Conflicting occurrence titles must not pick a first match.")
precondition(originalDisplay[knownMissingPath] == LegacyTrackDisplay(title: "Missing", artist: "Example"))
func displayEntry(_ path: String, _ title: String, _ artist: String) -> [String: Any] {
    ["id": "synthetic", "title": title, "artist": artist, "path": path, "status": "downloaded"]
}
let displayBytes = try json(["version": 1, "favoriteIDs": [], "playlists": [
    ["id": "display-one", "name": "One", "trackIDs": [], "entries": [
        displayEntry("Music/consistent.m4a", " Preserved title ", "Example"),
        displayEntry("Music/conflict.m4a", "First", "Example"),
        displayEntry("Music/artist-conflict.m4a", "Same title", "Artist A"),
        displayEntry("Music/empty.m4a", "Title", " \n"),
        displayEntry("Music/Case.m4a", "Upper path", "Example")
    ]],
    ["id": "display-two", "name": "Two", "trackIDs": [], "entries": [
        displayEntry("Music/consistent.m4a", " Preserved title ", "Example"),
        displayEntry("Music/conflict.m4a", "Second", "Example"),
        displayEntry("Music/conflict.m4a", "First", "Example"),
        displayEntry("Music/artist-conflict.m4a", "Same title", "Artist B"),
        displayEntry("Music/case.m4a", "Lower path", "Example")
    ]]
]])
let displayArchive = LegacyLibraryArchive(originalExportData: displayBytes, sourceFilename: newestName, sidecarData: [:])
let displayProjection = try LegacyLibraryMigration.displayMetadata(in: displayArchive)
let consistentPath = try LegacyRelativePath("Music/consistent.m4a")
let titleConflictPath = try LegacyRelativePath("Music/conflict.m4a")
let artistConflictPath = try LegacyRelativePath("Music/artist-conflict.m4a")
let emptyPath = try LegacyRelativePath("Music/empty.m4a")
let upperPath = try LegacyRelativePath("Music/Case.m4a")
let lowerPath = try LegacyRelativePath("Music/case.m4a")
precondition(displayProjection.count == 3)
precondition(displayProjection[consistentPath] == LegacyTrackDisplay(title: " Preserved title ", artist: "Example"))
precondition(displayProjection[titleConflictPath] == nil && displayProjection[artistConflictPath] == nil && displayProjection[emptyPath] == nil)
precondition(displayProjection[upperPath]?.title == "Upper path" && displayProjection[lowerPath]?.title == "Lower path")
let noDisplay = try LegacyLibraryMigration.displayMetadata(in: nil)
precondition(noDisplay.isEmpty && displayArchive.originalExportData == displayBytes)

// A prepared collection appends to the migrated library exactly once.
let c = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
let d = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
let preparedEntryOne = PlaylistEntry(trackID: "Music/prepared-one.m4a", title: "Prepared one", artist: "Example", status: "downloaded", legacyData: .object(["source": .string("synthetic-plan")]))
let preparedEntryTwo = PlaylistEntry(trackID: "Music/prepared-two.m4a", title: "Prepared two", artist: "Example", status: "downloaded")
var prepared = LibraryState()
prepared.playlists = [
    Playlist(id: c, name: "Prepared one", trackIDs: [preparedEntryOne.trackID!], entries: [preparedEntryOne]),
    Playlist(id: d, name: "Prepared two", trackIDs: [preparedEntryTwo.trackID!], entries: [preparedEntryTwo])
]
let preparedBytes = try JSONEncoder().encode(prepared)
let preparedURL = docs.appendingPathComponent(LegacyLibraryMigration.preparedFilename)
try preparedBytes.write(to: preparedURL)
let preparedBefore = try filesBelow(root)
let merged = try LibraryStateReader.read(documentsURL: docs, stateURL: target, allowLegacyMigration: true)
let preparedAfter = try filesBelow(root)
precondition(preparedBefore == preparedAfter)
precondition(merged.playlists.map(\.id) == [b, a, c, d])
precondition(merged.favoriteIDs == migrated.favoriteIDs && merged.trackOverrides == migrated.trackOverrides)
precondition(merged.legacyArchive == migrated.legacyArchive)
precondition(merged.playlists[2].entries?[0].legacyData == preparedEntryOne.legacyData)

func rejectPrepared(_ bad: LibraryState) throws {
    try JSONEncoder().encode(bad).write(to: preparedURL)
    expectReject { _ = try LibraryStateReader.read(documentsURL: docs, stateURL: target, allowLegacyMigration: true) }
}
var badPrepared = prepared
badPrepared.playlists[0].id = a
try rejectPrepared(badPrepared)
badPrepared = prepared
badPrepared.playlists[1].entries![0].id = preparedEntryOne.id
try rejectPrepared(badPrepared)
badPrepared = prepared
badPrepared.playlists[0].trackIDs = ["../outside.m4a"]
badPrepared.playlists[0].entries![0].trackID = "../outside.m4a"
try rejectPrepared(badPrepared)
badPrepared = prepared
badPrepared.favoriteIDs = ["Music/unrequested.m4a"]
try rejectPrepared(badPrepared)
badPrepared = prepared
badPrepared.playlists[0].entries = nil
try rejectPrepared(badPrepared)
try Data("{invalid".utf8).write(to: preparedURL)
expectReject { _ = try LibraryStateReader.read(documentsURL: docs, stateURL: target, allowLegacyMigration: true) }
try preparedBytes.write(to: preparedURL)
// Cross-library occurrence collisions are also rejected before saving.
var collidingBase = migrated
collidingBase.playlists[1].entries![0].id = preparedEntryOne.id
expectReject { _ = try LegacyLibraryMigration.appendingPreparedPlaylists(to: collidingBase, documentsURL: docs) }
migrated = merged

// A prepared-only installation needs no legacy export and never opens empty
// through the default protective reader.
let preparedOnlyDocs = root.appendingPathComponent("PreparedOnlyDocuments", isDirectory: true)
let preparedOnlyTarget = root.appendingPathComponent("PreparedOnlySupport/library-state-v3.json")
try fm.createDirectory(at: preparedOnlyDocs, withIntermediateDirectories: true)
try preparedBytes.write(to: preparedOnlyDocs.appendingPathComponent(LegacyLibraryMigration.preparedFilename))
expectReject { _ = try LibraryStateReader.read(documentsURL: preparedOnlyDocs, stateURL: preparedOnlyTarget) }
let preparedOnly = try LibraryStateReader.read(documentsURL: preparedOnlyDocs, stateURL: preparedOnlyTarget, allowLegacyMigration: true)
precondition(preparedOnly.playlists.map(\.id) == [c, d] && preparedOnly.favoriteIDs.isEmpty && !fm.fileExists(atPath: preparedOnlyTarget.path))

// Committing is explicitly simulated by this test, never by the reader.
let stableIDs = migrated.playlists[1].entries!.map(\.id)
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
precondition(restarted.playlists.map(\.id) == [b, a, c, d], "The prepared collection must not append again.")
precondition(restarted.playlists[1].name == "Edited after migration")
precondition(restarted.playlists[1].entries?[0].title == "Edited title")
precondition(restarted.playlists[1].entries?.map(\.id) == stableIDs)
precondition(restarted.favoriteIDs == ["Music/b.m4a"], "Restart must not re-apply original favorites.")
precondition(restarted.legacyArchive?.originalExportData == sourceBytes)
try Data("{invalid".utf8).write(to: preparedURL)
let restartWithMalformedPlan = try LibraryStateReader.read(documentsURL: docs, stateURL: target, allowLegacyMigration: true)
precondition(restartWithMalformedPlan.playlists.map(\.id) == [b, a, c, d], "An existing v3 library must not reread a leftover plan.")
try preparedBytes.write(to: preparedURL)

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

