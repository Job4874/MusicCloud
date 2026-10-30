import AVFoundation
import Combine
import MediaPlayer
import UIKit

@MainActor
final class PlaybackController: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var queue: [Track] = []
    @Published private(set) var currentIndex: Int?
    @Published private(set) var isPlaying = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var isShuffled = false
    @Published private(set) var queueTitle = PlaybackQueueContext.libraryTitle
    @Published private(set) var sourcePlaylistID: UUID?
    @Published var repeatMode: RepeatMode = .off {
        didSet { saveCheckpoint() }
    }
    @Published var errorMessage: String?

    private var player: AVAudioPlayer?
    private var originalOrder: [Track] = []
    private var queueState = PlaybackQueueState()
    private var timer: Timer?
    private let isEnabled: Bool
    private let documentsURL: URL
    private var resumeAfterInterruption = false
    private var remoteTargets: [(MPRemoteCommand, Any)] = []
    private var notificationObservers: [NSObjectProtocol] = []
    private let checkpointURL: URL
    private var pendingCheckpoint: PlaybackCheckpoint?
    private var restoringCheckpoint = false
    private var lastCheckpointTime = Date.distantPast
    private var interruptionActive = false

    var currentTrack: Track? {
        guard let currentIndex, queue.indices.contains(currentIndex) else { return nil }
        return queue[currentIndex]
    }

    init(documentsURL: URL, isEnabled: Bool = true) {
        self.isEnabled = isEnabled
        self.documentsURL = documentsURL
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MusicCloud", isDirectory: true)
        checkpointURL = support.appendingPathComponent("playback-state.json")
        super.init()
        // A protected library must not register playback callbacks or touch checkpoints.
        guard isEnabled else { return }
        pendingCheckpoint = Self.readCheckpoint(from: checkpointURL)
        configureRemoteCommands()
        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
                Task { @MainActor [weak self] in self?.interrupted(note) }
            })
        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
                Task { @MainActor [weak self] in self?.routeChanged(note) }
            })
        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.mediaServicesReset() }
            })
        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.saveCheckpoint() }
            })
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }

    func play(_ track: Track, from tracks: [Track], contextName: String? = nil, playlistID: UUID? = nil) {
        guard let index = tracks.firstIndex(where: { $0.id == track.id }) else {
            play(at: 0, from: [track], contextName: contextName, playlistID: playlistID)
            return
        }
        play(at: index, from: tracks, contextName: contextName, playlistID: playlistID)
    }

    func play(at index: Int, from tracks: [Track], contextName: String? = nil, playlistID: UUID? = nil) {
        guard isEnabled, tracks.indices.contains(index) else { return }
        pendingCheckpoint = nil
        let context = PlaybackQueueContext.starting(contextName: contextName, playlistID: playlistID)
        queueTitle = context.name
        sourcePlaylistID = context.playlistID
        queueState.start(trackIDs: tracks.map(\.id), at: index, shuffled: isShuffled)
        applyQueueState(refreshing: tracks)
        loadCurrentTrack(autoplay: true)
    }

    func playAll(_ tracks: [Track], shuffled: Bool = false, contextName: String? = nil, playlistID: UUID? = nil) {
        guard isEnabled, !tracks.isEmpty else { return }
        isShuffled = shuffled
        play(at: shuffled ? Int.random(in: tracks.indices) : 0, from: tracks,
            contextName: contextName, playlistID: playlistID)
    }

    func togglePlayback() { isPlaying ? pause() : resume() }

    func resume() {
        guard currentTrack != nil else { return }
        if player == nil {
            let position = duration > 0 && elapsed >= duration ? 0 : elapsed
            loadCurrentTrack(autoplay: true, position: position)
            return
        }
        do {
            try activateSession()
            if elapsed >= duration, duration > 0 { player?.currentTime = 0 }
            guard player?.play() == true else { throw PlaybackError.couldNotPlay }
            isPlaying = true
            refreshNowPlaying()
            saveCheckpoint()
        } catch { report(error) }
    }

    func pause() {
        resumeAfterInterruption = false
        pausePlayer()
    }

    private func pausePlayer() {
        player?.pause()
        isPlaying = false
        elapsed = player?.currentTime ?? elapsed
        refreshNowPlaying()
        saveCheckpoint()
    }

    func stop() {
        guard isEnabled else { return }
        pendingCheckpoint = nil
        resumeAfterInterruption = false
        player?.stop()
        player = nil
        isPlaying = false
        elapsed = 0
        duration = 0
        queue = []
        originalOrder = []
        currentIndex = nil
        queueState = PlaybackQueueState()
        queueTitle = PlaybackQueueContext.libraryTitle
        sourcePlaylistID = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        // An explicit stop clears the resume point; it never deletes music or playlists.
        do {
            if FileManager.default.fileExists(atPath: checkpointURL.path) {
                try FileManager.default.removeItem(at: checkpointURL)
            }
        } catch {
            errorMessage = "Could not clear the saved playback position. \(error.localizedDescription)"
        }
    }

    func seek(to seconds: TimeInterval) {
        guard currentTrack != nil, seconds.isFinite else { return }
        let newTime = min(max(0, seconds), player?.duration ?? duration)
        player?.currentTime = newTime
        elapsed = newTime
        refreshNowPlaying()
        saveCheckpoint()
    }

    func previous() {
        guard let currentIndex else { return }
        if elapsed > 3 { seek(to: 0); return }
        if currentIndex > 0 { selectIndex(currentIndex - 1) }
        else if repeatMode == .all, !queue.isEmpty { selectIndex(queue.count - 1) }
        else { seek(to: 0); return }
        loadCurrentTrack(autoplay: true)
    }

    func next() { advance(automatically: false) }

    private func advance(automatically: Bool) {
        guard let currentIndex else { return }
        if automatically && repeatMode == .one {
            seek(to: 0)
            resume()
        } else if currentIndex + 1 < queue.count {
            selectIndex(currentIndex + 1)
            loadCurrentTrack(autoplay: true)
        } else if repeatMode == .all && !queue.isEmpty {
            selectIndex(0)
            loadCurrentTrack(autoplay: true)
        } else {
            player?.pause()
            isPlaying = false
            if automatically { elapsed = duration }
            refreshNowPlaying()
            saveCheckpoint()
        }
    }

    func toggleShuffle() {
        guard isEnabled else { return }
        isShuffled.toggle()
        queueState.setShuffled(isShuffled)
        applyQueueState()
        saveCheckpoint()
    }

    func jump(to index: Int) {
        guard isEnabled, queue.indices.contains(index) else { return }
        selectIndex(index)
        loadCurrentTrack(autoplay: true)
    }

    func playNext(_ track: Track) {
        guard isEnabled else { return }
        guard currentIndex != nil else { play(track, from: [track]); return }
        queueState.insertNext(trackID: track.id)
        applyQueueState(refreshing: [track])
        saveCheckpoint()
    }

    func removeFromQueue(at index: Int) {
        guard isEnabled, queueState.remove(at: index) else { return }
        applyQueueState()
        saveCheckpoint()
    }

    func removeFromQueue(id: String) {
        guard isEnabled else { return }
        guard currentTrack?.id != id else { return }
        queueState.removeNonplayingPath(id)
        applyQueueState()
        saveCheckpoint()
    }

    // Keep the playing file until explicit deletion, but remove missing upcoming
    // files and refresh metadata after USB transfers or a rescan.
    func reconcile(with tracks: [Track]) {
        guard isEnabled else { return }
        queueState.reconcile(availablePaths: Set(tracks.map(\.id)))
        applyQueueState(refreshing: tracks)
        refreshNowPlaying()
        saveCheckpoint()
    }

    func prepareForDeletion(_ track: Track) {
        if currentTrack?.id == track.id { stop() }
        else { removeFromQueue(id: track.id) }
    }

    private func selectIndex(_ index: Int) {
        queueState.currentIndex = index
        currentIndex = index
    }

    private func applyQueueState(refreshing tracks: [Track] = []) {
        var byPath: [String: Track] = [:]
        for track in queue + originalOrder + tracks { byPath[track.id] = track }
        let nextQueue = queueState.queue.compactMap { byPath[$0.trackID] }
        let nextOriginal = queueState.original.compactMap { byPath[$0.trackID] }
        guard nextQueue.count == queueState.queue.count, nextOriginal.count == queueState.original.count else {
            errorMessage = "The queue could not be updated because a music file was not found."
            return
        }
        queue = nextQueue
        originalOrder = nextOriginal
        currentIndex = queueState.currentIndex
    }

    private func loadCurrentTrack(autoplay: Bool, position: TimeInterval = 0) {
        guard isEnabled else { return }
        player?.stop()
        player = nil
        isPlaying = false
        guard let track = currentTrack else { return }
        duration = track.duration.isFinite ? max(0, track.duration) : 0
        elapsed = position.isFinite ? max(0, position) : 0
        let url = documentsURL.appendingPathComponent(track.id).standardizedFileURL
        guard url.path.hasPrefix(documentsURL.standardizedFileURL.path + "/") else {
            report(PlaybackError.invalidPath)
            return
        }
        do {
            try activateSession()
            let nextPlayer = try AVAudioPlayer(contentsOf: url)
            nextPlayer.delegate = self
            guard nextPlayer.prepareToPlay() else { throw PlaybackError.couldNotPlay }
            player = nextPlayer
            duration = nextPlayer.duration
            let restoredPosition = position.isFinite ? min(max(0, position), duration) : 0
            nextPlayer.currentTime = restoredPosition
            elapsed = restoredPosition
            if autoplay {
                guard nextPlayer.play() else { throw PlaybackError.couldNotPlay }
                isPlaying = true
            }
            refreshNowPlaying()
            saveCheckpoint()
        } catch { report(error) }
    }

    private func activateSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [])
        try session.setActive(true)
    }

    private func tick() {
        guard let player else { return }
        if isPlaying { elapsed = player.currentTime }
        if isPlaying && Date().timeIntervalSince(lastCheckpointTime) >= 5 { saveCheckpoint() }
    }

    private func report(_ error: Error) {
        player?.stop()
        player = nil
        isPlaying = false
        errorMessage = "Could not play \(currentTrack?.filename ?? "this file"). The file may be incomplete, protected, or use an unsupported codec.\n\n\(error.localizedDescription)"
        refreshNowPlaying()
        saveCheckpoint()
    }

    private func refreshNowPlaying() {
        guard let track = currentTrack else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0
        ]
        if let data = track.artwork, let image = UIImage(data: data) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        register(center.playCommand) { controller, _ in
            guard controller.currentTrack != nil else { return .noSuchContent }
            controller.resume()
            return controller.isPlaying ? .success : .commandFailed
        }
        register(center.pauseCommand) { controller, _ in controller.pause(); return .success }
        register(center.togglePlayPauseCommand) { controller, _ in
            guard controller.currentTrack != nil else { return .noSuchContent }
            controller.togglePlayback(); return .success
        }
        register(center.nextTrackCommand) { controller, _ in controller.next(); return .success }
        register(center.previousTrackCommand) { controller, _ in controller.previous(); return .success }
        register(center.changePlaybackPositionCommand) { controller, event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            controller.seek(to: event.positionTime)
            return .success
        }
    }

    private func register(_ command: MPRemoteCommand,
        action: @escaping @MainActor (PlaybackController, MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) {
        command.isEnabled = true
        let target = command.addTarget { [weak self] event in
            // MediaPlayer delivers remote command callbacks on an unspecified
            // queue. All published state and AVAudioPlayer access stay on main.
            if Thread.isMainThread {
                return MainActor.assumeIsolated {
                    guard let self else { return .commandFailed }
                    return action(self, event)
                }
            }
            return DispatchQueue.main.sync {
                guard let self else { return .commandFailed }
                return action(self, event)
            }
        }
        remoteTargets.append((command, target))
    }

    private func interrupted(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            if !interruptionActive { resumeAfterInterruption = isPlaying }
            interruptionActive = true
            pausePlayer()
        case .ended:
            interruptionActive = false
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = resumeAfterInterruption
            resumeAfterInterruption = false
            if shouldResume && AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume) {
                resume()
            }
        @unknown default: break
        }
    }

    private func routeChanged(_ notification: Notification) {
        guard let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt else { return }
        if AVAudioSession.RouteChangeReason(rawValue: reason) == .oldDeviceUnavailable {
            // Do not unexpectedly continue through the phone speaker when a
            // wired headset or Bluetooth audio device disconnects.
            resumeAfterInterruption = false
            pause()
        }
    }

    private func mediaServicesReset() {
        // Apple may invalidate the player. Keep its last known position and
        // wait for a deliberate Play action before reactivating audio.
        let position = elapsed
        resumeAfterInterruption = false
        player = nil
        isPlaying = false
        elapsed = position
        refreshNowPlaying()
        saveCheckpoint()
    }

    // A checkpoint contains only IDs and playback settings, never audio or
    // artwork. Wait for a successful library scan and restore paused: launching
    // the app must not unexpectedly begin playing through the speaker.
    func restoreIfNeeded(with tracks: [Track]) {
        guard isEnabled, let saved = pendingCheckpoint else { return }
        guard let restoredOrder = try? saved.validatedQueueState(),
            let restoredContext = try? saved.validatedContext() else {
            errorMessage = "The saved queue could not be opened safely. Start a new queue to continue."
            return
        }
        let available = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        guard saved.queueIDs.allSatisfy({ available[$0] != nil }),
              saved.originalIDs.allSatisfy({ available[$0] != nil }) else {
            errorMessage = "The last queue could not be restored because some music files are missing. The saved queue was kept; copy the missing files back and rescan."
            return
        }
        restoringCheckpoint = true
        queueState = restoredOrder
        applyQueueState(refreshing: tracks)
        queueTitle = restoredContext.name
        sourcePlaylistID = restoredContext.playlistID
        isShuffled = saved.shuffled
        repeatMode = RepeatMode(rawValue: saved.repeatMode) ?? .off
        duration = currentTrack?.duration ?? 0
        elapsed = duration.isFinite && duration > 0 ? min(saved.position, duration) : saved.position
        isPlaying = false
        pendingCheckpoint = nil
        restoringCheckpoint = false
        refreshNowPlaying()
    }

    private func saveCheckpoint() {
        guard isEnabled else { return }
        guard !restoringCheckpoint, pendingCheckpoint == nil,
              let currentIndex, queue.indices.contains(currentIndex) else { return }
        let position = player?.currentTime ?? elapsed
        guard position.isFinite else { return }
        let saved = PlaybackCheckpoint(version: 3, queueIDs: queue.map(\.id),
            originalIDs: originalOrder.map(\.id), currentIndex: currentIndex,
            position: max(0, position), shuffled: isShuffled, repeatMode: repeatMode.rawValue,
            queueTokens: queueState.queue.map(\.token), originalTokens: queueState.original.map(\.token),
            contextName: queueTitle, playlistID: sourcePlaylistID)
        do {
            guard saved.queueIDs.count <= PlaybackCheckpoint.maximumOccurrences,
                saved.originalIDs.count <= PlaybackCheckpoint.maximumOccurrences else {
                throw PlaybackError.queueTooLarge
            }
            _ = try saved.validatedQueueState()
            let data = try JSONEncoder().encode(saved)
            guard data.count <= PlaybackCheckpoint.maximumBytes else { throw PlaybackError.queueTooLarge }
            try FileManager.default.createDirectory(at: checkpointURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try data.write(to: checkpointURL, options: .atomic)
            lastCheckpointTime = Date()
        } catch {
            // Limit retries while still keeping playback functional.
            lastCheckpointTime = Date()
            if errorMessage == nil {
                errorMessage = "Could not save the playback position. Music can still play, but the queue may not resume after a restart. \(error.localizedDescription)"
            }
        }
    }

    private static func readCheckpoint(from url: URL) -> PlaybackCheckpoint? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= PlaybackCheckpoint.maximumBytes,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: PlaybackCheckpoint.maximumBytes + 1),
              data.count <= PlaybackCheckpoint.maximumBytes,
              let saved = try? JSONDecoder().decode(PlaybackCheckpoint.self, from: data),
              (try? saved.validatedQueueState()) != nil,
              RepeatMode(rawValue: saved.repeatMode) != nil else { return nil }
        return saved
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player else { return }
            if flag { self.advance(automatically: true) }
            else { self.report(PlaybackError.decodeFailed) }
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player else { return }
            self.report(error ?? PlaybackError.decodeFailed)
        }
    }
}

private enum PlaybackError: LocalizedError {
    case couldNotPlay, invalidPath, decodeFailed, queueTooLarge
    var errorDescription: String? {
        switch self {
        case .couldNotPlay: return "iOS could not prepare or start this audio file."
        case .invalidPath: return "This file is outside the app’s music folder."
        case .decodeFailed: return "iOS could not decode the audio file."
        case .queueTooLarge: return "The playback queue is too large to save."
        }
    }
}


