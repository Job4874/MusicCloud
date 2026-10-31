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

struct PlaybackQueueContext: Equatable {
    static let libraryTitle = "Your library"
    let name: String
    let playlistID: UUID?

    static func starting(contextName: String?, playlistID: UUID?) -> Self {
        let trimmed = contextName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let bounded = trimmed.isEmpty ? libraryTitle : String(trimmed.prefix(500))
        return Self(name: bounded, playlistID: playlistID)
    }
}

struct PlaybackCheckpoint: Codable, Sendable {
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
    // Optional defaults preserve source compatibility with v1/v2 fixtures.
    var contextName: String? = nil
    var playlistID: UUID? = nil

    func validatedContext() throws -> PlaybackQueueContext {
        guard (1...3).contains(version) else { throw PlaybackQueueError.invalidCheckpoint }
        if version < 3 {
            guard contextName == nil, playlistID == nil else { throw PlaybackQueueError.invalidCheckpoint }
            return PlaybackQueueContext(name: PlaybackQueueContext.libraryTitle, playlistID: nil)
        }
        if let contextName {
            guard !contextName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                contextName.count <= 500 else { throw PlaybackQueueError.invalidCheckpoint }
        } else if playlistID != nil {
            throw PlaybackQueueError.invalidCheckpoint
        }
        return PlaybackQueueContext(name: contextName ?? PlaybackQueueContext.libraryTitle, playlistID: playlistID)
    }

    func validatedQueueState() throws -> PlaybackQueueState {
        guard (1...3).contains(version), !queueIDs.isEmpty,
            queueIDs.count <= Self.maximumOccurrences, originalIDs.count <= Self.maximumOccurrences,
            queueIDs.indices.contains(currentIndex), queueIDs.count == originalIDs.count,
            position.isFinite, position >= 0, ["off", "all", "one"].contains(repeatMode),
            queueIDs.allSatisfy(Self.isRelativePath), originalIDs.allSatisfy(Self.isRelativePath) else {
            throw PlaybackQueueError.invalidCheckpoint
        }
        _ = try validatedContext()
        var state = PlaybackQueueState()
        state.currentIndex = currentIndex
        if version >= 2 {
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

    static func isRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0"), !path.contains(":") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}

enum PlaybackQueueError: Error { case invalidCheckpoint }

// The user's intent is separate from whether the audio hardware is currently
// playing. A delayed file open or interruption ending must never undo Pause.
struct PlaybackIntentState: Equatable {
    private(set) var wantsPlayback = false
    private(set) var isInterrupted = false
    private var resumeAfterInterruption = false

    var canStartPlayback: Bool { wantsPlayback && !isInterrupted }

    func shouldPauseForToggle(isPlaying: Bool, isLoading: Bool) -> Bool {
        isPlaying || (isLoading && canStartPlayback)
    }

    mutating func requestPlay() {
        wantsPlayback = true
        if isInterrupted { resumeAfterInterruption = true }
    }

    mutating func requestPause() {
        wantsPlayback = false
        resumeAfterInterruption = false
    }

    // Only an explicit Play action may ask the OS to recover a missing end
    // notification. Automatic callbacks never use this bypass.
    mutating func explicitActivationSucceeded() {
        wantsPlayback = true
        isInterrupted = false
        resumeAfterInterruption = false
    }

    mutating func explicitActivationFailed() {
        // Do not let a delayed file-open or end notification start playback
        // after the OS refused this request. Another explicit Play can retry.
        requestPause()
    }

    mutating func interruptionBegan() {
        if !isInterrupted { resumeAfterInterruption = wantsPlayback }
        isInterrupted = true
    }

    @discardableResult
    mutating func interruptionEnded(shouldResume: Bool) -> Bool {
        guard isInterrupted else { return false }
        let resume = shouldResume && resumeAfterInterruption && wantsPlayback
        isInterrupted = false
        resumeAfterInterruption = false
        wantsPlayback = resume
        return resume
    }

    mutating func mediaServicesReset() {
        // A reset invalidates the player, not an already active phone call.
        requestPause()
    }
}

// Both file preparation and checkpoint jobs use a revision to discard obsolete
// work. No AVAudioPlayer is ever shared concurrently between worker and main.
final class PlaybackWorkRevision: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    @discardableResult
    func advance() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        value &+= 1
        return value
    }

    func isCurrent(_ revision: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return revision == value
    }
}

// Queue encoding, validation and atomic file operations stay on one worker.
// Newer pending positions supersede older ones; an in-flight write always
// finishes before the newer save/clear, so Stop cannot resurrect an old queue.
final class PlaybackCheckpointStore: @unchecked Sendable {
    private let url: URL
    private let worker: DispatchQueue
    private let revision = PlaybackWorkRevision()

    init(url: URL) {
        self.url = url
        worker = DispatchQueue(label: "MusicCloud.playback-checkpoint", qos: .utility)
    }

    func load(completion: @escaping @Sendable (PlaybackCheckpoint?) -> Void) {
        worker.async { [self] in completion(Self.read(from: url)) }
    }

    func save(_ checkpoint: PlaybackCheckpoint,
              completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        submit(checkpoint, completion: completion)
    }

    func clear(completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        submit(nil, completion: completion)
    }

    private func submit(_ checkpoint: PlaybackCheckpoint?,
                        completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        let ticket = revision.advance()
        worker.async { [self] in
            do {
                guard revision.isCurrent(ticket) else { completion(.success(())); return }
                if let checkpoint {
                    _ = try checkpoint.validatedQueueState()
                    let data = try JSONEncoder().encode(checkpoint)
                    guard data.count <= PlaybackCheckpoint.maximumBytes else {
                        throw PlaybackQueueError.invalidCheckpoint
                    }
                    // A seek/new track may have arrived during encoding.
                    guard revision.isCurrent(ticket) else { completion(.success(())); return }
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                        withIntermediateDirectories: true)
                    try checkExistingFile()
                    try data.write(to: url, options: .atomic)
                } else {
                    try checkExistingFile()
                    if FileManager.default.fileExists(atPath: url.path) {
                        try FileManager.default.removeItem(at: url)
                    }
                }
                completion(.success(()))
            } catch { completion(.failure(error)) }
        }
    }

    private func checkExistingFile() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw PlaybackQueueError.invalidCheckpoint
        }
    }

    private static func read(from url: URL) -> PlaybackCheckpoint? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
            values.isRegularFile == true, values.isSymbolicLink != true,
            let size = values.fileSize, size >= 0, size <= PlaybackCheckpoint.maximumBytes,
            let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: PlaybackCheckpoint.maximumBytes + 1),
            data.count <= PlaybackCheckpoint.maximumBytes,
            let checkpoint = try? JSONDecoder().decode(PlaybackCheckpoint.self, from: data),
            (try? checkpoint.validatedQueueState()) != nil else { return nil }
        return checkpoint
    }
}
