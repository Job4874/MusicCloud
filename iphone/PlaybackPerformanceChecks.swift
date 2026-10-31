import Foundation

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func set(_ newValue: Value) { lock.lock(); value = newValue; lock.unlock() }
    func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
}

@main
enum PlaybackPerformanceChecks {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func snapshot(position: TimeInterval, version: Int = 3) -> PlaybackCheckpoint {
        let tokens = [UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
                      UUID(uuidString: "10000000-0000-0000-0000-000000000002")!]
        return PlaybackCheckpoint(version: version, queueIDs: ["Synthetic/a.m4a", "Synthetic/a.m4a"],
            originalIDs: ["Synthetic/a.m4a", "Synthetic/a.m4a"], currentIndex: 1,
            position: position, shuffled: false, repeatMode: "off", queueTokens: tokens,
            originalTokens: tokens, contextName: "Synthetic playlist",
            playlistID: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!)
    }

    static func wait(_ semaphore: DispatchSemaphore) {
        require(semaphore.wait(timeout: .now() + 20) == .success, "Checkpoint worker did not complete")
    }

    static func save(_ value: PlaybackCheckpoint, to store: PlaybackCheckpointStore) throws {
        let done = DispatchSemaphore(value: 0)
        let result = LockedValue<Result<Void, Error>>(.failure(PlaybackQueueError.invalidCheckpoint))
        store.save(value) {
            require(!Thread.isMainThread, "Checkpoint encoding/IO completion ran on main")
            result.set($0)
            done.signal()
        }
        wait(done)
        try result.get().get()
    }

    static func load(_ store: PlaybackCheckpointStore) -> PlaybackCheckpoint? {
        let done = DispatchSemaphore(value: 0)
        let result = LockedValue<PlaybackCheckpoint?>(nil)
        store.load {
            require(!Thread.isMainThread, "Checkpoint loading ran on main")
            result.set($0)
            done.signal()
        }
        wait(done)
        return result.get()
    }

    static func main() throws {
        // A loading operation completing after Pause must not start audio.
        var intent = PlaybackIntentState()
        intent.requestPlay()
        require(intent.canStartPlayback, "Play did not record user intent")
        intent.requestPause()
        require(!intent.canStartPlayback, "A delayed load could undo Pause")

        intent.requestPlay()
        intent.interruptionBegan()
        intent.interruptionBegan()
        require(!intent.canStartPlayback, "Playback can activate during a call")
        require(intent.interruptionEnded(shouldResume: true) && intent.canStartPlayback,
            "A duplicate interruption notification lost the pre-call playback intent")
        require(!intent.interruptionEnded(shouldResume: true) && intent.canStartPlayback,
            "A duplicate end notification changed active playback")

        intent.interruptionBegan()
        intent.requestPause()
        require(!intent.interruptionEnded(shouldResume: true) && !intent.canStartPlayback,
            "Call ending undid the user's Pause or headphone-disconnect pause")
        intent.requestPlay()
        intent.interruptionBegan()
        require(!intent.interruptionEnded(shouldResume: false) && !intent.canStartPlayback,
            "Playback resumed without iOS shouldResume permission")
        intent.interruptionBegan()
        intent.requestPlay()
        require(!intent.canStartPlayback, "Explicit Play bypassed an active interruption")
        require(intent.interruptionEnded(shouldResume: true) && intent.canStartPlayback,
            "Explicit Play during interruption was not retained safely")
        intent.mediaServicesReset()
        require(!intent.canStartPlayback && !intent.isInterrupted,
            "Media-services reset retained an automatic-start intent")
        intent.interruptionBegan()
        intent.mediaServicesReset()
        intent.requestPlay()
        require(!intent.canStartPlayback && intent.isInterrupted,
            "Media-services reset bypassed an ongoing phone call")
        intent.requestPause()
        require(!intent.interruptionEnded(shouldResume: true),
            "Media-services reset allowed an automatic post-call restart")

        let revision = PlaybackWorkRevision()
        let first = revision.advance(), second = revision.advance()
        require(!revision.isCurrent(first) && revision.isCurrent(second),
            "A superseded file-open result could replace the newest track")
        revision.advance()
        require(!revision.isCurrent(second), "Stop did not invalidate pending file work")

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MusicCloud-playback-checks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("playback-state.json")
        let store = PlaybackCheckpointStore(url: url)
        try save(snapshot(position: 11.25), to: store)
        let restored = load(store)!
        let expected = snapshot(position: 11.25)
        let restoredQueue = try restored.validatedQueueState()
        let expectedQueue = try expected.validatedQueueState()
        require(restored.position == 11.25 && restored.playlistID == expected.playlistID
            && restoredQueue == expectedQueue,
            "Background checkpoint changed duplicate identity, position or playlist origin")

        // A storm of seeks followed by Stop cannot leave an earlier queue on disk.
        let jobs = DispatchGroup()
        let failed = LockedValue(false)
        for position in 0..<120 {
            jobs.enter()
            store.save(snapshot(position: Double(position))) { result in
                if case .failure = result { failed.set(true) }
                jobs.leave()
            }
        }
        jobs.enter()
        store.clear { result in
            if case .failure = result { failed.set(true) }
            jobs.leave()
        }
        require(jobs.wait(timeout: .now() + 20) == .success && !failed.get(), "Ordered save/clear failed")
        require(load(store) == nil && !FileManager.default.fileExists(atPath: url.path),
            "An older queued write resurrected the queue after Stop")

        // A new queue after Stop must win, regardless of earlier work still in flight.
        store.save(snapshot(position: 1)) { _ in }
        store.clear { _ in }
        try save(snapshot(position: 89.5), to: store)
        require(load(store)?.position == 89.5, "A stale Stop or save overwrote a newer queue")

        let originalBytes = try Data(contentsOf: url)
        do {
            try save(snapshot(position: 1, version: 99), to: store)
            fatalError("A future checkpoint schema was accepted")
        } catch {}
        let afterRejection = try Data(contentsOf: url)
        require(afterRejection == originalBytes,
            "A rejected checkpoint modified the existing resume point")

        // Bounded readers reject oversized data before allocating it.
        let oversized = root.appendingPathComponent("oversized.json")
        require(FileManager.default.createFile(atPath: oversized.path, contents: Data()), "Could not create fixture")
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: UInt64(PlaybackCheckpoint.maximumBytes + 1))
        try handle.close()
        require(load(PlaybackCheckpointStore(url: oversized)) == nil, "An oversized checkpoint was loaded")

        let outside = root.appendingPathComponent("preserved.json")
        let outsideBytes = Data("synthetic original bytes".utf8)
        try outsideBytes.write(to: outside)
        let link = root.appendingPathComponent("linked-state.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let linkedStore = PlaybackCheckpointStore(url: link)
        require(load(linkedStore) == nil, "A symbolic-link checkpoint was read")
        do {
            try save(snapshot(position: 3), to: linkedStore)
            fatalError("A symbolic-link checkpoint was overwritten")
        } catch {}
        let preservedOutside = try Data(contentsOf: outside)
        require(preservedOutside == outsideBytes, "Checkpoint IO changed a symlink target")
        print("Playback performance checks passed: user intent survives delayed loads/calls, stale file work is rejected, checkpoint IO runs off main, newest save/Stop ordering holds, duplicate queue/origin survives, invalid/oversized/symlink state is rejected.")
    }
}
