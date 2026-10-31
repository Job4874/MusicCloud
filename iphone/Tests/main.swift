import Foundation

// Portable model checks. These do not require or simulate iPhone playback.
let ids = ["Music/Artist/Track 02.m4a", "Music/Artist/Track 01.m4a", "日本語/曲.flac"]
let playlist = Playlist(name: "Evening", trackIDs: ids)
var state = LibraryState()
state.version = 1
state.trackOverrides = nil
state.playlists = [playlist]
state.favoriteIDs = [ids[2], ids[0]]
let bytes = try JSONEncoder().encode(state)
let restored = try JSONDecoder().decode(LibraryState.self, from: bytes)
precondition(restored.version == 1)
precondition(restored.playlists == state.playlists, "Playlist identity, Unicode paths and order must survive a backup.")
precondition(restored.favoriteIDs == state.favoriteIDs, "Favorites must survive a backup.")
precondition(TimeInterval.infinity.musicTime == "0:00")
precondition(TimeInterval.greatestFiniteMagnitude.musicTime == "0:00")
precondition(TimeInterval(-1).musicTime == "0:00")
precondition(TimeInterval(3661).musicTime == "1:01:01")
precondition(RepeatMode.off.next == .all && RepeatMode.all.next == .one && RepeatMode.one.next == .off)
print("Model checks passed: ordered backup round trip, favorites, Unicode paths, safe time formatting, repeat cycle.")

// Test the production schema guard with synthetic data; never print private backups.
func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
func expectNewer(_ object: Any) throws {
    do {
        try LibrarySchemaGuard.validate(json(object))
        preconditionFailure("Unknown schema fields must not be silently accepted.")
    } catch LibrarySchemaError.newerLibrary {
        // Expected: no model decoding or writes occurred.
    }
}
let base: [String: Any] = ["version": 1, "favoriteIDs": [], "playlists": []]
try LibrarySchemaGuard.validate(json(base))
try LibrarySchemaGuard.validate(json(["version": 2, "favoriteIDs": [], "playlists": [], "trackOverrides": [String: Any]()]))
try expectNewer(["version": 1, "favoriteIDs": [], "playlists": [], "artworkByPath": ["a.m4a": "a.jpg"]])
try expectNewer(["version": 1, "favoriteIDs": [], "playlists": [["id": UUID().uuidString, "name": "x", "trackIDs": [], "entries": []]]])
try expectNewer(["version": 2, "favoriteIDs": [], "playlists": [], "trackOverrides": ["a.m4a": ["title": "x", "artist": "y", "album": "z", "futureField": true]]])
do {
    try LibrarySchemaGuard.validate(json(["version": 1, "favoriteIDs": [], "playlists": ["not-a-playlist-object"]]))
    preconditionFailure("Malformed playlists must be rejected.")
} catch LibrarySchemaError.invalidJSON { }
print("Schema guard checks passed: known v1/v2 accepted; newer and malformed fields rejected.")



// Exercise the exact read-only startup routine with real temporary directories.
// Fixtures are synthetic and contain no user library data.
func expectBytes(_ url: URL, equalTo expected: Data) throws {
    let actual = try Data(contentsOf: url)
    precondition(actual == expected, "Startup must preserve existing bytes.")
}

func verifyStartupPreflight() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("MusicCloud-startup-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let docs = root.appendingPathComponent("Documents", isDirectory: true)
    let support = root.appendingPathComponent("Library/Application Support/MusicCloud", isDirectory: true)
    let stateURL = support.appendingPathComponent("library-state.json")
    let fresh = try LibraryStateReader.read(documentsURL: docs, stateURL: stateURL)
    precondition(fresh.playlists.isEmpty)
    precondition(!fm.fileExists(atPath: docs.path) && !fm.fileExists(atPath: support.path),
        "Reading a fresh installation must not create directories.")
    try fm.createDirectory(at: docs, withIntermediateDirectories: true)
    let audio = docs.appendingPathComponent("example.m4a")
    let sentinel = Data("synthetic audio sentinel".utf8)
    try sentinel.write(to: audio)
    _ = try LibraryStateReader.read(documentsURL: docs, stateURL: stateURL)
    try expectBytes(audio, equalTo: sentinel)

    // Every observed 1.5 sidecar must protect an otherwise empty draft state.
    for name in LibraryStateReader.incompatibleDocumentNames.sorted() {
        let marker = docs.appendingPathComponent(name)
        let markerData = Data("synthetic preserved sidecar".utf8)
        try markerData.write(to: marker)
        do {
            _ = try LibraryStateReader.read(documentsURL: docs, stateURL: stateURL)
            preconditionFailure("A newer Documents layout must not open as an empty library.")
        } catch LibrarySchemaError.incompatibleLayout { }
        precondition(!fm.fileExists(atPath: support.path))
        try expectBytes(marker, equalTo: markerData)
        try expectBytes(audio, equalTo: sentinel)
        try fm.removeItem(at: marker)
    }

    try fm.createDirectory(at: support, withIntermediateDirectories: true)
    for data in [bytes, try json(["version": 2, "favoriteIDs": [], "playlists": [], "trackOverrides": [String: Any]()])] {
        try data.write(to: stateURL)
        let opened = try LibraryStateReader.read(documentsURL: docs, stateURL: stateURL)
        let expected = try JSONDecoder().decode(LibraryState.self, from: data)
        precondition(opened.version == expected.version)
        try expectBytes(stateURL, equalTo: data)
    }
    try bytes.write(to: stateURL)
    let marker = docs.appendingPathComponent("Artwork.pack")
    try fm.createDirectory(at: marker, withIntermediateDirectories: false)
    do {
        _ = try LibraryStateReader.read(documentsURL: docs, stateURL: stateURL)
        preconditionFailure("Newer layout must win even when a valid draft state exists.")
    } catch LibrarySchemaError.incompatibleLayout { }
    try expectBytes(stateURL, equalTo: bytes)
    try fm.removeItem(at: marker)

    let malformed = Data("{invalid".utf8)
    try malformed.write(to: stateURL)
    do {
        _ = try LibraryStateReader.read(documentsURL: docs, stateURL: stateURL)
        preconditionFailure("Malformed state must not be opened as an empty library.")
    } catch { }
    try expectBytes(stateURL, equalTo: malformed)
    try expectBytes(audio, equalTo: sentinel)
}
try verifyStartupPreflight()
print("Startup checks passed: fresh and known layouts open; incompatible and malformed layouts preserve files.")


// The same likes importer and heart model must converge on one collection.
func verifyLikedMerge() throws {
    let retained = PlaylistEntry(trackID: "Music/old.m4a", title: "Old", artist: "A", status: "downloaded", sourceVideoID: "old-video")
    let missing = PlaylistEntry(trackID: nil, title: "Later", artist: "B", status: "unavailable", sourceVideoID: "new-video")
    let old = Playlist(name: "Liked Music", trackIDs: ["Music/old.m4a"], entries: [retained, missing])
    let repaired = PlaylistEntry(trackID: "Music/later.m4a", title: "Later", artist: "B", status: "downloaded", sourceVideoID: "new-video")
    let added = PlaylistEntry(trackID: "Music/added.m4a", title: "Added", artist: "C", status: "downloaded", sourceVideoID: "added-video")
    let imported = Playlist(name: "YouTube Liked Music (3 of 3 identified)", trackIDs: ["Music/old.m4a", "Music/later.m4a", "Music/added.m4a"], entries: [retained, repaired, added].enumerated().map { _, e in
        var copy = e; copy.id = UUID(); return copy
    })
    let ordinary = Playlist(name: "Night drive", trackIDs: ["Music/old.m4a", "Music/old.m4a"])
    var input = LibraryState()
    input.playlists = [old, ordinary, imported]
    input.favoriteIDs = ["Music/favorite.m4a"]
    let merged = LikedCollection.merging(input)
    precondition(merged.playlists.count == 2 && merged.playlists[1] == ordinary)
    let liked = merged.playlists[0]
    precondition(liked.id == old.id && liked.name == "Liked Songs")
    precondition(liked.entries?.count == 4)
    precondition(liked.entries?[0].id == retained.id && liked.entries?[1].id == missing.id)
    precondition(liked.entries?[1].trackID == "Music/later.m4a")
    precondition(liked.trackIDs == ["Music/old.m4a", "Music/later.m4a", "Music/added.m4a", "Music/favorite.m4a"])
    precondition(merged.favoriteIDs == input.favoriteIDs)
    precondition(LikedCollection.merging(merged).playlists == merged.playlists, "Migration must be idempotent.")
    precondition(!LikedCollection.recognizes("Songs I liked on a trip"))
    try LibrarySchemaGuard.validateState(merged)
}
try verifyLikedMerge()
print("Liked collection checks passed: one identity, repaired entries, union without duplicate paths, existing favorites, unchanged ordinary duplicates, idempotent migration.")

var pathOnly = LibraryState()
let nativeLike = PlaylistEntry(trackID: "Music/shared.m4a", title: "", artist: "", status: "downloaded")
let namedLike = PlaylistEntry(trackID: "Music/shared.m4a", title: "Shared", artist: "Artist", status: "downloaded", sourceVideoID: "public-id")
pathOnly.playlists = [Playlist(name: "Liked Music", trackIDs: ["Music/shared.m4a"], entries: [nativeLike]), Playlist(name: "YouTube Liked Music (1 of 1 identified)", trackIDs: ["Music/shared.m4a"], entries: [namedLike])]
let enrichedLike = LikedCollection.merging(pathOnly).playlists[0].entries![0]
precondition(enrichedLike.id == nativeLike.id && enrichedLike.sourceVideoID == "public-id" && enrichedLike.title == "Shared")
print("Liked merge retains newly supplied source IDs and artwork lookup metadata for path-only entries.")
