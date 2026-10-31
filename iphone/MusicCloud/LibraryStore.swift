import AVFoundation
import Foundation
import OSLog
import SwiftUI
import UIKit

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var state = LibraryState()
    @Published private(set) var isScanning = false
    @Published private(set) var isImporting = false
    @Published private(set) var isSaving = false
    @Published var message: String?
    @Published private(set) var lastScan: Date?
    @Published private(set) var lastScanSucceeded = false
    @Published private(set) var isLibraryProtected = false
    @Published private(set) var catalogRevision = 0
    @Published private(set) var tracksRevision = 0

    nonisolated static let extensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "caf"]
    let documentsURL: URL
    private let stateURL: URL
    private let catalogURL: URL
    private var canSave = true
    private var scanTask: Task<Void, Never>?
    private var scanGeneration = UUID()
    // Keep file metadata separate from display edits so a reset reveals the original tags.
    private var scannedTracks: [Track] = []
    @Published private var playlistArtwork: [UUID: Data] = [:]
    private var unavailableArtwork: [UUID: Data] = [:]
    private var importedDetails: [LegacyRelativePath: LegacyTrackDisplay] = [:]
    private var tracksByID: [String: Track] = [:]
    private var tracksByPlaylist: [UUID: [Track]] = [:]
    private var cachedTotalSize = "0 KB"
    private var persistence: NativeLibraryPersistence?
    private var saveRevision: UInt64 = 0

    init() {
        let fm = FileManager.default
        documentsURL = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MusicCloud", isDirectory: true)
        stateURL = support.appendingPathComponent("library-state-v3.json")
        catalogURL = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MusicCloud", isDirectory: true).appendingPathComponent("catalog-v1.json")
        do {
            let previous = try LibraryStateReader.read(documentsURL: documentsURL, stateURL: stateURL,
                allowLegacyMigration: true, legacyStateURL: support.appendingPathComponent("library-state.json"))
            let loaded = LikedCollection.merging(previous)
            let nativeStateExists = fm.fileExists(atPath: stateURL.path)
            let needsStateWrite = !nativeStateExists || previous.playlists != loaded.playlists
            // The reader already strictly validated an unchanged native state.
            // Re-encoding/re-validating its immutable archive on every launch
            // delays the first frame without making an unchanged file safer.
            let encoded: Data?
            if needsStateWrite { encoded = try Self.encodedState(loaded) }
            else { encoded = nil }
            let details = try LegacyLibraryMigration.displayMetadata(in: loaded.legacyArchive)
            try fm.createDirectory(at: documentsURL, withIntermediateDirectories: true)
            try fm.createDirectory(at: support, withIntermediateDirectories: true)
            if let encoded {
                if nativeStateExists {
                    let backup = support.appendingPathComponent("library-state-before-liked-merge.json")
                    if !fm.fileExists(atPath: backup.path) {
                        let original = try LegacyLibraryMigration.readBoundedFile(stateURL,
                            maximumBytes: LibraryStateReader.maximumStateBytes)
                        try original.write(to: backup, options: .atomic)
                    }
                }
                try encoded.write(to: stateURL, options: .atomic)
            }
            state = loaded
            importedDetails = details
            persistence = NativeLibraryPersistence(url: stateURL, durableState: loaded)
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

    var likedPlaylistID: UUID? { LikedCollection.playlistID(in: state) }
    var visiblePlaylists: [Playlist] { state.playlists.filter { $0.id != likedPlaylistID } }
    var likedTracks: [Track] { likedPlaylistID.flatMap { tracksByPlaylist[$0] } ?? [] }
    var favorites: [Track] { likedTracks }
    var totalSize: String { cachedTotalSize }
    func isLiked(_ track: Track) -> Bool {
        state.favoriteIDs.contains(track.id) || likedTrackIDs.contains(track.id)
    }
    private var likedTrackIDs = Set<String>()

    func track(id: String) -> Track? { tracksByID[id] }
    func track(for entry: PlaylistEntry) -> Track? {
        guard let id = entry.trackID, let original = track(id: id) else { return nil }
        return applyingEntryDetails(entry, to: original)
    }

    private func applyingEntryDetails(_ entry: PlaylistEntry, to original: Track) -> Track {
        guard state.trackOverrides?[original.id] == nil else { return original }
        return Track(id: original.id,
            title: entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? original.title : entry.title,
            artist: entry.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? original.artist : entry.artist,
            album: original.album, duration: original.duration, artwork: original.artwork,
            byteCount: original.byteCount, modifiedAt: original.modifiedAt)
    }
    func playlist(id: UUID) -> Playlist? { state.playlists.first { $0.id == id } }
    func playlistTracks(_ playlist: Playlist) -> [Track] {
        tracksByPlaylist[playlist.id] ?? []
    }

    func playlistEntryCount(_ playlist: Playlist) -> Int { playlist.entries?.count ?? playlist.trackIDs.count }

    func artwork(for playlist: Playlist) -> Data? {
        playlistArtwork[playlist.id] ?? playlistTracks(playlist).lazy.compactMap(\.artwork).first
    }

    func artwork(for entry: PlaylistEntry) -> Data? {
        entry.trackID.flatMap { tracksByID[$0]?.artwork } ?? unavailableArtwork[entry.id]
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
        let cacheURL = catalogURL
        let cache = Dictionary(uniqueKeysWithValues: scannedTracks.map { ($0.id, $0) })
        let allowCachedPreview = scannedTracks.isEmpty && tracks.isEmpty && lastScan == nil
        let exportData = state.legacyArchive?.originalExportData
        let playlistIDs = state.playlists.map(\.id)
        let playlistEntries = state.playlists.flatMap { $0.entries ?? [] }
        var supplementalArtwork: [String: String] = [:]
        for playlist in state.playlists {
            for entry in playlist.entries ?? [] {
                guard let path = entry.trackID, let video = entry.sourceVideoID,
                    video.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil else { continue }
                supplementalArtwork[path] = "Artwork/\(video).jpg"
            }
        }
        let extraArtwork = supplementalArtwork
        scanTask = Task {
            let worker = Task.detached(priority: .userInitiated) { [weak self] in
                var cached = cache
                var loadedPersistedCache = false
                if cached.isEmpty,
                    let data = try? LegacyLibraryMigration.readBoundedFile(cacheURL, maximumBytes: 8 * 1024 * 1024),
                    let records = try? JSONDecoder().decode([TrackCatalogRecord].self, from: data), records.count <= 50_000 {
                    for record in records { if let track = record.track { cached[track.id] = track } }
                    loadedPersistedCache = !cached.isEmpty
                }
                var artworkWarning: String?
                let artwork: LibraryArtworkStore?
                do { artwork = try LibraryArtworkStore(documentsURL: root, legacyExportData: exportData,
                    supplemental: extraArtwork) }
                catch {
                    artwork = nil
                    artworkWarning = "Some saved artwork could not be opened. The original artwork files have been preserved."
                }
                let playlistImages = Dictionary(uniqueKeysWithValues: playlistIDs.compactMap { id in
                    artwork?.artwork(for: id).map { (id, $0) }
                })
                func unavailableImages(available: Set<String>) -> [UUID: Data] {
                    var images: [UUID: Data] = [:]
                    for entry in playlistEntries where entry.trackID.map({ !available.contains($0) }) ?? true {
                        var reference: String?
                        if case .object(let raw)? = entry.legacyData, case .string(let path)? = raw["artwork"] { reference = path }
                        if reference == nil, let video = entry.sourceVideoID,
                            video.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil {
                            reference = "Artwork/\(video).jpg"
                        }
                        if let reference, let image = artwork?.art(reference: reference) { images[entry.id] = image }
                    }
                    return images
                }
                if allowCachedPreview, loadedPersistedCache, let artwork, !Task.isCancelled {
                    let preview = cached.values.map { track in
                        Track(id: track.id, title: track.title, artist: track.artist, album: track.album,
                            duration: track.duration, artwork: artwork.artwork(for: track.id) ?? track.artwork,
                            byteCount: track.byteCount, modifiedAt: track.modifiedAt)
                    }
                    let previewUnavailable = unavailableImages(available: Set(preview.map(\.id)))
                    await MainActor.run { [weak self] in
                        guard let self, !Task.isCancelled, self.scanGeneration == generation,
                            self.canSave, !self.isLibraryProtected, self.scannedTracks.isEmpty else { return }
                        self.scannedTracks = preview
                        self.playlistArtwork = playlistImages
                        self.unavailableArtwork = previewUnavailable
                        // This is a disposable display preview. Only a completed
                        // filesystem scan may mark success and restore a queue.
                        self.applyMetadataOverrides()
                    }
                }
                let scan = await Self.scan(root: root, cache: cached, artworkStore: artwork)
                if scan.error == nil, !Task.isCancelled,
                    let data = try? JSONEncoder().encode(scan.tracks.map {
                        TrackCatalogRecord($0, embeddedArtwork: artwork?.artwork(for: $0.id) == nil ? $0.artwork : nil)
                    }), data.count <= 8 * 1024 * 1024 {
                    try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? data.write(to: cacheURL, options: .atomic)
                }
                let available = Set(scan.tracks.map(\.id))
                return (tracks: scan.tracks, error: scan.error, artworkWarning: artworkWarning,
                    playlistImages: playlistImages, unavailableImages: unavailableImages(available: available))
            }
            let result = await withTaskCancellationHandler(operation: {
                await worker.value
            }, onCancel: { worker.cancel() })
            guard !Task.isCancelled, scanGeneration == generation else { return }
            lastScanSucceeded = result.error == nil
            scannedTracks = result.tracks
            playlistArtwork = result.playlistImages
            unavailableArtwork = result.unavailableImages
            applyMetadataOverrides()
            isScanning = false
            lastScan = Date()
            if let error = result.error ?? result.artworkWarning { message = error }
        }
    }

    private func applyMetadataOverrides() {
        tracks = scannedTracks.map { track in
            let edit = state.trackOverrides?[track.id]
            let detail = (try? LegacyRelativePath(track.id)).flatMap { importedDetails[$0] }
            return Track(id: track.id, title: edit?.title ?? detail?.title ?? track.title,
                artist: edit?.artist ?? detail?.artist ?? track.artist, album: edit?.album ?? track.album,
                duration: track.duration, artwork: track.artwork, byteCount: track.byteCount,
                modifiedAt: track.modifiedAt)
        }.sorted {
            let lhs = $0.title.musicSortKey, rhs = $1.title.musicSortKey
            return lhs == rhs ? $0.id < $1.id : lhs < rhs
        }
        rebuildIndexes()
        tracksRevision &+= 1
    }

    private func rebuildIndexes() {
        tracksByID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        cachedTotalSize = ByteCountFormatter.string(fromByteCount: tracks.reduce(0) { $0 + $1.byteCount }, countStyle: .file)
        var lists: [UUID: [Track]] = [:]
        for playlist in state.playlists {
            if let entries = playlist.entries {
                lists[playlist.id] = entries.compactMap { entry in
                    guard let id = entry.trackID, let original = tracksByID[id] else { return nil }
                    return applyingEntryDetails(entry, to: original)
                }
            } else { lists[playlist.id] = playlist.trackIDs.compactMap { tracksByID[$0] } }
        }
        tracksByPlaylist = lists
        likedTrackIDs = Set(state.playlists.first { $0.id == likedPlaylistID }?.trackIDs ?? [])
        catalogRevision &+= 1
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
        // A path override changes display only. Keep each playlist occurrence's
        // saved source text, so Reset does not flatten distinct imported titles.
        guard commit(candidate) else { return false }
        applyMetadataOverrides()
        return true
    }

    @discardableResult
    func resetMetadata(id: String) -> Bool {
        guard requireWritableLibrary() else { return false }
        var edits = state.trackOverrides ?? [:]
        let previousEdit = edits.removeValue(forKey: id)
        var candidate = state
        candidate.trackOverrides = edits
        if let previousEdit, let original = scannedTracks.first(where: { $0.id == id }) {
            let detail = (try? LegacyRelativePath(id)).flatMap { importedDetails[$0] }
            for index in candidate.playlists.indices {
                guard var entries = candidate.playlists[index].entries else { continue }
                for entryIndex in entries.indices where entries[entryIndex].trackID == id {
                    // Older builds copied the override into entries too.
                    // Recover only those matching copies from their retained
                    // source object; leave already preserved occurrence text.
                    guard entries[entryIndex].title == previousEdit.title,
                        entries[entryIndex].artist == previousEdit.artist else { continue }
                    var sourceTitle: String?
                    var sourceArtist: String?
                    if case .object(let raw)? = entries[entryIndex].legacyData {
                        if case .string(let value)? = raw["title"] { sourceTitle = value }
                        if case .string(let value)? = raw["artist"] { sourceArtist = value }
                    }
                    entries[entryIndex].title = sourceTitle ?? detail?.title ?? original.title
                    entries[entryIndex].artist = sourceArtist ?? detail?.artist ?? original.artist
                }
                setEntries(entries, at: index, in: &candidate)
            }
        }
        guard commit(candidate) else { return false }
        applyMetadataOverrides()
        return true
    }

    func toggleFavorite(_ track: Track) {
        toggleLike(track)
    }

    func toggleLike(_ track: Track) {
        guard requireWritableLibrary() else { return }
        var candidate = state
        if isLiked(track) {
            candidate.favoriteIDs.remove(track.id)
            if let index = candidate.playlists.firstIndex(where: { $0.id == likedPlaylistID }) {
                let entries = editableEntries(for: candidate.playlists[index]).filter { $0.trackID != track.id }
                setEntries(entries, at: index, in: &candidate)
            }
        } else {
            candidate.favoriteIDs.insert(track.id)
            if let index = candidate.playlists.firstIndex(where: { $0.id == likedPlaylistID }) {
                var entries = editableEntries(for: candidate.playlists[index])
                entries.insert(PlaylistEntry(trackID: track.id, title: track.title, artist: track.artist, status: "downloaded"), at: 0)
                setEntries(entries, at: index, in: &candidate)
            }
        }
        commit(candidate)
    }

    @discardableResult
    func createPlaylist(name: String) -> UUID? {
        guard requireWritableLibrary() else { return nil }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 500 else { return nil }
        if LikedCollection.recognizes(name) { return likedPlaylistID }
        let playlist = Playlist(name: name, entries: [])
        var candidate = state
        candidate.playlists.append(playlist)
        guard commit(candidate) else { return nil }
        return playlist.id
    }

    func renamePlaylist(id: UUID, name: String) {
        guard requireWritableLibrary() else { return }
        guard id != likedPlaylistID, !LikedCollection.recognizes(name) else { return }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 500, let index = state.playlists.firstIndex(where: { $0.id == id }) else { return }
        var candidate = state
        candidate.playlists[index].name = name
        commit(candidate)
    }

    /// Reorders only user playlists, keeping the canonical Liked Songs
    /// collection protected while preserving the visible list order.
    func movePlaylists(from source: IndexSet, to destination: Int) {
        guard requireWritableLibrary() else { return }
        let visible = state.playlists.filter { $0.id != likedPlaylistID }
        guard source.allSatisfy({ visible.indices.contains($0) }), (0...visible.count).contains(destination) else { return }
        var reordered = visible
        reordered.move(fromOffsets: source, toOffset: destination)

        var candidate = state
        var cursor = 0
        for index in candidate.playlists.indices where candidate.playlists[index].id != likedPlaylistID {
            candidate.playlists[index] = reordered[cursor]
            cursor += 1
        }
        commit(candidate)
    }

    func deletePlaylist(id: UUID) {
        guard requireWritableLibrary() else { return }
        guard id != likedPlaylistID else { return }
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
        if playlistID == likedPlaylistID {
            for offset in offsets { if let path = entries[offset].trackID { candidate.favoriteIDs.remove(path) } }
        }
        entries.remove(atOffsets: offsets)
        setEntries(entries, at: index, in: &candidate)
        commit(candidate)
    }

    func removeTrack(id: String, from playlistID: UUID) {
        guard requireWritableLibrary() else { return }
        guard let index = state.playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        var candidate = state
        var entries = editableEntries(for: candidate.playlists[index])
        if playlistID == likedPlaylistID { candidate.favoriteIDs.remove(id) }
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
        candidate.favoriteIDs.remove(track.id)
        for index in candidate.playlists.indices where candidate.playlists[index].trackIDs.contains(track.id) {
            var entries = editableEntries(for: candidate.playlists[index])
            for entryIndex in entries.indices where entries[entryIndex].trackID == track.id {
                entries[entryIndex].status = "missing"
            }
            setEntries(entries, at: index, in: &candidate)
        }
        // Persist the retained references first. A failed state write must never
        // be followed by deleting the audio file.
        guard commit(candidate, durably: true) else { return }
        do {
            try FileManager.default.removeItem(at: url)
            tracks.removeAll { $0.id == track.id }
            scannedTracks.removeAll { $0.id == track.id }
            rebuildIndexes()
            rescan()
        } catch {
            let deletionError = error.localizedDescription
            let rolledBack = commit(previous, durably: true)
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
        decoded = LikedCollection.merging(decoded)
        // Complete the atomic write first, preserving current in-memory state
        // if the device has no free space or cannot write the replacement.
        _ = try Self.encodedState(decoded)
        let details = try LegacyLibraryMigration.displayMetadata(in: decoded.legacyArchive)
        guard commit(decoded, durably: true, allowArchiveReplacement: true) else {
            throw StoreError.persistenceFailure(message ?? "The restored library could not be saved.")
        }
        importedDetails = details
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
    private func commit(_ proposed: LibraryState, durably: Bool = false,
        allowArchiveReplacement: Bool = false) -> Bool {
        guard canSave, let persistence else {
            message = "Changes cannot be saved because the saved library state could not be read. Existing saved data has been preserved."
            return false
        }
        var candidate = proposed
        candidate.version = 3
        candidate.trackOverrides = candidate.trackOverrides ?? [:]
        if durably {
            let outcome = persistence.saveDurably(candidate, allowArchiveReplacement: allowArchiveReplacement)
            saveRevision = outcome.revision
            isSaving = false
            if let error = outcome.errorDescription {
                state = outcome.durableState
                applyMetadataOverrides()
                message = "Could not save library changes. Unsaved changes were reverted to the last saved library. \(error)"
                return false
            }
            state = candidate
            rebuildIndexes()
            return true
        }
        let background = LibrarySaveBackgroundTask()
        // Snapshot before publishing. Nested arrays/dictionaries use value
        // semantics, so subsequent taps cannot mutate the worker's snapshot.
        saveRevision = persistence.save(candidate) { [weak self] outcome in
            Task { @MainActor [weak self] in
                background.end()
                guard let self, self.saveRevision == outcome.revision else { return }
                self.isSaving = false
                if let error = outcome.errorDescription {
                    self.state = outcome.durableState
                    self.applyMetadataOverrides()
                    self.message = "Could not save library changes. Unsaved changes were reverted to the last saved library. \(error)"
                }
            }
        }
        isSaving = true
        state = candidate
        rebuildIndexes()
        return true
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
        while let item = enumerator.nextObject() {
            guard let url = item as? URL else { continue }
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

@MainActor
private final class LibrarySaveBackgroundTask {
    private static let log = Logger(subsystem: "MusicCloud", category: "LibraryPersistence")
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    init() {
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Save music library") { [weak self] in
            MainActor.assumeIsolated {
                Self.log.info("library background assertion expiry")
                self?.end()
            }
        }
        Self.log.info("library background assertion start id=\(self.identifier.rawValue, privacy: .public)")
    }
    func end() {
        guard identifier != .invalid else { return }
        Self.log.info("library background assertion end id=\(self.identifier.rawValue, privacy: .public)")
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

private enum StoreError: LocalizedError {
    case notRegularFile, unsupportedVersion, invalidBackup, cannotPreserveEdits, libraryTooLarge, newerLibrary
    case persistenceFailure(String)
    var errorDescription: String? {
        switch self {
        case .notRegularFile: return "The selected item is not a regular audio file."
        case .unsupportedVersion: return "This library state was created by a different app version."
        case .invalidBackup: return "This is not a valid MusicCloud playlist backup, or it exceeds the supported size."
        case .libraryTooLarge: return "The library exceeds the supported backup size. No replacement was saved."
        case .cannotPreserveEdits: return "The existing library state could not be read, so song edits cannot be preserved from this older backup. No data was changed. Preserve the existing library data before recovery."
        case .newerLibrary: return "This library or backup cannot be safely opened by this build. No data was changed."
        case .persistenceFailure(let description): return description
        }
    }
}



