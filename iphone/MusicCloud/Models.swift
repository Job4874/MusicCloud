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

