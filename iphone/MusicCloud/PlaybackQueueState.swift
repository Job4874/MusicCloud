import Foundation

// A queue occurrence has its own identity even when several rows use one file.
// This value type is shared by the player and portable regression checks.
struct PlaybackQueueState: Equatable {
    struct Occurrence: Equatable {
        let token: UUID
        let trackID: String
    }

    var queue: [Occurrence] = []
    var original: [Occurrence] = []
    var currentIndex: Int?

    var currentToken: UUID? {
        guard let currentIndex, queue.indices.contains(currentIndex) else { return nil }
        return queue[currentIndex].token
    }

    @discardableResult
    mutating func start(trackIDs: [String], at index: Int, shuffled: Bool) -> Bool {
        guard trackIDs.indices.contains(index) else { return false }
        original = trackIDs.map { Occurrence(token: UUID(), trackID: $0) }
        if shuffled {
            let selected = original[index]
            queue = [selected] + original.enumerated().filter { $0.offset != index }.map { $0.element }.shuffled()
            currentIndex = 0
        } else {
            queue = original
            currentIndex = index
        }
        return true
    }

    mutating func setShuffled(_ shuffled: Bool) {
        guard let token = currentToken else { return }
        if shuffled {
            guard let selected = queue.first(where: { $0.token == token }) else { return }
            queue = [selected] + queue.filter { $0.token != token }.shuffled()
        } else {
            queue = original
        }
        currentIndex = queue.firstIndex { $0.token == token }
    }

    mutating func insertNext(trackID: String) {
        guard let currentIndex, let token = currentToken else {
            start(trackIDs: [trackID], at: 0, shuffled: false)
            return
        }
        let next = Occurrence(token: UUID(), trackID: trackID)
        queue.insert(next, at: currentIndex + 1)
        if let originalIndex = original.firstIndex(where: { $0.token == token }) {
            original.insert(next, at: originalIndex + 1)
        } else {
            original.append(next)
        }
    }

    @discardableResult
    mutating func remove(at index: Int) -> Bool {
        // Removing the playing row requires a separate playback decision. Queue
        // menus use this operation only for a nonplaying occurrence.
        guard queue.indices.contains(index), index != currentIndex else { return false }
        let selectedToken = currentToken
        let removedToken = queue.remove(at: index).token
        original.removeAll { $0.token == removedToken }
        currentIndex = selectedToken.flatMap { token in queue.firstIndex { $0.token == token } }
        return true
    }

    mutating func removeNonplayingPath(_ path: String) {
        guard let selectedToken = currentToken else { return }
        guard !queue.contains(where: { $0.token == selectedToken && $0.trackID == path }) else { return }
        queue.removeAll { $0.trackID == path }
        original.removeAll { $0.trackID == path }
        currentIndex = queue.firstIndex { $0.token == selectedToken }
    }

    mutating func reconcile(availablePaths: Set<String>) {
        let selectedToken = currentToken
        let keep: (Occurrence) -> Bool = { occurrence in
            availablePaths.contains(occurrence.trackID) || occurrence.token == selectedToken
        }
        queue = queue.filter(keep)
        original = original.filter(keep)
        currentIndex = selectedToken.flatMap { token in queue.firstIndex { $0.token == token } }
    }

    func validate() throws {
        guard queue.count == original.count,
            Set(queue.map(\.token)).count == queue.count,
            Set(original.map(\.token)).count == original.count,
            Set(queue.map(\.token)) == Set(original.map(\.token)) else {
            throw PlaybackQueueError.invalidCheckpoint
        }
        let byToken = Dictionary(uniqueKeysWithValues: original.map { ($0.token, $0.trackID) })
        guard queue.allSatisfy({ byToken[$0.token] == $0.trackID }) else { throw PlaybackQueueError.invalidCheckpoint }
        if queue.isEmpty {
            guard currentIndex == nil else { throw PlaybackQueueError.invalidCheckpoint }
        } else {
            guard let currentIndex, queue.indices.contains(currentIndex) else { throw PlaybackQueueError.invalidCheckpoint }
        }
    }
}

struct PlaybackCheckpoint: Codable {
    static let maximumBytes = 16 * 1024 * 1024
    static let maximumOccurrences = 50_000
    let version: Int
    let queueIDs: [String]
    let originalIDs: [String]
    let currentIndex: Int
    let position: TimeInterval
    let shuffled: Bool
    let repeatMode: String
    let queueTokens: [UUID]?
    let originalTokens: [UUID]?

    func validatedQueueState() throws -> PlaybackQueueState {
        guard version == 1 || version == 2, !queueIDs.isEmpty,
            queueIDs.count <= Self.maximumOccurrences, originalIDs.count <= Self.maximumOccurrences,
            queueIDs.indices.contains(currentIndex), queueIDs.count == originalIDs.count,
            position.isFinite, position >= 0, ["off", "all", "one"].contains(repeatMode),
            queueIDs.allSatisfy(Self.isRelativePath), originalIDs.allSatisfy(Self.isRelativePath) else {
            throw PlaybackQueueError.invalidCheckpoint
        }
        var state = PlaybackQueueState()
        state.currentIndex = currentIndex
        if version == 2 {
            guard let queueTokens, let originalTokens,
                queueTokens.count == queueIDs.count, originalTokens.count == originalIDs.count else {
                throw PlaybackQueueError.invalidCheckpoint
            }
            state.queue = zip(queueTokens, queueIDs).map { .init(token: $0.0, trackID: $0.1) }
            state.original = zip(originalTokens, originalIDs).map { .init(token: $0.0, trackID: $0.1) }
        } else {
            guard queueTokens == nil, originalTokens == nil else { throw PlaybackQueueError.invalidCheckpoint }
            state.original = originalIDs.map { .init(token: UUID(), trackID: $0) }
            // v1 lacked occurrence identities. Consume each original occurrence
            // exactly once rather than mapping all repeated paths to one row.
            var tokensByPath: [String: [UUID]] = [:]
            for occurrence in state.original { tokensByPath[occurrence.trackID, default: []].append(occurrence.token) }
            var consumed: [String: Int] = [:]
            for path in queueIDs {
                let offset = consumed[path, default: 0]
                guard let tokens = tokensByPath[path], tokens.indices.contains(offset) else {
                    throw PlaybackQueueError.invalidCheckpoint
                }
                state.queue.append(.init(token: tokens[offset], trackID: path))
                consumed[path] = offset + 1
            }
        }
        try state.validate()
        return state
    }

    private static func isRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0"), !path.contains(":") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}

enum PlaybackQueueError: Error { case invalidCheckpoint }
