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

// Disposable scan cache: never contains the authoritative playlists or audio.
struct TrackCatalogRecord: Codable {
    let id: String
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval
    let byteCount: Int64
    let modifiedAt: Date
    let embeddedArtwork: Data?

    init(_ track: Track, embeddedArtwork: Data? = nil) {
        id = track.id; title = track.title; artist = track.artist; album = track.album
        duration = track.duration; byteCount = track.byteCount; modifiedAt = track.modifiedAt
        self.embeddedArtwork = embeddedArtwork
    }

    var track: Track? {
        guard (try? LegacyRelativePath(id)) != nil, byteCount >= 0,
            duration.isFinite, duration >= 0,
            [title, artist, album].allSatisfy({ $0.count <= 4096 }),
            (embeddedArtwork?.count ?? 0) <= 4 * 1024 * 1024 else { return nil }
        return Track(id: id, title: title, artist: artist, album: album,
            duration: duration, artwork: embeddedArtwork, byteCount: byteCount, modifiedAt: modifiedAt)
    }
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

    static func validateState(_ state: LibraryState, validateArchive: Bool = true) throws {
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
        if validateArchive, let archive = state.legacyArchive { try LegacyLibraryMigration.validateArchive(archive) }
    }
}

// One editable collection receives hearts and imported likes. A separate,
// byte-exact pre-merge file is retained by LibraryStore before this projection
// is written; the original source archive and all audio remain untouched.
enum LikedCollection {
    static func recognizes(_ name: String) -> Bool {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return key == "liked songs" || key == "liked music" || key.hasPrefix("youtube liked music (")
    }

    static func playlistID(in state: LibraryState) -> UUID? {
        state.playlists.first(where: { $0.name == "Liked Songs" })?.id
            ?? state.playlists.first(where: { recognizes($0.name) })?.id
    }

    static func merging(_ original: LibraryState) -> LibraryState {
        let sources = original.playlists.filter { recognizes($0.name) }
        let canonical = sources.first(where: { $0.name == "Liked Songs" })
            ?? sources.first(where: { $0.name.lowercased() == "liked music" })
            ?? sources.first ?? Playlist(name: "Liked Songs", entries: [])
        var entries: [PlaylistEntry] = []
        var byVideo: [String: Int] = [:]
        var byPath: [String: Int] = [:]
        // Retain the original collection's order and occurrence identities.
        let ordered = [canonical] + sources.filter { $0.id != canonical.id }
        for playlist in ordered {
            let incoming = playlist.entries ?? playlist.trackIDs.map {
                PlaylistEntry(trackID: $0, title: "", artist: "", status: "downloaded")
            }
            for entry in incoming {
                let matched = entry.sourceVideoID.flatMap { byVideo[$0] }
                    ?? entry.trackID.flatMap { byPath[$0] }
                if let index = matched {
                    // A later successful import can repair an unavailable old
                    // entry without changing the old entry's identity/order.
                    if entries[index].trackID == nil, let path = entry.trackID {
                        entries[index].trackID = path
                        entries[index].status = entry.status
                    }
                    if entries[index].sourceVideoID == nil { entries[index].sourceVideoID = entry.sourceVideoID }
                    if entries[index].title.isEmpty { entries[index].title = entry.title }
                    if entries[index].artist.isEmpty { entries[index].artist = entry.artist }
                    if let video = entry.sourceVideoID { byVideo[video] = index }
                    if let path = entry.trackID { byPath[path] = index }
                } else {
                    let index = entries.count
                    entries.append(entry)
                    if let video = entry.sourceVideoID { byVideo[video] = index }
                    if let path = entry.trackID { byPath[path] = index }
                }
            }
        }
        for path in original.favoriteIDs.sorted() where byPath[path] == nil {
            byPath[path] = entries.count
            entries.append(PlaylistEntry(trackID: path, title: "", artist: "", status: "downloaded"))
        }
        var result = original
        let replacement = Playlist(id: canonical.id, name: "Liked Songs",
            trackIDs: entries.compactMap(\.trackID), entries: entries)
        let insertion = original.playlists.firstIndex(where: { recognizes($0.name) }) ?? 0
        result.playlists.removeAll { recognizes($0.name) }
        result.playlists.insert(replacement, at: min(insertion, result.playlists.count))
        return result
    }
}

// Native mutations are optimistic in the UI. This worker owns the last state
// actually written to disk, so a failed latest save rolls back to durable data,
// rather than to an earlier optimistic edit that also failed to save.
struct LibraryWriteOutcome: @unchecked Sendable {
    let revision: UInt64
    let durableState: LibraryState
    let errorDescription: String?
}

final class NativeLibraryPersistence: @unchecked Sendable {
    private let url: URL
    private let worker = DispatchQueue(label: "MusicCloud.library-persistence", qos: .userInitiated)
    private let lock = NSLock()
    private var revision: UInt64 = 0
    // Accessed only by worker, including through its synchronous barrier.
    private var durableState: LibraryState

    init(url: URL, durableState: LibraryState) {
        self.url = url
        self.durableState = durableState
    }

    private func nextRevision() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        revision &+= 1
        return revision
    }

    private func isCurrent(_ ticket: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return revision == ticket
    }

    @discardableResult
    func save(_ snapshot: LibraryState,
        completion: @escaping @Sendable (LibraryWriteOutcome) -> Void) -> UInt64 {
        let ticket = nextRevision()
        worker.async { [self] in
            guard isCurrent(ticket) else {
                completion(LibraryWriteOutcome(revision: ticket, durableState: durableState, errorDescription: nil))
                return
            }
            completion(write(snapshot, ticket: ticket, allowArchiveReplacement: false, coalescing: true))
        }
        return ticket
    }

    // Used only by confirmed destructive operations and restore. Invalidate
    // queued optimistic saves before waiting for any in-flight atomic write.
    // Older callbacks carry older revisions and cannot undo this transaction.
    func saveDurably(_ snapshot: LibraryState, allowArchiveReplacement: Bool = false) -> LibraryWriteOutcome {
        let ticket = nextRevision()
        return worker.sync {
            write(snapshot, ticket: ticket, allowArchiveReplacement: allowArchiveReplacement, coalescing: false)
        }
    }

    private func write(_ snapshot: LibraryState, ticket: UInt64,
        allowArchiveReplacement: Bool, coalescing: Bool) -> LibraryWriteOutcome {
        do {
            guard allowArchiveReplacement || snapshot.legacyArchive == durableState.legacyArchive else {
                throw LibrarySchemaError.invalidJSON
            }
            try LibrarySchemaGuard.validateState(snapshot, validateArchive: allowArchiveReplacement)
            let data = try JSONEncoder().encode(snapshot)
            guard data.count <= LibraryStateReader.maximumStateBytes else { throw LibrarySchemaError.invalidJSON }
            if coalescing && !isCurrent(ticket) {
                return LibraryWriteOutcome(revision: ticket, durableState: durableState, errorDescription: nil)
            }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: url.path) {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw LibrarySchemaError.invalidJSON
                }
            }
            try data.write(to: url, options: .atomic)
            durableState = snapshot
            return LibraryWriteOutcome(revision: ticket, durableState: durableState, errorDescription: nil)
        } catch {
            return LibraryWriteOutcome(revision: ticket, durableState: durableState,
                errorDescription: error.localizedDescription)
        }
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


