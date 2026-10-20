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
    @Published var repeatMode: RepeatMode = .off
    @Published var errorMessage: String?

    private var player: AVAudioPlayer?
    private var originalOrder: [Track] = []
    private var timer: Timer?
    private let documentsURL: URL
    private var resumeAfterInterruption = false
    private var remoteTargets: [(MPRemoteCommand, Any)] = []
    private var notificationObservers: [NSObjectProtocol] = []

    var currentTrack: Track? {
        guard let currentIndex, queue.indices.contains(currentIndex) else { return nil }
        return queue[currentIndex]
    }

    init(documentsURL: URL) {
        self.documentsURL = documentsURL
        super.init()
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
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }

    func play(_ track: Track, from tracks: [Track]) {
        guard !tracks.isEmpty else { return }
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
        if player == nil { loadCurrentTrack(autoplay: true); return }
        do {
            try activateSession()
            if elapsed >= duration, duration > 0 { player?.currentTime = 0 }
            guard player?.play() == true else { throw PlaybackError.couldNotPlay }
            isPlaying = true
            refreshNowPlaying()
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
    }

    func stop() {
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
    }

    func seek(to seconds: TimeInterval) {
        guard let player, seconds.isFinite else { return }
        let newTime = min(max(0, seconds), player.duration)
        player.currentTime = newTime
        elapsed = newTime
        refreshNowPlaying()
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
    }

    func removeFromQueue(id: String) {
        guard currentTrack?.id != id else { return }
        let currentID = currentTrack?.id
        queue.removeAll { $0.id == id }
        originalOrder.removeAll { $0.id == id }
        currentIndex = queue.firstIndex { $0.id == currentID }
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
    }

    func prepareForDeletion(_ track: Track) {
        if currentTrack?.id == track.id { stop() }
        else { removeFromQueue(id: track.id) }
    }

    private func loadCurrentTrack(autoplay: Bool) {
        player?.stop()
        player = nil
        elapsed = 0
        duration = 0
        isPlaying = false
        guard let track = currentTrack else { return }
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
            if autoplay {
                guard nextPlayer.play() else { throw PlaybackError.couldNotPlay }
                isPlaying = true
            }
            refreshNowPlaying()
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
    }

    private func report(_ error: Error) {
        player?.stop()
        player = nil
        isPlaying = false
        errorMessage = "Could not play \(currentTrack?.filename ?? "this file"). The file may be incomplete, protected, or use an unsupported codec.\n\n\(error.localizedDescription)"
        refreshNowPlaying()
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
            resumeAfterInterruption = isPlaying
            pausePlayer()
        case .ended:
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
        let position = elapsed
        player = nil
        loadCurrentTrack(autoplay: false)
        seek(to: position)
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
    case couldNotPlay, invalidPath, decodeFailed
    var errorDescription: String? {
        switch self {
        case .couldNotPlay: return "iOS could not prepare or start this audio file."
        case .invalidPath: return "This file is outside the app’s music folder."
        case .decodeFailed: return "iOS could not decode the audio file."
        }
    }
}
