import CryptoKit
import Foundation

enum ArtworkStoreError: Error {
    case invalidIndex, invalidPack, unsafeReference
}

// Immutable, read-only artwork access. Original index, pack and loose images
// stay in Documents; the app never rewrites them during migration or scanning.
struct LibraryArtworkStore: Sendable {
    private struct Index: Decodable {
        let version: Int
        let packSha256: String
        let files: [Entry]
    }
    private struct Entry: Decodable {
        let path: String
        let offset: Int64
        let length: Int64
    }
    private let documentsURL: URL
    private let mapping: [LegacyRelativePath: LegacyRelativePath]
    private let playlistMapping: [UUID: LegacyRelativePath]
    private let ranges: [LegacyRelativePath: Range<Int>]
    private let pack: Data?
    private static let maximumImageBytes = 4 * 1024 * 1024

    init(documentsURL: URL, legacyExportData: Data?, supplemental: [String: String] = [:]) throws {
        self.documentsURL = documentsURL.standardizedFileURL.resolvingSymlinksInPath()
        let snapshot = try legacyExportData.map { try LegacyExportSnapshot(data: $0) }
        var trackImages = snapshot?.artworkByPath ?? [:]
        for playlist in snapshot?.playlists ?? [] {
            for entry in playlist.entries {
                if let path = entry.path, let reference = entry.artwork, trackImages[path] == nil {
                    trackImages[path] = reference
                }
            }
        }
        for (path, reference) in supplemental {
            let path = try LegacyRelativePath(path)
            if trackImages[path] == nil { trackImages[path] = try LegacyRelativePath(reference) }
        }
        mapping = trackImages
        var playlistImages: [UUID: LegacyRelativePath] = [:]
        for playlist in snapshot?.playlists ?? [] {
            if let id = UUID(uuidString: playlist.id), let artwork = playlist.artwork { playlistImages[id] = artwork }
        }
        playlistMapping = playlistImages
        let fm = FileManager.default
        let indexURL = documentsURL.appendingPathComponent("Artwork-index.json")
        let packURL = documentsURL.appendingPathComponent("Artwork.pack")
        guard fm.fileExists(atPath: indexURL.path) || fm.fileExists(atPath: packURL.path) else {
            ranges = [:]
            pack = nil
            return
        }
        let indexInfo = try indexURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        let packInfo = try packURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard indexInfo.isRegularFile == true, indexInfo.isSymbolicLink != true,
              packInfo.isRegularFile == true, packInfo.isSymbolicLink != true,
              let indexSize = indexInfo.fileSize, indexSize > 0, indexSize <= 8 * 1024 * 1024,
              let packSize = packInfo.fileSize, packSize > 0, packSize <= 512 * 1024 * 1024 else {
            throw ArtworkStoreError.invalidIndex
        }
        let index = try JSONDecoder().decode(Index.self, from: Data(contentsOf: indexURL))
        guard index.version == 1, index.files.count <= 50_000 else { throw ArtworkStoreError.invalidIndex }
        let data = try Data(contentsOf: packURL, options: .mappedIfSafe)
        guard data.count == packSize else { throw ArtworkStoreError.invalidPack }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == index.packSha256.lowercased() else { throw ArtworkStoreError.invalidPack }
        var positions: [LegacyRelativePath: Range<Int>] = [:]
        for entry in index.files {
            let path = try LegacyRelativePath(entry.path)
            guard entry.offset >= 0, entry.length > 0, entry.length <= Int64(Self.maximumImageBytes),
                  entry.offset <= Int64(data.count), entry.length <= Int64(data.count) - entry.offset,
                  positions[path] == nil else { throw ArtworkStoreError.invalidIndex }
            positions[path] = Int(entry.offset)..<Int(entry.offset + entry.length)
        }
        ranges = positions
        pack = data
    }

    func artwork(for trackPath: String) -> Data? {
        guard let path = try? LegacyRelativePath(trackPath), let reference = mapping[path] else { return nil }
        return art(reference: reference.rawValue)
    }

    func artwork(for playlistID: UUID) -> Data? {
        guard let reference = playlistMapping[playlistID] else { return nil }
        return art(reference: reference.rawValue)
    }

    func art(reference: String) -> Data? {
        guard let path = try? LegacyRelativePath(reference) else { return nil }
        if let range = ranges[path], let pack { return pack.subdata(in: range) }
        let candidate = documentsURL.appendingPathComponent(path.rawValue).standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.path.hasPrefix(documentsURL.path + "/"),
              let info = try? candidate.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              info.isRegularFile == true, let size = info.fileSize, size > 0, size <= Self.maximumImageBytes,
              let data = try? Data(contentsOf: candidate), data.count == size else { return nil }
        return data
    }
}
