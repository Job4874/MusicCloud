import Foundation

struct Track: Identifiable, Hashable {
    // Identity follows the path inside Documents. Rescanning or replacing a file
    // at the same path keeps its favorites and playlist membership.
    let id: String
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval
    let artwork: Data?
    let byteCount: Int64
    let modifiedAt: Date

    var filename: String { (id as NSString).lastPathComponent }
    var searchableText: String { "\(title) \(artist) \(album) \(filename)" }
}

struct Playlist: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var trackIDs: [String] = []
}

// Display-only edits. Audio files and path-based identities stay unchanged.
struct TrackMetadataOverride: Codable, Equatable {
    var title: String
    var artist: String
    var album: String
}

struct LibraryState: Codable {
    var version = 1
    var favoriteIDs: Set<String> = []
    var playlists: [Playlist] = []
    // v1 has no edits. v2 always includes this dictionary, even when empty.
    // Optional permits decoding old v1 files without a migration write.
    var trackOverrides: [String: TrackMetadataOverride]? = nil
}

enum LibrarySchemaError: LocalizedError {
    case invalidJSON, newerLibrary
    var errorDescription: String? {
        switch self {
        case .invalidJSON: return "The library data is not a valid MusicCloud object."
        case .newerLibrary: return "This library or backup contains data from a newer MusicCloud version. No data was changed."
        }
    }
}

// Codable ignores unrecognized keys. This guard deliberately fails closed
// before decoding, so a later write cannot discard data from a newer app.
enum LibrarySchemaGuard {
    static func validate(_ data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LibrarySchemaError.invalidJSON
        }
        let rootKeys: Set<String> = ["version", "favoriteIDs", "playlists", "trackOverrides"]
        guard Set(root.keys).isSubset(of: rootKeys) else { throw LibrarySchemaError.newerLibrary }
        guard let playlists = root["playlists"] as? [[String: Any]] else { throw LibrarySchemaError.invalidJSON }
        let playlistKeys: Set<String> = ["id", "name", "trackIDs"]
        for playlist in playlists where !Set(playlist.keys).isSubset(of: playlistKeys) {
            throw LibrarySchemaError.newerLibrary
        }
        if let raw = root["trackOverrides"], !(raw is NSNull) {
            guard let overrides = raw as? [String: Any] else { throw LibrarySchemaError.invalidJSON }
            let overrideKeys: Set<String> = ["title", "artist", "album"]
            for value in overrides.values {
                guard let edit = value as? [String: Any] else { throw LibrarySchemaError.invalidJSON }
                guard Set(edit.keys).isSubset(of: overrideKeys) else { throw LibrarySchemaError.newerLibrary }
            }
        }
    }
}

enum RepeatMode: String, CaseIterable {
    case off, all, one

    var symbol: String { self == .one ? "repeat.1" : "repeat" }
    var label: String {
        switch self {
        case .off: return "Repeat off"
        case .all: return "Repeat all"
        case .one: return "Repeat one"
        }
    }

    var next: RepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }
}

extension TimeInterval {
    var musicTime: String {
        guard isFinite, self >= 0, self < TimeInterval(Int.max) else { return "0:00" }
        let seconds = Int(self)
        return seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

extension String {
    var musicSortKey: String { folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current) }
}

