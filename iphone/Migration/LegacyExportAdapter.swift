import Foundation

enum LegacyAdapterError: Error, Equatable {
    case tooLarge
    case invalidField(String)
    case unsupportedVersion
    case unsafePath(String)
    case ambiguousPath(String)
}

// A read-only projection keeps opaque values instead of decoding only known keys.
// The original bytes remain authoritative; re-encoded JSON is diagnostic output.
indirect enum JSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case string(String)
    case number(Decimal)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let array = try? value.decode([JSONValue].self) { self = .array(array) }
        else if let object = try? value.decode([String: JSONValue].self) { self = .object(object) }
        else { self = .number(try value.decode(Decimal.self)) }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case .bool(let x): try value.encode(x)
        case .string(let x): try value.encode(x)
        case .number(let x): try value.encode(x)
        case .array(let x): try value.encode(x)
        case .object(let x): try value.encode(x)
        }
    }

    fileprivate func object(_ field: String) throws -> [String: JSONValue] {
        guard case .object(let value) = self else { throw LegacyAdapterError.invalidField(field) }
        return value
    }

    fileprivate func array(_ field: String) throws -> [JSONValue] {
        guard case .array(let value) = self else { throw LegacyAdapterError.invalidField(field) }
        return value
    }

    fileprivate func string(_ field: String) throws -> String {
        guard case .string(let value) = self else { throw LegacyAdapterError.invalidField(field) }
        return value
    }

    fileprivate func integer(_ field: String) throws -> Int {
        guard case .number(let value) = self else { throw LegacyAdapterError.invalidField(field) }
        let number = NSDecimalNumber(decimal: value)
        let integer = number.int64Value
        guard Decimal(integer) == value, let result = Int(exactly: integer) else {
            throw LegacyAdapterError.invalidField(field)
        }
        return result
    }
}

private func required(_ object: [String: JSONValue], _ key: String) throws -> JSONValue {
    guard let value = object[key] else { throw LegacyAdapterError.invalidField(key) }
    return value
}

private func optionalString(_ object: [String: JSONValue], _ key: String) throws -> String? {
    guard let value = object[key], value != .null else { return nil }
    return try value.string(key)
}

private func optionalCount(_ object: [String: JSONValue], _ key: String) throws -> Int? {
    guard let value = object[key], value != .null else { return nil }
    let number = try value.integer(key)
    guard number >= 0 else { throw LegacyAdapterError.invalidField(key) }
    return number
}

private func optionalBool(_ object: [String: JSONValue], _ key: String) throws -> Bool? {
    guard let value = object[key], value != .null else { return nil }
    guard case .bool(let result) = value else { throw LegacyAdapterError.invalidField(key) }
    return result
}

struct LegacyRelativePath: Hashable {
    let rawValue: String

    init(_ rawValue: String) throws {
        // These are filesystem paths, never URLs. Do not URL-decode, trim,
        // normalize case/Unicode, collapse separators or match by filename.
        let components = rawValue.split(separator: "/", omittingEmptySubsequences: false)
        guard !rawValue.isEmpty, !rawValue.contains("\\"), !rawValue.contains(":"),
            !rawValue.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
            components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw LegacyAdapterError.unsafePath(rawValue)
        }
        self.rawValue = rawValue
    }

    // String's Unicode-equivalence comparison is inappropriate for a path
    // inventory. This key requires the exact UTF-8 bytes supplied by the export.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue.utf8.elementsEqual(rhs.rawValue.utf8)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(Data(rawValue.utf8))
    }
}

private func optionalPath(_ object: [String: JSONValue], _ key: String) throws -> LegacyRelativePath? {
    guard let path = try optionalString(object, key), !path.isEmpty else { return nil }
    return try LegacyRelativePath(path)
}

struct LegacyPlaylistEntry {
    let raw: JSONValue
    let id: String
    let title: String
    let artist: String
    let videoID: String?
    let path: LegacyRelativePath?
    let status: String
    let artwork: LegacyRelativePath?
    let sourceAvailable: Bool?
    let sourcePosition: Int?

    fileprivate init(_ raw: JSONValue) throws {
        let object = try raw.object("entry")
        self.raw = raw
        id = try required(object, "id").string("entry.id")
        title = try required(object, "title").string("entry.title")
        artist = try required(object, "artist").string("entry.artist")
        status = try required(object, "status").string("entry.status")
        videoID = try optionalString(object, "videoId")
        path = try optionalPath(object, "path")
        artwork = try optionalPath(object, "artwork")
        sourceAvailable = try optionalBool(object, "sourceAvailable")
        sourcePosition = try optionalCount(object, "sourcePosition")
        guard !id.isEmpty, !status.isEmpty else { throw LegacyAdapterError.invalidField("entry identity/status") }
    }
}

struct LegacyPlaylist {
    let raw: JSONValue
    let id: String
    let name: String
    let trackIDs: [LegacyRelativePath]
    let entries: [LegacyPlaylistEntry]
    let artwork: LegacyRelativePath?
    let sourceComplete: Bool?
    let observedCount: Int?
    let reportedCount: Int?
    let downloadedCount: Int?
    let missingCount: Int?
    let unavailableCount: Int?

    fileprivate init(_ raw: JSONValue) throws {
        let object = try raw.object("playlist")
        self.raw = raw
        id = try required(object, "id").string("playlist.id")
        name = try required(object, "name").string("playlist.name")
        trackIDs = try required(object, "trackIDs").array("playlist.trackIDs").map {
            try LegacyRelativePath($0.string("playlist.trackIDs[]"))
        }
        // Earlier exports lack entries. Their ordered trackIDs are preserved.
        entries = try object["entries"].map { try $0.array("playlist.entries").map(LegacyPlaylistEntry.init) } ?? []
        artwork = try optionalPath(object, "artwork")
        sourceComplete = try optionalBool(object, "sourceComplete")
        observedCount = try optionalCount(object, "observedCount")
        reportedCount = try optionalCount(object, "reportedCount")
        downloadedCount = try optionalCount(object, "downloadedCount")
        missingCount = try optionalCount(object, "missingCount")
        unavailableCount = try optionalCount(object, "unavailableCount")
        guard !id.isEmpty else { throw LegacyAdapterError.invalidField("playlist.id") }
    }
}

struct LegacyExportSnapshot {
    let originalData: Data
    let raw: JSONValue
    let version: Int
    let favoriteIDs: [LegacyRelativePath]
    let playlists: [LegacyPlaylist]
    let artworkByPath: [LegacyRelativePath: LegacyRelativePath]

    init(data: Data) throws {
        guard data.count <= 10 * 1024 * 1024 else { throw LegacyAdapterError.tooLarge }
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        let object = try value.object("root")
        let version = try required(object, "version").integer("version")
        guard version == 1 else { throw LegacyAdapterError.unsupportedVersion }
        let favorites = try required(object, "favoriteIDs").array("favoriteIDs").map {
            try LegacyRelativePath($0.string("favoriteIDs[]"))
        }
        let playlists = try required(object, "playlists").array("playlists").map(LegacyPlaylist.init)
        var artwork: [LegacyRelativePath: LegacyRelativePath] = [:]
        if let mapping = object["artworkByPath"] {
            for (path, reference) in try mapping.object("artworkByPath") {
                artwork[try LegacyRelativePath(path)] = try LegacyRelativePath(reference.string("artworkByPath[]"))
            }
        }
        self.originalData = data
        raw = value
        self.version = version
        favoriteIDs = favorites
        self.playlists = playlists
        artworkByPath = artwork
    }

    // Useful for inspection/testing. This is never a replacement for originalData:
    // JSONEncoder may change number formatting, escaping and object-key order.
    func diagnosticTreeData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(raw)
    }
}

enum LegacyPathResolution: Equatable {
    case noLocalPath
    case present(LegacyRelativePath)
    case missing(LegacyRelativePath)
}

struct LegacyPathInventory {
    private let occurrences: [LegacyRelativePath: Int]

    init(paths: [String]) throws {
        var counts: [LegacyRelativePath: Int] = [:]
        for raw in paths { counts[try LegacyRelativePath(raw), default: 0] += 1 }
        occurrences = counts
    }

    func resolve(_ path: LegacyRelativePath?) throws -> LegacyPathResolution {
        guard let path else { return .noLocalPath }
        switch occurrences[path, default: 0] {
        case 0: return .missing(path)
        case 1: return .present(path)
        default: throw LegacyAdapterError.ambiguousPath(path.rawValue)
        }
    }
}
