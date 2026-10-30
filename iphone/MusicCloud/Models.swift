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
    var entries: [PlaylistEntry]? = nil
}

struct PlaylistEntry: Identifiable, Codable, Equatable {
    var id = UUID()
    var trackID: String?
    var title: String
    var artist: String
    var status: String
    var sourceVideoID: String? = nil
    // The original entry is opaque history, not a source of mutable UI values.
    var legacyData: JSONValue? = nil
}

struct LegacyLibraryArchive: Codable, Equatable {
    let originalExportData: Data
    let sourceFilename: String
    let sidecarData: [String: Data]
}

// Display-only edits. Audio files and path-based identities stay unchanged.
struct TrackMetadataOverride: Codable, Equatable {
    var title: String
    var artist: String
    var album: String
}

struct LibraryState: Codable {
    var version = 3
    var favoriteIDs: Set<String> = []
    var playlists: [Playlist] = []
    // v1 has no edits. v2 always includes this dictionary, even when empty.
    // Optional permits decoding old v1 files without a migration write.
    var trackOverrides: [String: TrackMetadataOverride]? = [:]
    var legacyArchive: LegacyLibraryArchive? = nil
}

enum LibrarySchemaError: LocalizedError {
    case invalidJSON, newerLibrary, incompatibleLayout
    var errorDescription: String? {
        switch self {
        case .invalidJSON: return "The library data is not a valid MusicCloud object."
        case .incompatibleLayout: return "Saved playlist or artwork files use a library layout this build cannot open. No files were changed."
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
        let rootKeys: Set<String> = ["version", "favoriteIDs", "playlists", "trackOverrides", "legacyArchive"]
        guard Set(root.keys).isSubset(of: rootKeys) else { throw LibrarySchemaError.newerLibrary }
        guard let playlists = root["playlists"] as? [[String: Any]] else { throw LibrarySchemaError.invalidJSON }
        let version = root["version"] as? Int
        let playlistKeys: Set<String> = ["id", "name", "trackIDs", "entries"]
        let entryKeys: Set<String> = ["id", "trackID", "title", "artist", "status", "sourceVideoID", "legacyData"]
        for playlist in playlists {
            guard Set(playlist.keys).isSubset(of: playlistKeys) else { throw LibrarySchemaError.newerLibrary }
            if let rawEntries = playlist["entries"], !(rawEntries is NSNull) {
                guard version == 3 else { throw LibrarySchemaError.newerLibrary }
                guard let entries = rawEntries as? [[String: Any]] else { throw LibrarySchemaError.invalidJSON }
                for entry in entries where !Set(entry.keys).isSubset(of: entryKeys) {
                    throw LibrarySchemaError.newerLibrary
                }
            }
        }
        if let raw = root["trackOverrides"], !(raw is NSNull) {
            guard let overrides = raw as? [String: Any] else { throw LibrarySchemaError.invalidJSON }
            let overrideKeys: Set<String> = ["title", "artist", "album"]
            for value in overrides.values {
                guard let edit = value as? [String: Any] else { throw LibrarySchemaError.invalidJSON }
                guard Set(edit.keys).isSubset(of: overrideKeys) else { throw LibrarySchemaError.newerLibrary }
            }
        }
        if let rawArchive = root["legacyArchive"], !(rawArchive is NSNull) {
            guard version == 3, let archive = rawArchive as? [String: Any] else {
                throw LibrarySchemaError.newerLibrary
            }
            let archiveKeys: Set<String> = ["originalExportData", "sourceFilename", "sidecarData"]
            guard Set(archive.keys).isSubset(of: archiveKeys) else { throw LibrarySchemaError.newerLibrary }
        }
        let state = try JSONDecoder().decode(LibraryState.self, from: data)
        try validateState(state)
    }

    static func validateState(_ state: LibraryState) throws {
        guard (state.version == 1 && state.trackOverrides == nil && state.legacyArchive == nil && state.playlists.allSatisfy({ $0.entries == nil })) ||
            (state.version == 2 && state.trackOverrides != nil && state.legacyArchive == nil && state.playlists.allSatisfy({ $0.entries == nil })) ||
            (state.version == 3 && state.trackOverrides != nil) else {
            throw LibrarySchemaError.newerLibrary
        }
        guard Set(state.playlists.map(\.id)).count == state.playlists.count else { throw LibrarySchemaError.invalidJSON }
        for path in state.favoriteIDs { _ = try LegacyRelativePath(path) }
        var entryIDs = Set<UUID>()
        for playlist in state.playlists {
            guard !playlist.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LibrarySchemaError.invalidJSON }
            for path in playlist.trackIDs { _ = try LegacyRelativePath(path) }
            if let entries = playlist.entries {
                guard playlist.trackIDs == entries.compactMap(\.trackID) else { throw LibrarySchemaError.invalidJSON }
                for entry in entries {
                    guard entryIDs.insert(entry.id).inserted, !entry.status.isEmpty else { throw LibrarySchemaError.invalidJSON }
                    if let path = entry.trackID { _ = try LegacyRelativePath(path) }
                }
            }
        }
        for (path, edit) in state.trackOverrides ?? [:] {
            _ = try LegacyRelativePath(path)
            guard [edit.title, edit.artist, edit.album].allSatisfy({
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 500
            }) else { throw LibrarySchemaError.invalidJSON }
        }
        if let archive = state.legacyArchive { try LegacyLibraryMigration.validateArchive(archive) }
    }
}


// Read-only preflight shared by app startup and filesystem regression checks.
// A container can survive an update while its contents remain incompatible.
enum LibraryStateReader {
    static let maximumStateBytes = 32 * 1024 * 1024
    static let incompatibleDocumentNames: Set<String> = [
        ".musiccloud-favorites.json", ".musiccloud-playlist-order.json",
        ".musiccloud-view.json", ".musiccloud-artwork-import.json",
        "Artwork-index.json", "Artwork.pack"
    ]

    static func read(documentsURL: URL, stateURL: URL, allowLegacyMigration: Bool = false,
        legacyStateURL: URL? = nil) throws -> LibraryState {
        let fm = FileManager.default
        var hasLegacyLayout = false
        if LegacyLibraryMigration.exists(documentsURL) {
            // Enumerating names also detects marker directories and broken links.
            // Permission/enumeration errors propagate before any writes occur.
            let names = Set(try fm.contentsOfDirectory(atPath: documentsURL.path))
            guard !names.contains(where: {
                $0.hasPrefix(".musiccloud-") && $0.hasSuffix(".json") && !LegacyLibraryMigration.sidecarNames.contains($0)
            }) else { throw LibrarySchemaError.incompatibleLayout }
            hasLegacyLayout = !names.isDisjoint(with: incompatibleDocumentNames)
        }
        if LegacyLibraryMigration.exists(stateURL) {
            var state = try readNative(stateURL)
            if hasLegacyLayout && !(state.version == 3 && state.legacyArchive != nil) {
                throw LibrarySchemaError.incompatibleLayout
            }
            if allowLegacyMigration { state = upgraded(state) }
            return state
        }
        let preparedURL = documentsURL.appendingPathComponent(LegacyLibraryMigration.preparedFilename)
        if LegacyLibraryMigration.exists(preparedURL), !allowLegacyMigration {
            throw LibrarySchemaError.incompatibleLayout
        }
        var state: LibraryState
        if hasLegacyLayout {
            guard allowLegacyMigration else { throw LibrarySchemaError.incompatibleLayout }
            state = try LegacyLibraryMigration.read(documentsURL: documentsURL)
        } else if let legacyStateURL, LegacyLibraryMigration.exists(legacyStateURL) {
            let native = try readNative(legacyStateURL)
            state = allowLegacyMigration ? upgraded(native) : native
        } else {
            state = LibraryState()
        }
        if allowLegacyMigration {
            return try LegacyLibraryMigration.appendingPreparedPlaylists(to: state, documentsURL: documentsURL)
        }
        return state
    }

    private static func readNative(_ url: URL) throws -> LibraryState {
        let data = try LegacyLibraryMigration.readBoundedFile(url, maximumBytes: maximumStateBytes)
        try LibrarySchemaGuard.validate(data)
        return try JSONDecoder().decode(LibraryState.self, from: data)
    }

    private static func upgraded(_ input: LibraryState) -> LibraryState {
        var state = input
        state.version = 3
        state.trackOverrides = state.trackOverrides ?? [:]
        return state
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



