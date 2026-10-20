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
