import Foundation

// Portable model checks. These do not require or simulate iPhone playback.
let ids = ["Music/Artist/Track 02.m4a", "Music/Artist/Track 01.m4a", "日本語/曲.flac"]
let playlist = Playlist(name: "Evening", trackIDs: ids)
var state = LibraryState()
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

