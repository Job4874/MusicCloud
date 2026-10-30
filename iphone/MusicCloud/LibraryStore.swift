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
    @Published private(set) var lastScanSucceeded = false
    @Published private(set) var isLibraryProtected = false

    nonisolated static let extensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "caf"]
    let documentsURL: URL
    private let stateURL: URL
    private var canSave = true
    private var scanTask: Task<Void, Never>?
    private var scanGeneration = UUID()
    // Keep file metadata separate from display edits so a reset reveals the original tags.
    private var scannedTracks: [Track] = []
    @Published private var playlistArtwork: [UUID: Data] = [:]

    init() {
        let fm = FileManager.default
        documentsURL = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MusicCloud", isDirectory: true)
        stateURL = support.appendingPathComponent("library-state-v3.json")
        do {
            let loaded = try LibraryStateReader.read(documentsURL: documentsURL, stateURL: stateURL,
                allowLegacyMigration: true, legacyStateURL: support.appendingPathComponent("library-state.json"))
            // Validate and bound the complete projection plus its source archive
            // before creating a new state file. Existing source files stay intact.
            let encoded = try Self.encodedState(loaded)
            try fm.createDirectory(at: documentsURL, withIntermediateDirectories: true)
            try fm.createDirectory(at: support, withIntermediateDirectories: true)
            if !fm.fileExists(atPath: stateURL.path) {
                try encoded.write(to: stateURL, options: .atomic)
            }
            state = loaded
        } catch LibrarySchemaError.incompatibleLayout {
            isLibraryProtected = true
            canSave = false
            message = "The saved library could not be migrated safely. Its original files have been preserved for recovery."
        } catch LibrarySchemaError.newerLibrary {
            isLibraryProtected = true
            canSave = false
            message = "This library contains data from a newer MusicCloud version. It has not been changed. Use the matching newer app or restore from a verified backup after migration."
        } catch StoreError.unsupportedVersion {
            isLibraryProtected = true
            canSave = false
            message = "This library uses an unsupported MusicCloud version. It has not been changed. Use the matching newer app or restore from a verified backup after migration."
        } catch {
            // Unreadable state must not be replaced by defaults or a restore.
            isLibraryProtected = true
            canSave = false
            message = "The saved library could not be opened safely. No library changes were made. Preserve the existing data for recovery. \(error.localizedDescription)"
        }
    }

    func requireWritableLibrary() -> Bool {
        guard canSave else {
            message = "The saved library could not be opened safely. No changes were made."
            return false
        }
        return true
    }

    var favorites: [Track] { tracks.filter { state.favoriteIDs.contains($0.id) } }
    var totalSize: String {
        ByteCountFormatter.string(fromByteCount: tracks.reduce(0) { $0 + $1.byteCount }, countStyle: .file)
    }

    func track(id: String) -> Track? { tracks.first { $0.id == id } }
    func playlist(id: UUID) -> Playlist? { state.playlists.first { $0.id == id } }
    func playlistTracks(_ playlist: Playlist) -> [Track] {
        let byID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        let ids = playlist.entries.map { $0.compactMap(\.trackID) } ?? playlist.trackIDs
        return ids.compactMap { byID[$0] }
    }

    func playlistEntryCount(_ playlist: Playlist) -> Int { playlist.entries?.count ?? playlist.trackIDs.count }

    func artwork(for playlist: Playlist) -> Data? {
        playlistArtwork[playlist.id] ?? playlistTracks(playlist).first?.artwork
    }

    // Promote a legacy native playlist only when an explicit edit needs entries.
    // Each occurrence receives its own identity, including repeated audio paths.
    private func editableEntries(for playlist: Playlist) -> [PlaylistEntry] {
        if let entries = playlist.entries { return entries }
        return playlist.trackIDs.map { id in
            let track = self.track(id: id)
            return PlaylistEntry(trackID: id,
                title: track?.title ?? (id as NSString).lastPathComponent,
                artist: track?.artist ?? "Unknown artist", status: track == nil ? "missing" : "downloaded")
        }
    }

    private func setEntries(_ entries: [PlaylistEntry], at index: Int, in candidate: inout LibraryState) {
        candidate.playlists[index].entries = entries
        candidate.playlists[index].trackIDs = entries.compactMap(\.trackID)
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
        lastScanSucceeded = false
        let root = documentsURL
        let cache = Dictionary(uniqueKeysWithValues: scannedTracks.map { ($0.id, $0) })
        let exportData = state.legacyArchive?.originalExportData
        let playlistIDs = state.playlists.map(\.id)
        scanTask = Task {
            let worker = Task.detached(priority: .userInitiated) {
                var artworkWarning: String?
                let artwork: LibraryArtworkStore?
                do { artwork = try LibraryArtworkStore(documentsURL: root, legacyExportData: exportData) }
                catch {
                    artwork = nil
                    artworkWarning = "Some saved artwork could not be opened. The original artwork files have been preserved."
                }
                let scan = await Self.scan(root: root, cache: cache, artworkStore: artwork)
                let playlistImages = Dictionary(uniqueKeysWithValues: playlistIDs.compactMap { id in
                    artwork?.artwork(for: id).map { (id, $0) }
                })
                return (tracks: scan.tracks, error: scan.error, artworkWarning: artworkWarning, playlistImages: playlistImages)
            }
            let result = await withTaskCancellationHandler(operation: {
                await worker.value
            }, onCancel: { worker.cancel() })
            guard !Task.isCancelled, scanGeneration == generation else { return }
            lastScanSucceeded = result.error == nil
            scannedTracks = result.tracks
            playlistArtwork = result.playlistImages
            applyMetadataOverrides()
            isScanning = false
            lastScan = Date()
            if let error = result.error ?? result.artworkWarning { message = error }
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
        guard requireWritableLibrary() else { return false }
        guard scannedTracks.contains(where: { $0.id == id }) else {
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
        var candidate = state
        candidate.trackOverrides = edits
        for index in candidate.playlists.indices {
            guard var entries = candidate.playlists[index].entries else { continue }
            for entryIndex in entries.indices where entries[entryIndex].trackID == id {
                entries[entryIndex].title = values[0]
                entries[entryIndex].artist = values[1]
            }
            setEntries(entries, at: index, in: &candidate)
        }
        guard commit(candidate) else { return false }
        applyMetadataOverrides()
        return true
    }

    @discardableResult
    func resetMetadata(id: String) -> Bool {
        guard requireWritableLibrary() else { return false }
        var edits = state.trackOverrides ?? [:]
        edits.removeValue(forKey: id)
        var candidate = state
        candidate.trackOverrides = edits
        if let original = scannedTracks.first(where: { $0.id == id }) {
            for index in candidate.playlists.indices {
                guard var entries = candidate.playlists[index].entries else { continue }
                for entryIndex in entries.indices where entries[entryIndex].trackID == id {
                    entries[entryIndex].title = original.title
                    entries[entryIndex].artist = original.artist
                }
                setEntries(entries, at: index, in: &candidate)
            }
        }
        guard commit(candidate) else { return false }
        applyMetadataOverrides()
        return true
    }

    func toggleFavorite(_ track: Track) {
        guard requireWritableLibrary() else { return }
        var candidate = state
        if candidate.favoriteIDs.contains(track.id) { candidate.favoriteIDs.remove(track.id) }
        else { candidate.favoriteIDs.insert(track.id) }
        commit(candidate)
    }

    @discardableResult
    func createPlaylist(name: String) -> UUID? {
        guard requireWritableLibrary() else { return nil }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 500 else { return nil }
        let playlist = Playlist(name: name, entries: [])
        var candidate = state
        candidate.playlists.append(playlist)
        guard commit(candidate) else { return nil }
        return playlist.id
    }

    func renamePlaylist(id: UUID, name: String) {
        guard requireWritableLibrary() else { return }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 500, let index = state.playlists.firstIndex(where: { $0.id == id }) else { return }
        var candidate = state
        candidate.playlists[index].name = name
        commit(candidate)
    }

    func deletePlaylist(id: UUID) {
        guard requireWritableLibrary() else { return }
        var candidate = state
        candidate.playlists.removeAll { $0.id == id }
        commit(candidate)
    }

    func add(_ track: Track, to playlistID: UUID) {
        guard requireWritableLibrary() else { return }
        guard let index = state.playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        guard !state.playlists[index].trackIDs.contains(track.id) else { return }
        var candidate = state
        var entries = editableEntries(for: candidate.playlists[index])
        entries.append(PlaylistEntry(trackID: track.id, title: track.title, artist: track.artist, status: "downloaded"))
        setEntries(entries, at: index, in: &candidate)
        commit(candidate)
    }

    func removeTracks(at offsets: IndexSet, from playlistID: UUID) {
        guard requireWritableLibrary() else { return }
        guard let index = state.playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        var candidate = state
        var entries = editableEntries(for: candidate.playlists[index])
        guard offsets.allSatisfy({ entries.indices.contains($0) }) else { return }
        entries.remove(atOffsets: offsets)
        setEntries(entries, at: index, in: &candidate)
        commit(candidate)
    }

    func removeTrack(id: String, from playlistID: UUID) {
        guard requireWritableLibrary() else { return }
        guard let index = state.playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        var candidate = state
        var entries = editableEntries(for: candidate.playlists[index])
        entries.removeAll { $0.trackID == id }
        setEntries(entries, at: index, in: &candidate)
        commit(candidate)
    }

    func moveTracks(from source: IndexSet, to destination: Int, in playlistID: UUID) {
        guard requireWritableLibrary() else { return }
        guard let index = state.playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        var candidate = state
        var entries = editableEntries(for: candidate.playlists[index])
        guard source.allSatisfy({ entries.indices.contains($0) }), (0...entries.count).contains(destination) else { return }
        entries.move(fromOffsets: source, toOffset: destination)
        setEntries(entries, at: index, in: &candidate)
        commit(candidate)
    }

    // Called only after a destructive confirmation in the UI.
    func deleteFile(_ track: Track) {
        guard requireWritableLibrary() else { return }
        guard let url = safeURL(for: track.id) else { return }
        let previous = state
        var candidate = state
        for index in candidate.playlists.indices where candidate.playlists[index].trackIDs.contains(track.id) {
            var entries = editableEntries(for: candidate.playlists[index])
            for entryIndex in entries.indices where entries[entryIndex].trackID == track.id {
                entries[entryIndex].status = "missing"
            }
            setEntries(entries, at: index, in: &candidate)
        }
        // Persist the retained references first. A failed state write must never
        // be followed by deleting the audio file.
        guard commit(candidate) else { return }
        do {
            try FileManager.default.removeItem(at: url)
            tracks.removeAll { $0.id == track.id }
            scannedTracks.removeAll { $0.id == track.id }
            rescan()
        } catch {
            let deletionError = error.localizedDescription
            let rolledBack = commit(previous)
            message = "Could not delete \(track.filename): \(deletionError)"
                + (rolledBack ? "" : " The saved entries were retained as missing; the audio file is still present.")
        }
    }

    func importFiles(_ urls: [URL]) {
        guard requireWritableLibrary() else { return }
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
        guard canSave else { throw StoreError.newerLibrary }
        return try Self.encodedState(state)
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
                    let data = try handle.read(upToCount: LibraryStateReader.maximumStateBytes + 1) ?? Data()
                    guard data.count <= LibraryStateReader.maximumStateBytes else { throw StoreError.invalidBackup }
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
        // A recovery restore must not replace state from a newer app silently.
        guard canSave, !isLibraryProtected else { throw StoreError.newerLibrary }
        guard data.count <= LibraryStateReader.maximumStateBytes else { throw StoreError.invalidBackup }
        try LibrarySchemaGuard.validate(data)
        var decoded = try JSONDecoder().decode(LibraryState.self, from: data)
        guard (1...3).contains(decoded.version) else {
            throw StoreError.unsupportedVersion
        }
        try LibrarySchemaGuard.validateState(decoded)
        // A v1 restore cannot express display edits or the preserved source
        // archive. Preserve those fields rather than losing them implicitly.
        if decoded.version == 1 && decoded.trackOverrides == nil {
            decoded.trackOverrides = state.trackOverrides ?? [:]
        }
        if decoded.legacyArchive == nil { decoded.legacyArchive = state.legacyArchive }
        decoded.version = 3
        decoded.trackOverrides = decoded.trackOverrides ?? [:]
        // Complete the atomic write first, preserving current in-memory state
        // if the device has no free space or cannot write the replacement.
        let mergedData = try Self.encodedState(decoded)
        try mergedData.write(to: stateURL, options: .atomic)
        state = decoded
        applyMetadataOverrides()
        canSave = true
        message = "Restored \(decoded.playlists.count) playlists and \(decoded.favoriteIDs.count) favorites. Unavailable playlist entries and preserved source data remain in the backup. Missing files will reappear when copied to their original paths."
    }

    private static func encodedState(_ value: LibraryState) throws -> Data {
        try LibrarySchemaGuard.validateState(value)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= LibraryStateReader.maximumStateBytes else { throw StoreError.libraryTooLarge }
        // Check the actual representation too, before any atomic replacement.
        try LibrarySchemaGuard.validate(data)
        return data
    }

    @discardableResult
    private func commit(_ proposed: LibraryState) -> Bool {
        guard canSave else {
            message = "Changes cannot be saved because the saved library state could not be read. Existing saved data has been preserved."
            return false
        }
        do {
            var candidate = proposed
            candidate.version = 3
            candidate.trackOverrides = candidate.trackOverrides ?? [:]
            let data = try Self.encodedState(candidate)
            try data.write(to: stateURL, options: .atomic)
            // Publish only after the complete file write has succeeded.
            state = candidate
            return true
        } catch {
            message = "Could not save library changes. Your previous saved state is unchanged. \(error.localizedDescription)"
            return false
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

    nonisolated private static func scan(root: URL, cache: [String: Track], artworkStore: LibraryArtworkStore?) async -> (tracks: [Track], error: String?) {
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
            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: Set(keys))
            } catch {
                scanError = "Some files could not be read. \(error.localizedDescription)"
                continue
            }
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            if values.isRegularFile == nil && extensions.contains(url.pathExtension.lowercased()) {
                scanError = "Some music files could not be checked. Rescan when they are available."
                continue
            }
            guard values.isRegularFile == true, extensions.contains(url.pathExtension.lowercased()) else { continue }
            let prefix = root.standardizedFileURL.path + "/"
            guard url.standardizedFileURL.path.hasPrefix(prefix) else { continue }
            let id = String(url.standardizedFileURL.path.dropFirst(prefix.count))
            let size = Int64(values.fileSize ?? 0)
            let modified = values.contentModificationDate ?? .distantPast
            if let cached = cache[id], cached.byteCount == size, cached.modifiedAt == modified {
                result.append(Track(id: cached.id, title: cached.title, artist: cached.artist, album: cached.album,
                    duration: cached.duration, artwork: artworkStore?.artwork(for: id) ?? cached.artwork,
                    byteCount: cached.byteCount, modifiedAt: cached.modifiedAt))
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
                artwork: artworkStore?.artwork(for: id) ?? artwork, byteCount: size, modifiedAt: modified))
        }
        return (result.sorted {
            let lhs = $0.title.musicSortKey
            let rhs = $1.title.musicSortKey
            return lhs == rhs ? $0.id < $1.id : lhs < rhs
        }, scanError)
    }
}

private enum StoreError: LocalizedError {
    case notRegularFile, unsupportedVersion, invalidBackup, cannotPreserveEdits, libraryTooLarge, newerLibrary
    var errorDescription: String? {
        switch self {
        case .notRegularFile: return "The selected item is not a regular audio file."
        case .unsupportedVersion: return "This library state was created by a different app version."
        case .invalidBackup: return "This is not a valid MusicCloud playlist backup, or it exceeds the supported size."
        case .libraryTooLarge: return "The library exceeds the supported backup size. No replacement was saved."
        case .cannotPreserveEdits: return "The existing library state could not be read, so song edits cannot be preserved from this older backup. No data was changed. Preserve the existing library data before recovery."
        case .newerLibrary: return "This library or backup cannot be safely opened by this build. No data was changed."
        }
    }
}


