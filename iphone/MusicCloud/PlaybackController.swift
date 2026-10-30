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
    @Published var repeatMode: RepeatMode = .off {
        didSet { saveCheckpoint() }
    }
    @Published var errorMessage: String?

    private var player: AVAudioPlayer?
    private var originalOrder: [Track] = []
    private var timer: Timer?
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

    init(documentsURL: URL) {
        self.documentsURL = documentsURL
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MusicCloud", isDirectory: true)
        checkpointURL = support.appendingPathComponent("playback-state.json")
        super.init()
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

    func play(_ track: Track, from tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        pendingCheckpoint = nil
        originalOrder = tracks
        if isShuffled {
            queue = [track] + tracks.filter { $0.id != track.id }.shuffled()
            currentIndex = 0
        } else {
            queue = tracks
            currentIndex = tracks.firstIndex(where: { $0.id == track.id }) ?? 0
        }
        loadCurrentTrack(autoplay: true)
    }

    func playAll(_ tracks: [Track], shuffled: Bool = false) {
        guard let first = shuffled ? tracks.randomElement() : tracks.first else { return }
        isShuffled = shuffled
        play(first, from: tracks)
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
        if currentIndex > 0 { self.currentIndex = currentIndex - 1 }
        else if repeatMode == .all, !queue.isEmpty { self.currentIndex = queue.count - 1 }
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
            self.currentIndex = currentIndex + 1
            loadCurrentTrack(autoplay: true)
        } else if repeatMode == .all && !queue.isEmpty {
            self.currentIndex = 0
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
        let currentID = currentTrack?.id
        isShuffled.toggle()
        guard let currentID else { return }
        if isShuffled {
            let selected = queue.filter { $0.id == currentID }
            queue = selected + queue.filter { $0.id != currentID }.shuffled()
            currentIndex = 0
        } else {
            queue = originalOrder
            currentIndex = queue.firstIndex { $0.id == currentID }
        }
        saveCheckpoint()
    }

    func jump(to index: Int) {
        guard queue.indices.contains(index) else { return }
        currentIndex = index
        loadCurrentTrack(autoplay: true)
    }

    func playNext(_ track: Track) {
        guard let currentIndex else { play(track, from: [track]); return }
        // Each track appears once in the queue. Moving a current track is a no-op.
        guard currentTrack?.id != track.id else { return }
        let currentID = currentTrack?.id
        queue.removeAll { $0.id == track.id }
        let newIndex = queue.firstIndex { $0.id == currentID } ?? currentIndex
        self.currentIndex = newIndex
        queue.insert(track, at: min(newIndex + 1, queue.count))
        originalOrder.removeAll { $0.id == track.id }
        if let originalCurrent = originalOrder.firstIndex(where: { $0.id == currentID }) {
            originalOrder.insert(track, at: min(originalCurrent + 1, originalOrder.count))
        } else { originalOrder.append(track) }
        saveCheckpoint()
    }

    func removeFromQueue(id: String) {
        guard currentTrack?.id != id else { return }
        let currentID = currentTrack?.id
        queue.removeAll { $0.id == id }
        originalOrder.removeAll { $0.id == id }
        currentIndex = queue.firstIndex { $0.id == currentID }
        saveCheckpoint()
    }

    // Keep the playing file until explicit deletion, but remove missing upcoming
    // files and refresh metadata after USB transfers or a rescan.
    func reconcile(with tracks: [Track]) {
        let available = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        let current = currentTrack
        queue = queue.compactMap { available[$0.id] ?? ($0.id == current?.id ? $0 : nil) }
        originalOrder = originalOrder.compactMap { available[$0.id] ?? ($0.id == current?.id ? $0 : nil) }
        currentIndex = queue.firstIndex { $0.id == current?.id }
        refreshNowPlaying()
        saveCheckpoint()
    }

    func prepareForDeletion(_ track: Track) {
        if currentTrack?.id == track.id { stop() }
        else { removeFromQueue(id: track.id) }
    }

    private func loadCurrentTrack(autoplay: Bool, position: TimeInterval = 0) {
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
        guard let saved = pendingCheckpoint else { return }
        let available = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        guard saved.queueIDs.allSatisfy({ available[$0] != nil }),
              saved.originalIDs.allSatisfy({ available[$0] != nil }) else {
            errorMessage = "The last queue could not be restored because some music files are missing. The saved queue was kept; copy the missing files back and rescan."
            return
        }
        restoringCheckpoint = true
        queue = saved.queueIDs.compactMap { available[$0] }
        originalOrder = saved.originalIDs.compactMap { available[$0] }
        currentIndex = saved.currentIndex
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
        guard !restoringCheckpoint, pendingCheckpoint == nil,
              let currentIndex, queue.indices.contains(currentIndex) else { return }
        let position = player?.currentTime ?? elapsed
        guard position.isFinite else { return }
        let saved = PlaybackCheckpoint(version: 1, queueIDs: queue.map(\.id),
            originalIDs: originalOrder.map(\.id), currentIndex: currentIndex,
            position: max(0, position), shuffled: isShuffled, repeatMode: repeatMode.rawValue)
        do {
            guard saved.queueIDs.count <= 50000, saved.originalIDs.count <= 50000 else {
                throw PlaybackError.queueTooLarge
            }
            let data = try JSONEncoder().encode(saved)
            guard data.count <= 4 * 1024 * 1024 else { throw PlaybackError.queueTooLarge }
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
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 4 * 1024 * 1024,
              let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode(PlaybackCheckpoint.self, from: data),
              saved.version == 1, !saved.queueIDs.isEmpty,
              saved.queueIDs.count <= 50000, saved.originalIDs.count <= 50000,
              saved.queueIDs.indices.contains(saved.currentIndex),
              saved.originalIDs.contains(saved.queueIDs[saved.currentIndex]),
              saved.position.isFinite, saved.position >= 0,
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

private struct PlaybackCheckpoint: Codable {
    let version: Int
    let queueIDs: [String]
    let originalIDs: [String]
    let currentIndex: Int
    let position: TimeInterval
    let shuffled: Bool
    let repeatMode: String
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

