import Foundation

enum LegacyLibraryMigration {
    static let sidecarNames: Set<String> = [
        ".musiccloud-favorites.json", ".musiccloud-playlist-order.json",
        ".musiccloud-view.json", ".musiccloud-artwork-import.json", "Artwork-index.json"
    ]
    private static let requiredSidecars: Set<String> = [".musiccloud-favorites.json", ".musiccloud-playlist-order.json"]
    private static let maximumSidecarBytes = 4 * 1024 * 1024

    // Files are read only. The caller owns a separate atomic v3 state commit.
    static func read(documentsURL: URL) throws -> LibraryState {
        let fm = FileManager.default
        let names = try fm.contentsOfDirectory(atPath: documentsURL.path)
        var candidates: [(name: String, date: Date, modified: Date)] = []
        for name in names where name.hasPrefix("MusicCloud-playlists-live-") && name.hasSuffix(".json") {
            let date = try exportDate(name)
            let url = documentsURL.appendingPathComponent(name)
            try requireContained(url, in: documentsURL)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw LibrarySchemaError.incompatibleLayout }
            candidates.append((name, date, values.contentModificationDate ?? .distantPast))
        }
        guard let selected = candidates.sorted(by: {
            if $0.date != $1.date { return $0.date > $1.date }
            if $0.modified != $1.modified { return $0.modified > $1.modified }
            return $0.name.utf8.lexicographicallyPrecedes($1.name.utf8)
        }).first else { throw LibrarySchemaError.incompatibleLayout }
        let original = try readBoundedFile(documentsURL.appendingPathComponent(selected.name), maximumBytes: 10 * 1024 * 1024)
        let snapshot = try LegacyExportSnapshot(data: original)
        var sidecars: [String: Data] = [:]
        for name in sidecarNames where names.contains(name) {
            let url = documentsURL.appendingPathComponent(name)
            try requireContained(url, in: documentsURL)
            sidecars[name] = try readBoundedFile(url, maximumBytes: maximumSidecarBytes)
        }
        let parsed = try parseSidecars(sidecars)
        if names.contains("Artwork.pack") || names.contains("Artwork-index.json") {
            guard names.contains("Artwork.pack"), names.contains("Artwork-index.json") else { throw LibrarySchemaError.incompatibleLayout }
            let pack = documentsURL.appendingPathComponent("Artwork.pack")
            try requireContained(pack, in: documentsURL)
            let values = try pack.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                let packBytes = values.fileSize, packBytes >= 0,
                (parsed.artworkRanges ?? []).allSatisfy({ $0.offset <= packBytes && $0.length <= packBytes - $0.offset }) else {
                throw LibrarySchemaError.incompatibleLayout
            }
        }
        var state = LibraryState()
        var playlistIDs = Set<UUID>()
        for source in snapshot.playlists {
            guard let id = UUID(uuidString: source.id), playlistIDs.insert(id).inserted else { throw LibrarySchemaError.invalidJSON }
            var playlist = Playlist(id: id, name: source.name, trackIDs: source.trackIDs.map(\.rawValue))
            if case .object(let fields) = source.raw, fields["entries"] != nil {
                let entries = source.entries.map {
                    PlaylistEntry(trackID: $0.path?.rawValue, title: $0.title, artist: $0.artist,
                        status: $0.status, sourceVideoID: $0.videoID, legacyData: $0.raw)
                }
                playlist.entries = entries
                playlist.trackIDs = entries.compactMap(\.trackID)
            }
            state.playlists.append(playlist)
        }
        // A UUID in the order sidecar represents a real playlist. An unknown
        // UUID would mean this snapshot omits current content; do not guess.
        var ordered: [Playlist] = []
        var seen = Set<UUID>()
        let byID = Dictionary(uniqueKeysWithValues: state.playlists.map { ($0.id, $0) })
        for token in parsed.order {
            guard let id = UUID(uuidString: token) else { continue } // Preserve opaque special-row tokens in archive.
            guard let playlist = byID[id], seen.insert(id).inserted else { throw LibrarySchemaError.incompatibleLayout }
            ordered.append(playlist)
        }
        ordered.append(contentsOf: state.playlists.filter { !seen.contains($0.id) })
        state.playlists = ordered
        state.favoriteIDs = Set(parsed.favorites)
        state.legacyArchive = LegacyLibraryArchive(originalExportData: original, sourceFilename: selected.name, sidecarData: sidecars)
        try LibrarySchemaGuard.validateState(state)
        return state
    }

    static func validateArchive(_ archive: LegacyLibraryArchive) throws {
        _ = try exportDate(archive.sourceFilename)
        _ = try LegacyExportSnapshot(data: archive.originalExportData)
        _ = try parseSidecars(archive.sidecarData)
    }

    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path) || (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    static func readBoundedFile(_ url: URL, maximumBytes: Int) throws -> Data {
        let before = try FileManager.default.attributesOfItem(atPath: url.path)
        guard before[.type] as? FileAttributeType == .typeRegular,
            let size = before[.size] as? NSNumber, size.int64Value >= 0,
            size.int64Value <= Int64(maximumBytes) else { throw LibrarySchemaError.incompatibleLayout }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes, data.count == size.intValue else { throw LibrarySchemaError.incompatibleLayout }
        let after = try FileManager.default.attributesOfItem(atPath: url.path)
        guard after[.type] as? FileAttributeType == .typeRegular,
            (after[.size] as? NSNumber)?.int64Value == size.int64Value,
            (after[.modificationDate] as? Date) == (before[.modificationDate] as? Date) else {
            throw LibrarySchemaError.incompatibleLayout
        }
        return data
    }

    private static func requireContained(_ url: URL, in root: URL) throws {
        let prefix = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(prefix) else { throw LibrarySchemaError.incompatibleLayout }
    }

    private static func exportDate(_ name: String) throws -> Date {
        let prefix = "MusicCloud-playlists-live-"
        guard name.hasPrefix(prefix), name.hasSuffix(".json") else { throw LibrarySchemaError.incompatibleLayout }
        let stamp = String(name.dropFirst(prefix.count).dropLast(5))
        guard stamp.count == 19, stamp.range(of: "^[0-9]{8}-[0-9]{9}Z$", options: .regularExpression) != nil else {
            throw LibrarySchemaError.incompatibleLayout
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmssSSS'Z'"
        formatter.isLenient = false
        guard let date = formatter.date(from: stamp), formatter.string(from: date) == stamp else { throw LibrarySchemaError.incompatibleLayout }
        return date
    }

    private struct Sidecars {
        let favorites: [String]
        let order: [String]
        let artworkRanges: [(offset: Int, length: Int)]?
    }

    private static func parseSidecars(_ files: [String: Data]) throws -> Sidecars {
        guard Set(files.keys).isSubset(of: sidecarNames), requiredSidecars.isSubset(of: Set(files.keys)),
            files.values.allSatisfy({ $0.count <= maximumSidecarBytes }) else { throw LibrarySchemaError.incompatibleLayout }
        let favorites = try stringArray(files[".musiccloud-favorites.json"]!)
        for path in favorites { _ = try LegacyRelativePath(path) }
        let order = try stringArray(files[".musiccloud-playlist-order.json"]!)
        guard order.allSatisfy({ !$0.isEmpty }) else { throw LibrarySchemaError.incompatibleLayout }
        if let data = files[".musiccloud-view.json"] {
            let object = try object(data, keys: ["mode", "playlistID"])
            guard object.count == 2, case .string? = object["mode"], case .string? = object["playlistID"] else {
                throw LibrarySchemaError.incompatibleLayout
            }
        }
        if let data = files[".musiccloud-artwork-import.json"] {
            let object = try object(data, keys: ["sha256"])
            guard object.count == 1, case .string(let hash)? = object["sha256"], validHash(hash) else { throw LibrarySchemaError.incompatibleLayout }
        }
        var ranges: [(offset: Int, length: Int)]?
        if let data = files["Artwork-index.json"] {
            let object = try object(data, keys: ["version", "packSha256", "files"])
            guard object.count == 3, case .number(let version)? = object["version"], version == 1,
                case .string(let hash)? = object["packSha256"], validHash(hash),
                case .array(let files)? = object["files"] else { throw LibrarySchemaError.incompatibleLayout }
            var paths = Set<LegacyRelativePath>()
            ranges = try files.map { file in
                guard case .object(let fields) = file, Set(fields.keys) == Set(["path", "offset", "length"]),
                    case .string(let path)? = fields["path"], case .number(let offset)? = fields["offset"],
                    case .number(let length)? = fields["length"] else { throw LibrarySchemaError.incompatibleLayout }
                guard paths.insert(try LegacyRelativePath(path)).inserted else { throw LibrarySchemaError.incompatibleLayout }
                return (offset: try nonnegativeInteger(offset), length: try nonnegativeInteger(length))
            }
        }
        return Sidecars(favorites: favorites, order: order, artworkRanges: ranges)
    }

    private static func object(_ data: Data, keys: Set<String>) throws -> [String: JSONValue] {
        guard case .object(let object) = try JSONDecoder().decode(JSONValue.self, from: data),
            Set(object.keys).isSubset(of: keys) else { throw LibrarySchemaError.incompatibleLayout }
        return object
    }

    private static func stringArray(_ data: Data) throws -> [String] {
        guard case .array(let values) = try JSONDecoder().decode(JSONValue.self, from: data) else { throw LibrarySchemaError.incompatibleLayout }
        return try values.map {
            guard case .string(let value) = $0 else { throw LibrarySchemaError.incompatibleLayout }
            return value
        }
    }

    private static func nonnegativeInteger(_ value: Decimal) throws -> Int {
        let integer = NSDecimalNumber(decimal: value).int64Value
        guard integer >= 0, Decimal(integer) == value, let result = Int(exactly: integer) else { throw LibrarySchemaError.incompatibleLayout }
        return result
    }

    private static func validHash(_ string: String) -> Bool {
        string.count == 64 && string.unicodeScalars.allSatisfy({ (48...57).contains($0.value) || (65...70).contains($0.value) || (97...102).contains($0.value) })
    }
}
