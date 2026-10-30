import Foundation

@main
enum PlaybackQueueChecks {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func rejects(_ message: String, _ body: () throws -> Void) {
        do { try body() }
        catch { return }
        fatalError(message)
    }

    static func checkpoint(_ state: PlaybackQueueState) -> PlaybackCheckpoint {
        PlaybackCheckpoint(version: 2, queueIDs: state.queue.map(\.trackID),
            originalIDs: state.original.map(\.trackID), currentIndex: state.currentIndex!,
            position: 83.25, shuffled: true, repeatMode: "all",
            queueTokens: state.queue.map(\.token), originalTokens: state.original.map(\.token))
    }

    static func main() throws {
        let a = "Mix/a.m4a", b = "Mix/b.m4a", c = "Mix/c.m4a"
        var order = PlaybackQueueState()
        require(order.start(trackIDs: [a, b, a, c], at: 2, shuffled: false), "Valid initial queue was rejected")
        let selected = order.currentToken!
        require(selected == order.original[2].token && selected != order.original[0].token,
            "Selecting the second duplicate selected the first occurrence")
        for _ in 0..<20 {
            order.setShuffled(true)
            require(order.queue.count == 4 && order.currentIndex == 0 && order.currentToken == selected,
                "Shuffle dropped a repeated file or changed the playing occurrence")
            require(Set(order.queue.map(\.token)).count == 4, "Shuffle duplicated an occurrence token")
            order.setShuffled(false)
            require(order.queue.map(\.trackID) == [a, b, a, c] && order.currentIndex == 2,
                "Unshuffle restored the wrong duplicate position")
        }
        order.reconcile(availablePaths: [a, b, c])
        require(order.currentIndex == 2 && order.currentToken == selected,
            "A metadata rescan moved the current duplicate to the first matching path")
        require(order.remove(at: 0), "Removing an earlier duplicate failed")
        require(order.queue.map(\.trackID) == [b, a, c] && order.currentIndex == 1 && order.currentToken == selected,
            "Occurrence removal removed every matching file or changed the current occurrence")
        require(!order.remove(at: 1), "Queue removal must not silently remove the playing occurrence")
        order.insertNext(trackID: a)
        let inserted = order.queue[2].token
        require(order.queue.map(\.trackID) == [b, a, a, c] && inserted != selected && order.currentToken == selected,
            "Play next moved/dropped an existing duplicate instead of inserting a new occurrence")
        require(order.remove(at: 2) && !order.original.contains(where: { $0.token == inserted }),
            "Removing the inserted occurrence left a ghost in the unshuffled order")
        order.removeNonplayingPath(b)
        require(order.queue.map(\.trackID) == [a, c] && order.currentIndex == 0 && order.currentToken == selected,
            "Deleting a nonplaying path changed the playing duplicate identity")
        try order.validate()

        let encoded = try JSONEncoder().encode(checkpoint(order))
        let decoded = try JSONDecoder().decode(PlaybackCheckpoint.self, from: encoded)
        let restored = try decoded.validatedQueueState()
        require(decoded.position == 83.25 && restored == order,
            "A checkpoint round trip lost the exact playing occurrence or position")
        let valid = checkpoint(order)
        let wrongMapping = PlaybackCheckpoint(version: 2, queueIDs: valid.queueIDs,
            originalIDs: valid.originalIDs, currentIndex: valid.currentIndex, position: valid.position,
            shuffled: true, repeatMode: "all", queueTokens: Array(valid.queueTokens!.reversed()),
            originalTokens: valid.originalTokens)
        rejects("A token was accepted for a different audio path") { _ = try wrongMapping.validatedQueueState() }
        let reused = PlaybackCheckpoint(version: 2, queueIDs: valid.queueIDs,
            originalIDs: valid.originalIDs, currentIndex: 0, position: 0, shuffled: false,
            repeatMode: "off", queueTokens: [selected, selected], originalTokens: valid.originalTokens)
        rejects("Duplicate occurrence tokens were accepted") { _ = try reused.validatedQueueState() }

        let legacy = PlaybackCheckpoint(version: 1, queueIDs: [b, a, a], originalIDs: [a, b, a],
            currentIndex: 2, position: 16, shuffled: true, repeatMode: "off", queueTokens: nil, originalTokens: nil)
        let upgraded = try legacy.validatedQueueState()
        require(upgraded.currentIndex == 2 && upgraded.queue[2].token == upgraded.original[2].token
            && upgraded.queue[1].token == upgraded.original[0].token,
            "Legacy restoration reused the first matching path token for multiple occurrences")
        let damaged = PlaybackCheckpoint(version: 1, queueIDs: [a, a], originalIDs: [a, b],
            currentIndex: 1, position: 0, shuffled: false, repeatMode: "off", queueTokens: nil, originalTokens: nil)
        rejects("A malformed legacy multiset was accepted") { _ = try damaged.validatedQueueState() }
        let unsafe = PlaybackCheckpoint(version: 1, queueIDs: ["../outside.m4a"], originalIDs: ["../outside.m4a"],
            currentIndex: 0, position: 0, shuffled: false, repeatMode: "off", queueTokens: nil, originalTokens: nil)
        rejects("An unsafe restored file path was accepted") { _ = try unsafe.validatedQueueState() }

        var missing = PlaybackQueueState()
        missing.start(trackIDs: [a, b, a, c], at: 2, shuffled: false)
        let stillPlaying = missing.currentToken
        missing.reconcile(availablePaths: [c])
        require(missing.queue.map(\.trackID) == [a, c] && missing.currentToken == stillPlaying,
            "Reconciliation retained all missing duplicates instead of just the playing occurrence")
        try missing.validate()
        print("Playback queue checks passed: repeated files survive selection, shuffle, rescan, removal, Play next and checkpoint recovery; malformed token/path mappings rejected.")
    }
}
