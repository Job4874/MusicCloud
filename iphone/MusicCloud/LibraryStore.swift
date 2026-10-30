import AVFoundation
import Foundation
import SwiftUI
import UIKit

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var state = LibraryState()
    @Published private(set) var isScanning = false
    @Published private(set) var isImporting = false
    @Published var message: String?
    @Published private(set) var lastScan: Date?

    nonisolated static let extensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "caf"]
    let documentsURL: URL
    private let stateURL: URL
    private var canSave = true
    private var scanTask: Task<Void, Never>?
    private var scanGeneration = UUID()
    // Keep file metadata separate from display edits so a reset reveals the original tags.
    private var scannedTracks: [Track] = []

    init() {
        let fm = FileManager.default
        documentsURL = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MusicCloud", isDirectory: true)
        stateURL = support.appendingPathComponent("library-state.json")
        do {
            try fm.createDirectory(at: documentsURL, withIntermediateDirectories: true)
            try fm.createDirectory(at: support, withIntermediateDirectories: true)
            if fm.fileExists(atPath: stateURL.path) {
                let decoded = try JSONDecoder().decode(LibraryState.self, from: Data(contentsOf: stateURL))
                guard (decoded.version == 1 && decoded.trackOverrides == nil) ||
                    (decoded.version == 2 && decoded.trackOverrides != nil) else {
                    throw StoreError.unsupportedVersion
                }
                state = decoded
            }
        } catch {
            // A damaged or newer state file must not be overwritten with defaults.
            canSave = false
            message = "Saved playlists could not be opened. Your music is safe. Use Transfer → Restore playlist backup to recover your saved lists. Existing saved data has been preserved. \(error.localizedDescription)"
        }
    }

    var favorites: [Track] { tracks.filter { state.favoriteIDs.contains($0.id) } }
    var totalSize: String {
        ByteCountFormatter.string(fromByteCount: tracks.reduce(0) { $0 + $1.byteCount }, countStyle: .file)
    }

    func track(id: String) -> Track? { tracks.first { $0.id == id } }
    func playlist(id: UUID) -> Playlist? { state.playlists.first { $0.id == id } }
    func playlistTracks(_ playlist: Playlist) -> [Track] {
        let byID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        return playlist.trackIDs.compactMap { byID[$0] }
    }

    func url(for track: Track) -> URL? { safeURL(for: track.id) }

    private func safeURL(for relativePath: String) -> URL? {
        let result = documentsURL.appendingPathComponent(relativePath).standardizedFileURL
        guard result.path.hasPrefix(documentsURL.standardizedFileURL.path + "/") else { return nil }
        return result
    }

    func rescan() {
        scanTask?.cancel()
        let generation = UUID()
        scanGeneration = generation
        isScanning = true
        let root = documentsURL
        let cache = Dictionary(uniqueKeysWithValues: scannedTracks.map { ($0.id, $0) })
        scanTask = Task {
            let worker = Task.detached(priority: .userInitiated) {
                await Self.scan(root: root, cache: cache)
            }
            let result = await withTaskCancellationHandler(operation: {
                await worker.value
            }, onCancel: { worker.cancel() })
            guard !Task.isCancelled, scanGeneration == generation else { return }
            scannedTracks = result.tracks
            applyMetadataOverrides()
            isScanning = false
            lastScan = Date()
            if let error = result.error { message = error }
        }
    }

    private func applyMetadataOverrides() {
        tracks = scannedTracks.map { track in
            guard let edit = state.trackOverrides?[track.id] else { return track }
            return Track(id: track.id, title: edit.title, artist: edit.artist, album: edit.album,
                duration: track.duration, artwork: track.artwork, byteCount: track.byteCount,
                modifiedAt: track.modifiedAt)
        }.sorted {
            let lhs = $0.title.musicSortKey, rhs = $1.title.musicSortKey
            return lhs == rhs ? $0.id < $1.id : lhs < rhs
        }
    }

    @discardableResult
    func editMetadata(id: String, title: String, artist: String, album: String) -> Bool {
        guard canSave, scannedTracks.contains(where: { $0.id == id }) else {
            message = "Changes could not be saved. Check the library state and try again."
            return false
        }
        let values = [title, artist, album].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard values.allSatisfy({ !$0.isEmpty && $0.count <= 500 }) else {
            message = "Enter a title, artist, and album, each under 500 characters."
            return false
        }
        var edits = state.trackOverrides ?? [:]
        edits[id] = TrackMetadataOverride(title: values[0], artist: values[1], album: values[2])
        let previous = state
        state.version = 2
        state.trackOverrides = edits
        guard saveMetadataState() else { state = previous; return false }
        applyMetadataOverrides()
        return true
    }

    @discardableResult
    func resetMetadata(id: String) -> Bool {
        guard canSave else { message = "Changes cannot be saved until the library state is restored."; return false }
        let previous = state
        var edits = state.trackOverrides ?? [:]
        edits.removeValue(forKey: id)
        state.version = 2
        state.trackOverrides = edits
        guard saveMetadataState() else { state = previous; return false }
        applyMetadataOverrides()
        return true
    }

    private func saveMetadataState() -> Bool {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(state).write(to: stateURL, options: .atomic)
            return true
        } catch {
            message = "Could not save song details: \(error.localizedDescription)"
            return false
        }
    }

    func toggleFavorite(_ track: Track) {
        if state.favoriteIDs.contains(track.id) { state.favoriteIDs.remove(track.id) }
        else { state.favoriteIDs.insert(track.id) }
        save()
    }

    @discardableResult
    func createPlaylist(name: String) -> UUID? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let playlist = Playlist(name: name)
        state.playlists.append(playlist)
        save()
        return playlist.id
    }

    func renamePlaylist(id: UUID, name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = state.playlists.firstIndex(where: { $0.id == id }) else { return }
        state.playlists[index].name = name
        save()
    }

    func deletePlaylist(id: UUID) {
        state.playlists.removeAll { $0.id == id }
        save()
    }

    func add(_ track: Track, to playlistID: UUID) {
        guard let index = state.playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        guard !state.playlists[index].trackIDs.contains(track.id) else { return }
        state.playlists[index].trackIDs.append(track.id)
        save()
    }

    func removeTracks(at offsets: IndexSet, from playlistID: UUID) {
        guard let index = state.playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        state.playlists[index].trackIDs.remove(atOffsets: offsets)
        save()
    }

    func removeTrack(id: String, from playlistID: UUID) {
        guard let index = state.playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        state.playlists[index].trackIDs.removeAll { $0 == id }
        save()
    }

    func moveTracks(from source: IndexSet, to destination: Int, in playlistID: UUID) {
        guard let index = state.playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        state.playlists[index].trackIDs.move(fromOffsets: source, toOffset: destination)
        save()
    }

    // Called only after a destructive confirmation in the UI.
    func deleteFile(_ track: Track) {
        guard let url = safeURL(for: track.id) else { return }
        do {
            try FileManager.default.removeItem(at: url)
            state.favoriteIDs.remove(track.id)
            state.trackOverrides?.removeValue(forKey: track.id)
            for index in state.playlists.indices {
                state.playlists[index].trackIDs.removeAll { $0 == track.id }
            }
            save()
            tracks.removeAll { $0.id == track.id }
            scannedTracks.removeAll { $0.id == track.id }
            rescan()
        } catch {
            message = "Could not delete \(track.filename): \(error.localizedDescription)"
        }
    }

    func importFiles(_ urls: [URL]) {
        guard !isImporting else {
            message = "An import is already in progress. Wait for it to finish, then try again."
            return
        }
        isImporting = true
        let root = documentsURL
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> (Int, [String]) in
                let fm = FileManager.default
                var copied = 0
                var errors: [String] = []
                let destination = root.appendingPathComponent("Music", isDirectory: true)
                do { try fm.createDirectory(at: destination, withIntermediateDirectories: true) }
                catch { return (0, [error.localizedDescription]) }
                for source in urls {
                    let access = source.startAccessingSecurityScopedResource()
                    defer { if access { source.stopAccessingSecurityScopedResource() } }
                    guard Self.extensions.contains(source.pathExtension.lowercased()) else {
                        errors.append("\(source.lastPathComponent): unsupported file extension")
                        continue
                    }
                    do {
                        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                        guard values.isRegularFile == true, values.isSymbolicLink != true else {
                            throw StoreError.notRegularFile
                        }
                        // Files already in our Documents directory need only a rescan.
                        if source.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") {
                            continue
                        }
                        let target = Self.uniqueDestination(for: source.lastPathComponent, in: destination)
                        // Copy to a non-audio temporary path and rename on success so
                        // a simultaneous scan cannot index a partly imported file.
                        let temporary = destination.appendingPathComponent(".import-\(UUID().uuidString).tmp")
                        defer { try? fm.removeItem(at: temporary) }
                        let coordinator = NSFileCoordinator()
                        var coordinationError: NSError?
                        var copyError: Error?
                        coordinator.coordinate(readingItemAt: source, options: [], error: &coordinationError) { readable in
                            do { try fm.copyItem(at: readable, to: temporary) }
                            catch { copyError = error }
                        }
                        if let coordinationError { throw coordinationError }
                        if let copyError { throw copyError }
                        try fm.moveItem(at: temporary, to: target)
                        copied += 1
                    } catch {
                        errors.append("\(source.lastPathComponent): \(error.localizedDescription)")
                    }
                }
                return (copied, errors)
            }.value
            isImporting = false
            message = "Imported \(result.0) file\(result.0 == 1 ? "" : "s")."
                + (result.1.isEmpty ? "" : "\n\n" + result.1.prefix(10).joined(separator: "\n"))
                + (result.1.count > 10 ? "\nAnd \(result.1.count - 10) more errors." : "")
            rescan()
        }
    }

    func makeBackup() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(state)
    }

    nonisolated static func readBackup(from source: URL) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            let access = source.startAccessingSecurityScopedResource()
            defer { if access { source.stopAccessingSecurityScopedResource() } }
            var coordinationError: NSError?
            var result: Result<Data, Error>?
            NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { readable in
                result = Result {
                    let handle = try FileHandle(forReadingFrom: readable)
                    defer { try? handle.close() }
                    // Bound the actual read even if a file provider doesn't
                    // report a size, and never block the main UI on downloads.
                    let data = try handle.read(upToCount: 10 * 1024 * 1024 + 1) ?? Data()
                    guard data.count <= 10 * 1024 * 1024 else { throw StoreError.invalidBackup }
                    return data
                }
            }
            if let coordinationError { throw coordinationError }
            guard let result else { throw StoreError.invalidBackup }
            return try result.get()
        }.value
    }

    // A JSON backup contains playlist/favorite references, never audio files.
    // It is only applied after a separate replacement confirmation in the UI.
    func restoreBackup(_ data: Data) throws {
        guard data.count <= 10 * 1024 * 1024 else { throw StoreError.invalidBackup }
        var decoded = try JSONDecoder().decode(LibraryState.self, from: data)
        guard decoded.version == 1 || (decoded.version == 2 && decoded.trackOverrides != nil) else {
            throw StoreError.unsupportedVersion
        }
        // If existing state could not be read, we cannot preserve its edits from
        // a legacy backup. A v2 restore explicitly replaces edits after consent.
        if !canSave && decoded.version == 1 && decoded.trackOverrides == nil {
            throw StoreError.cannotPreserveEdits
        }
        // Old backups know nothing about song edits. Preserve the current edits
        // instead of silently deleting them. A v2 backup replaces them.
        if decoded.version == 1 && decoded.trackOverrides == nil, state.version == 2 {
            decoded.version = 2
            decoded.trackOverrides = state.trackOverrides ?? [:]
        } else if decoded.version == 1 && decoded.trackOverrides != nil {
            // Support backups from an early draft without letting v1 writers erase edits.
            decoded.version = 2
        }
        guard Set(decoded.playlists.map(\.id)).count == decoded.playlists.count,
            decoded.playlists.allSatisfy({ playlist in
                !playlist.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && Set(playlist.trackIDs).count == playlist.trackIDs.count
                    && playlist.trackIDs.allSatisfy({ !$0.isEmpty && safeURL(for: $0) != nil })
            }), decoded.favoriteIDs.allSatisfy({ !$0.isEmpty && safeURL(for: $0) != nil }),
            (decoded.trackOverrides ?? [:]).allSatisfy({ id, edit in
                !id.isEmpty && safeURL(for: id) != nil &&
                    [edit.title, edit.artist, edit.album].allSatisfy {
                        !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 500
                    }
            })
        else { throw StoreError.invalidBackup }
        // Complete the atomic write first, preserving current in-memory state
        // if the device has no free space or cannot write the replacement.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(decoded).write(to: stateURL, options: .atomic)
        state = decoded
        applyMetadataOverrides()
        canSave = true
        message = "Restored \(decoded.playlists.count) playlists and \(decoded.favoriteIDs.count) favorites. Song edits were preserved or replaced as described before restore. Missing files will reappear when copied to their original paths."
    }

    private func save() {
        guard canSave else {
            message = "Changes cannot be saved because the saved library state could not be read. Existing saved data has been preserved."
            return
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)
            try data.write(to: stateURL, options: .atomic)
        } catch {
            message = "Could not save favorites and playlists: \(error.localizedDescription)"
        }
    }

    nonisolated private static func uniqueDestination(for filename: String, in directory: URL) -> URL {
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var candidate = directory.appendingPathComponent(filename)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base) (\(suffix)).\(ext)")
            suffix += 1
        }
        return candidate
    }

    nonisolated private static func scan(root: URL, cache: [String: Track]) async -> (tracks: [Track], error: String?) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        var scanError: String?
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, error in
                scanError = "Some files could not be read. \(error.localizedDescription)"
                return true
            }) else { return ([], "Could not open the music folder.") }
        var result: [Track] = []
        for case let url as URL in enumerator {
            if Task.isCancelled { break }
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            guard values.isRegularFile == true, extensions.contains(url.pathExtension.lowercased()) else { continue }
            let prefix = root.standardizedFileURL.path + "/"
            guard url.standardizedFileURL.path.hasPrefix(prefix) else { continue }
            let id = String(url.standardizedFileURL.path.dropFirst(prefix.count))
            let size = Int64(values.fileSize ?? 0)
            let modified = values.contentModificationDate ?? .distantPast
            if let cached = cache[id], cached.byteCount == size, cached.modifiedAt == modified {
                result.append(cached)
                continue
            }
            let asset = AVURLAsset(url: url)
            var title = url.deletingPathExtension().lastPathComponent
            var artist = "Unknown artist"
            var album = "Unknown album"
            var artwork: Data?
            let metadata = (try? await asset.load(.commonMetadata)) ?? []
            for item in metadata {
                if Task.isCancelled { break }
                switch item.commonKey {
                case .commonKeyTitle:
                    if let value = try? await item.load(.stringValue), !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { title = value }
                case .commonKeyArtist:
                    if let value = try? await item.load(.stringValue), !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { artist = value }
                case .commonKeyAlbumName:
                    if let value = try? await item.load(.stringValue), !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { album = value }
                case .commonKeyArtwork:
                    if artwork == nil, let data = try? await item.load(.dataValue), let image = UIImage(data: data) {
                        let maxSide: CGFloat = 512
                        let factor = min(1, maxSide / max(image.size.width, image.size.height))
                        let size = CGSize(width: max(1, image.size.width * factor), height: max(1, image.size.height * factor))
                        let format = UIGraphicsImageRendererFormat()
                        format.scale = 1
                        artwork = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                            image.draw(in: CGRect(origin: .zero, size: size))
                        }.jpegData(compressionQuality: 0.8)
                    }
                default: break
                }
            }
            let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
            result.append(Track(id: id, title: title, artist: artist, album: album,
                duration: duration.isFinite && duration > 0 ? duration : 0,
                artwork: artwork, byteCount: size, modifiedAt: modified))
        }
        return (result.sorted {
            let lhs = $0.title.musicSortKey
            let rhs = $1.title.musicSortKey
            return lhs == rhs ? $0.id < $1.id : lhs < rhs
        }, scanError)
    }
}

private enum StoreError: LocalizedError {
    case notRegularFile, unsupportedVersion, invalidBackup, cannotPreserveEdits
    var errorDescription: String? {
        switch self {
        case .notRegularFile: return "The selected item is not a regular audio file."
        case .unsupportedVersion: return "This library state was created by a different app version."
        case .invalidBackup: return "This is not a valid MusicCloud playlist backup, or it exceeds 10 MB."
        case .cannotPreserveEdits: return "The existing library state could not be read, so song edits cannot be preserved from this older backup. No data was changed. Preserve the existing library data before recovery."
        }
    }
}

