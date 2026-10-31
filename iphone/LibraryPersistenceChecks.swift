import Foundation

private final class OutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: LibraryWriteOutcome?
    func set(_ value: LibraryWriteOutcome) { lock.lock(); self.value = value; lock.unlock() }
    func get() -> LibraryWriteOutcome { lock.lock(); defer { lock.unlock() }; return value! }
}

@main
enum LibraryPersistenceChecks {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }
    static func snapshot(_ name: String) -> LibraryState {
        LibraryState(version: 3, favoriteIDs: [], playlists: [Playlist(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!,
            name: name, entries: [])], trackOverrides: [:])
    }
    static func name(_ value: LibraryState) -> String { value.playlists[0].name }
    static func saved(_ value: LibraryState, by writer: NativeLibraryPersistence) -> LibraryWriteOutcome {
        let done = DispatchSemaphore(value: 0), result = OutcomeBox()
        writer.save(value) {
            require(!Thread.isMainThread, "Library validation/encode/write ran on main")
            result.set($0); done.signal()
        }
        require(done.wait(timeout: .now() + 20) == .success, "Library worker stalled")
        return result.get()
    }
    static func diskName(_ url: URL) throws -> String {
        name(try JSONDecoder().decode(LibraryState.self, from: Data(contentsOf: url)))
    }
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MusicCloud-library-writer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("state.json")
        let original = snapshot("Original")
        try JSONEncoder().encode(original).write(to: url, options: .atomic)
        let writer = NativeLibraryPersistence(url: url, durableState: original)

        let jobs = DispatchGroup()
        for index in 0..<100 {
            jobs.enter()
            writer.save(snapshot("Rapid \(index)")) { _ in jobs.leave() }
        }
        let latest = saved(snapshot("Latest like"), by: writer)
        require(jobs.wait(timeout: .now() + 20) == .success && latest.errorDescription == nil,
            "Rapid library saves did not complete")
        let latestDisk = try diskName(url)
        require(latestDisk == "Latest like", "An obsolete optimistic snapshot overwrote the latest save")

        // A latest failure must report the ACTUAL last durable state, rather
        // than the previous optimistic candidate or the startup state.
        var invalid = snapshot("Invalid pending edit")
        invalid.version = 99
        let failed = saved(invalid, by: writer)
        require(failed.errorDescription != nil && name(failed.durableState) == "Latest like",
            "A failed latest save did not return the true durable rollback state")
        let afterFailure = try diskName(url)
        require(afterFailure == "Latest like", "A failed save changed the durable file")

        // UI callbacks filter revisions; an older failure cannot roll back a
        // later successful edit. Both outcomes carry their original ticket.
        let oldDone = DispatchSemaphore(value: 0), oldResult = OutcomeBox()
        let olderRevision = writer.save(invalid) { oldResult.set($0); oldDone.signal() }
        let newer = saved(snapshot("Newer successful edit"), by: writer)
        require(oldDone.wait(timeout: .now() + 20) == .success
            && oldResult.get().revision == olderRevision && olderRevision < newer.revision
            && newer.errorDescription == nil, "Persistence revisions cannot distinguish stale callbacks")

        // Restore is a synchronous serial barrier. Pending optimistic writes
        // are invalidated before it waits for the current atomic write.
        for index in 0..<100 { writer.save(snapshot("Before restore \(index)")) { _ in } }
        let restored = writer.saveDurably(snapshot("Restored backup"), allowArchiveReplacement: true)
        require(restored.errorDescription == nil, "Durable restore barrier failed")
        let restoredDisk = try diskName(url)
        require(restoredDisk == "Restored backup", "A queued older save overwrote the restored backup")
        let next = saved(snapshot("Edit after restore"), by: writer)
        require(next.revision > restored.revision && next.errorDescription == nil,
            "Editing after restore did not use a fresh revision")

        // A save before deletion must be durable. Simulate a real IO failure
        // and exercise the same success gate that guards LibraryStore deletion.
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        let audio = root.appendingPathComponent("synthetic-audio.m4a")
        let audioBytes = Data("synthetic audio fixture".utf8)
        try audioBytes.write(to: audio)
        let deletion = writer.saveDurably(snapshot("Missing references"))
        if deletion.errorDescription == nil { try FileManager.default.removeItem(at: audio) }
        let remainingAudio = try Data(contentsOf: audio)
        require(deletion.errorDescription != nil && remainingAudio == audioBytes
            && name(deletion.durableState) == "Edit after restore",
            "A failed durable save allowed deletion or returned a fictitious rollback state")
        try FileManager.default.removeItem(at: url)
        let recovered = writer.saveDurably(snapshot("Recovered storage"))
        require(recovered.errorDescription == nil, "Writer could not recover after IO failure")

        // Normal edits cannot substitute the immutable original archive.
        var changedArchive = snapshot("Changed immutable archive")
        changedArchive.legacyArchive = LegacyLibraryArchive(originalExportData: Data("invalid".utf8),
            sourceFilename: "synthetic.json", sidecarData: [:])
        let rejected = saved(changedArchive, by: writer)
        require(rejected.errorDescription != nil && name(rejected.durableState) == "Recovered storage",
            "Normal persistence allowed replacing an unvalidated original archive")
        let rejectedRestore = writer.saveDurably(changedArchive, allowArchiveReplacement: true)
        require(rejectedRestore.errorDescription != nil, "Restore allowed an invalid source archive")
        print("Library persistence checks passed: off-main ordered/coalesced writes, actual durable rollback, stale callback revisions, restore barrier, failed durable-save deletion gate, IO recovery and immutable archive validation.")
    }
}
