import AVFoundation
import Combine
import ImageIO
import MediaPlayer
import OSLog
import UIKit

private let playbackLog = Logger(subsystem: "MusicCloud", category: "Playback")

// Only scrubber/time views observe this object. A clock tick must not rebuild
// the library, playlist rows, artwork and queue controls several times a second.
@MainActor
final class PlaybackProgress: ObservableObject {
    @Published fileprivate(set) var elapsed: TimeInterval = 0
    @Published fileprivate(set) var duration: TimeInterval = 0
}

@MainActor
final class PlaybackController: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var queue: [Track] = []
    @Published private(set) var currentIndex: Int?
    @Published private(set) var isPlaying = false
    let progress = PlaybackProgress()
    private(set) var elapsed: TimeInterval {
        get { progress.elapsed }
        set { if progress.elapsed != newValue { progress.elapsed = newValue } }
    }
    private(set) var duration: TimeInterval {
        get { progress.duration }
        set { if progress.duration != newValue { progress.duration = newValue } }
    }
    @Published private(set) var isLoading = false
    @Published private(set) var isShuffled = false
    @Published private(set) var queueTitle = PlaybackQueueContext.libraryTitle
    @Published private(set) var sourcePlaylistID: UUID?
    @Published var repeatMode: RepeatMode = .off {
        didSet { if oldValue != repeatMode { saveCheckpoint() } }
    }
    @Published var errorMessage: String?

    private var player: AVAudioPlayer?
    private var originalOrder: [Track] = []
    private var queueState = PlaybackQueueState()
    private var timer: Timer?
    private let isEnabled: Bool
    private let documentsURL: URL
    private var intent = PlaybackIntentState()
    private var remoteTargets: [(MPRemoteCommand, Any)] = []
    private var notificationObservers: [NSObjectProtocol] = []
    private let checkpointStore: PlaybackCheckpointStore
    private var pendingCheckpoint: PlaybackCheckpoint?
    private var checkpointReadFinished = false
    private var checkpointRestoreAllowed = true
    private var tracksAwaitingCheckpoint: [Track]?
    private var restoringCheckpoint = false
    private var lastCheckpointUptime: TimeInterval = -.infinity
    private var checkpointRequest: UInt64 = 0
    private var checkpointQueueIDs: [String] = []
    private var checkpointOriginalIDs: [String] = []
    private var checkpointQueueTokens: [UUID] = []
    private var checkpointOriginalTokens: [UUID] = []
    private let preparationQueue = DispatchQueue(label: "MusicCloud.audio-file-open", qos: .userInitiated)
    private let preparationRevision = PlaybackWorkRevision()
    private var sessionConfigured = false
    private var sessionActive = false
    private var artworkCachePath: String?
    private var artworkCacheData: Data?
    private var nowPlayingArtwork: MPMediaItemArtwork?
    private let artworkQueue = DispatchQueue(label: "MusicCloud.now-playing-artwork", qos: .utility)
    private let artworkRevision = PlaybackWorkRevision()

    var currentTrack: Track? {
        guard let currentIndex, queue.indices.contains(currentIndex) else { return nil }
        return queue[currentIndex]
    }

    init(documentsURL: URL, isEnabled: Bool = true) {
        self.isEnabled = isEnabled
        self.documentsURL = documentsURL
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MusicCloud", isDirectory: true)
        checkpointStore = PlaybackCheckpointStore(url: support.appendingPathComponent("playback-state.json"))
        super.init()
        // A protected library must not register playback callbacks or touch checkpoints.
        guard isEnabled else { return }
        checkpointStore.load { [weak self] checkpoint in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.checkpointReadFinished = true
                guard self.checkpointRestoreAllowed else { return }
                self.pendingCheckpoint = checkpoint
                if let tracks = self.tracksAwaitingCheckpoint {
                    self.tracksAwaitingCheckpoint = nil
                    self.restoreIfNeeded(with: tracks)
                }
            }
        }
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
                Task { @MainActor [weak self] in
                    self?.logPlaybackState("did-enter-background")
                    self?.saveCheckpoint(keepAlive: true)
                }
            })
        let clock = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        clock.tolerance = 0.05
        RunLoop.main.add(clock, forMode: .common)
        timer = clock
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
        checkpointRestoreAllowed = false
        tracksAwaitingCheckpoint = nil
        errorMessage = nil
        let context = PlaybackQueueContext.starting(contextName: contextName, playlistID: playlistID)
        queueTitle = context.name
        sourcePlaylistID = context.playlistID
        queueState.start(trackIDs: tracks.map(\.id), at: index, shuffled: isShuffled)
        applyQueueState(refreshing: tracks)
        loadCurrentTrack(autoplay: true, explicitRequest: true)
    }

    func playAll(_ tracks: [Track], shuffled: Bool = false, contextName: String? = nil, playlistID: UUID? = nil) {
        guard isEnabled, !tracks.isEmpty else { return }
        isShuffled = shuffled
        play(at: shuffled ? Int.random(in: tracks.indices) : 0, from: tracks,
            contextName: contextName, playlistID: playlistID)
    }

    var showsPauseControl: Bool { intent.shouldPauseForToggle(isPlaying: isPlaying, isLoading: isLoading) }

    func togglePlayback() { showsPauseControl ? pause() : resume() }

    func resume() {
        guard isEnabled, currentTrack != nil else { return }
        if isPlaying, player?.isPlaying == true { return }
        intent.requestPlay()
        logPlaybackState("explicit-play-request")
        // A begin notification is not guaranteed a matching end. Explicit
        // user/remote Play asks the OS instead of trusting a stale local gate.
        do {
            try activateSession(explicitRequest: true)
            intent.explicitActivationSucceeded()
            errorMessage = nil
        } catch {
            reportSessionActivationFailure(error)
            return
        }
        startPlaybackIfAllowed()
    }

    private func startPlaybackIfAllowed() {
        guard intent.canStartPlayback, !isLoading else { return }
        if player == nil {
            let position = duration > 0 && elapsed >= duration ? 0 : elapsed
            loadCurrentTrack(autoplay: true, position: position)
            return
        }
        do { try activateSession() }
        catch { reportSessionActivationFailure(error); return }
        do {
            if elapsed >= duration, duration > 0 { player?.currentTime = 0; elapsed = 0 }
            guard player?.play() == true else { throw PlaybackError.couldNotPlay }
            isPlaying = true
            logPlaybackState("play-started")
            refreshNowPlaying()
            saveCheckpoint()
        } catch { report(error) }
    }

    func pause() {
        intent.requestPause()
        pausePlayer()
        logPlaybackState("user-paused")
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
        checkpointRestoreAllowed = false
        tracksAwaitingCheckpoint = nil
        intent.requestPause()
        preparationRevision.advance()
        isLoading = false
        player?.stop()
        player = nil
        isPlaying = false
        elapsed = 0
        duration = 0
        queue = []
        originalOrder = []
        currentIndex = nil
        queueState = PlaybackQueueState()
        cacheCheckpointOrder()
        queueTitle = PlaybackQueueContext.libraryTitle
        sourcePlaylistID = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        artworkCachePath = nil
        artworkCacheData = nil
        nowPlayingArtwork = nil
        artworkRevision.advance()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        sessionActive = false
        // An explicit stop clears the resume point; it never deletes music or playlists.
        checkpointRequest &+= 1
        let request = checkpointRequest
        let background = CheckpointBackgroundTask.startIfNeeded()
        checkpointStore.clear { [weak self] result in
            Task { @MainActor [weak self] in
                background?.end()
                guard let self, self.checkpointRequest == request else { return }
                if case .failure(let error) = result {
                    self.errorMessage = "Could not clear the saved playback position. \(error.localizedDescription)"
                }
            }
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
        loadCurrentTrack(autoplay: true, explicitRequest: true)
    }

    func next() { advance(automatically: false) }

    private func advance(automatically: Bool) {
        guard let currentIndex else { return }
        if automatically && repeatMode == .one {
            seek(to: 0)
            startPlaybackIfAllowed()
        } else if currentIndex + 1 < queue.count {
            selectIndex(currentIndex + 1)
            loadCurrentTrack(autoplay: true, explicitRequest: !automatically)
        } else if repeatMode == .all && !queue.isEmpty {
            selectIndex(0)
            loadCurrentTrack(autoplay: true, explicitRequest: !automatically)
        } else {
            intent.requestPause()
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
        loadCurrentTrack(autoplay: true, explicitRequest: true)
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
        if queue != nextQueue { queue = nextQueue }
        originalOrder = nextOriginal
        if currentIndex != queueState.currentIndex { currentIndex = queueState.currentIndex }
        cacheCheckpointOrder()
    }

    private func cacheCheckpointOrder() {
        checkpointQueueIDs = queueState.queue.map(\.trackID)
        checkpointOriginalIDs = queueState.original.map(\.trackID)
        checkpointQueueTokens = queueState.queue.map(\.token)
        checkpointOriginalTokens = queueState.original.map(\.token)
    }

    private func loadCurrentTrack(autoplay: Bool, position: TimeInterval = 0, explicitRequest: Bool = false) {
        guard isEnabled else { return }
        if autoplay { intent.requestPlay() } else { intent.requestPause() }
        let revision = preparationRevision.advance()
        player?.stop()
        player = nil
        isPlaying = false
        guard let track = currentTrack else { isLoading = false; return }
        isLoading = true
        duration = track.duration.isFinite ? max(0, track.duration) : 0
        elapsed = position.isFinite ? min(max(0, position), duration > 0 ? duration : .greatestFiniteMagnitude) : 0
        guard PlaybackCheckpoint.isRelativePath(track.id) else {
            isLoading = false
            report(PlaybackError.invalidPath)
            return
        }
        if explicitRequest, autoplay, intent.isInterrupted {
            // Resolve a stale gate during the user action, never later in the
            // asynchronous load callback. A new interruption arriving while
            // opening the file therefore still prevents automatic playback.
            do {
                try activateSession(explicitRequest: true)
                intent.explicitActivationSucceeded()
                errorMessage = nil
            } catch { reportSessionActivationFailure(error) }
        }
        let root = documentsURL
        let path = track.id
        let revisions = preparationRevision
        refreshNowPlaying()
        saveCheckpoint()
        preparationQueue.async { [weak self] in
            guard revisions.isCurrent(revision) else { return }
            let prepared: Result<PreparedAudioPlayer, Error>
            do {
                let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
                let url = root.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
                guard url.path.hasPrefix(resolvedRoot.path + "/") else { throw PlaybackError.invalidPath }
                let values = try url.resourceValues(forKeys: [.isRegularFileKey])
                guard values.isRegularFile == true else { throw PlaybackError.invalidPath }
                // File opening/header parsing can be slow for large local files.
                // Do not prepareToPlay here: Apple documents that it activates
                // the session, including while a call or user Pause is pending.
                let next = try AVAudioPlayer(contentsOf: url)
                prepared = .success(PreparedAudioPlayer(next))
            } catch { prepared = .failure(error) }
            guard revisions.isCurrent(revision) else { return }
            Task { @MainActor [weak self] in
                guard let self, revisions.isCurrent(revision) else { return }
                self.isLoading = false
                switch prepared {
                case .success(let prepared):
                    let next = prepared.player
                    next.delegate = self
                    self.player = next
                    self.duration = next.duration.isFinite ? max(0, next.duration) : 0
                    // Seek/Pause made while opening the file wins over the
                    // original request. The player transfers ownership once.
                    next.currentTime = min(max(0, self.elapsed), self.duration)
                    self.elapsed = next.currentTime
                    if self.intent.canStartPlayback { self.startPlaybackIfAllowed() }
                    else { self.refreshNowPlaying(); self.saveCheckpoint() }
                case .failure(let error): self.report(error)
                }
            }
        }
    }

    private func activateSession(explicitRequest: Bool = false) throws {
        guard explicitRequest || intent.canStartPlayback else { throw PlaybackError.interrupted }
        let session = AVAudioSession.sharedInstance()
        do {
            if !sessionConfigured {
                try session.setCategory(.playback, mode: .default, options: [])
                sessionConfigured = true
            }
            if explicitRequest || !sessionActive {
                try session.setActive(true)
                sessionActive = true
                playbackLog.info("session activation success explicit=\(explicitRequest, privacy: .public)")
            }
        } catch {
            sessionActive = false
            playbackLog.error("session activation failed explicit=\(explicitRequest, privacy: .public) code=\((error as NSError).code, privacy: .public)")
            throw error
        }
    }

    private func reportSessionActivationFailure(_ error: Error) {
        intent.explicitActivationFailed()
        player?.pause()
        isPlaying = false
        elapsed = player?.currentTime ?? elapsed
        errorMessage = "Audio is temporarily unavailable. End the call or other audio interruption, then tap Play again.\n\n\(error.localizedDescription)"
        logPlaybackState("activation-paused")
        refreshNowPlaying()
        saveCheckpoint()
    }

    private func logPlaybackState(_ event: String) {
        playbackLog.info("\(event, privacy: .public) app=\(UIApplication.shared.applicationState.rawValue, privacy: .public) playing=\(self.isPlaying, privacy: .public) actual=\(self.player?.isPlaying ?? false, privacy: .public) loading=\(self.isLoading, privacy: .public) wants=\(self.intent.wantsPlayback, privacy: .public) interrupted=\(self.intent.isInterrupted, privacy: .public) session=\(self.sessionActive, privacy: .public)")
    }

    private func tick() {
        guard let player else { return }
        if isPlaying { elapsed = player.currentTime }
        if isPlaying && ProcessInfo.processInfo.systemUptime - lastCheckpointUptime >= 5 { saveCheckpoint() }
    }

    private func report(_ error: Error) {
        intent.requestPause()
        preparationRevision.advance()
        isLoading = false
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
        if artworkCachePath != track.id || artworkCacheData != track.artwork {
            artworkCachePath = track.id
            artworkCacheData = track.artwork
            nowPlayingArtwork = nil
            let revision = artworkRevision.advance()
            let revisions = artworkRevision
            if let data = track.artwork {
                artworkQueue.async { [weak self] in
                    guard revisions.isCurrent(revision),
                        let source = CGImageSourceCreateWithData(data as CFData,
                            [kCGImageSourceShouldCache: false] as CFDictionary),
                        let bitmap = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceShouldCacheImmediately: true,
                            kCGImageSourceThumbnailMaxPixelSize: 600
                        ] as CFDictionary) else { return }
                    let prepared = PreparedNowPlayingArtwork(UIImage(cgImage: bitmap))
                    Task { @MainActor [weak self] in
                        guard let self, revisions.isCurrent(revision) else { return }
                        let image = prepared.image
                        self.nowPlayingArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                        self.refreshNowPlaying()
                    }
                }
            }
        }
        if let nowPlayingArtwork {
            info[MPMediaItemPropertyArtwork] = nowPlayingArtwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        register(center.playCommand) { controller, _ in
            guard controller.currentTrack != nil else { return .noSuchContent }
            controller.resume()
            return controller.isPlaying || controller.isLoading ? .success : .commandFailed
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
        let reason = notification.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt ?? UInt.max
        let options = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
        let suspended = notification.userInfo?[AVAudioSessionInterruptionWasSuspendedKey] as? Bool ?? false
        playbackLog.info("interruption type=\(raw, privacy: .public) reason=\(reason, privacy: .public) options=\(options, privacy: .public) suspended=\(suspended, privacy: .public)")
        logPlaybackState("interruption-before")
        switch type {
        case .began:
            intent.interruptionBegan()
            sessionActive = false
            pausePlayer()
        case .ended:
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            if intent.interruptionEnded(shouldResume:
                AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)) {
                startPlaybackIfAllowed()
            }
        @unknown default: break
        }
        logPlaybackState("interruption-after")
    }

    private func routeChanged(_ notification: Notification) {
        guard let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt else { return }
        playbackLog.info("route change reason=\(reason, privacy: .public)")
        if AVAudioSession.RouteChangeReason(rawValue: reason) == .oldDeviceUnavailable {
            // Do not unexpectedly continue through the phone speaker when a
            // wired headset or Bluetooth audio device disconnects.
            pause()
        }
        logPlaybackState("route-after")
    }

    private func mediaServicesReset() {
        // Apple may invalidate the player. Keep its last known position and
        // wait for a deliberate Play action before reactivating audio.
        let position = elapsed
        intent.mediaServicesReset()
        preparationRevision.advance()
        isLoading = false
        sessionActive = false
        sessionConfigured = false
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
        guard isEnabled, checkpointRestoreAllowed else { return }
        guard checkpointReadFinished else { tracksAwaitingCheckpoint = tracks; return }
        guard let saved = pendingCheckpoint else { return }
        guard let restoredOrder = try? saved.validatedQueueState(),
            let restoredContext = try? saved.validatedContext() else {
            errorMessage = "The saved queue could not be opened safely. Start a new queue to continue."
            return
        }
        let available = Set(tracks.map(\.id))
        guard saved.queueIDs.allSatisfy({ available.contains($0) }),
              saved.originalIDs.allSatisfy({ available.contains($0) }) else {
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
        checkpointRestoreAllowed = false
        restoringCheckpoint = false
        refreshNowPlaying()
    }

    private func saveCheckpoint(keepAlive: Bool = false) {
        guard isEnabled else { return }
        guard !restoringCheckpoint, pendingCheckpoint == nil,
              let currentIndex, queue.indices.contains(currentIndex) else { return }
        let position = player?.currentTime ?? elapsed
        guard position.isFinite else { return }
        let saved = PlaybackCheckpoint(version: 3, queueIDs: checkpointQueueIDs,
            originalIDs: checkpointOriginalIDs, currentIndex: currentIndex,
            position: max(0, position), shuffled: isShuffled, repeatMode: repeatMode.rawValue,
            queueTokens: checkpointQueueTokens, originalTokens: checkpointOriginalTokens,
            contextName: queueTitle, playlistID: sourcePlaylistID)
        // Snapshotting these copy-on-write arrays is constant time. Encoding,
        // validation and atomic replacement happen serially off the main actor.
        lastCheckpointUptime = ProcessInfo.processInfo.systemUptime
        checkpointRequest &+= 1
        let request = checkpointRequest
        let background = CheckpointBackgroundTask.startIfNeeded(force: keepAlive || !isPlaying)
        checkpointStore.save(saved) { [weak self] result in
            Task { @MainActor [weak self] in
                background?.end()
                guard let self, self.checkpointRequest == request else { return }
                if case .failure(let error) = result, self.errorMessage == nil {
                    self.errorMessage = "Could not save the playback position. Music can still play, but the queue may not resume after a restart. \(error.localizedDescription)"
                }
            }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player, self.isPlaying, self.intent.canStartPlayback else { return }
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

// The worker constructs the player without starting/preparing it, then hands
// it to main once. It never reads or mutates the player after that handoff.
private final class PreparedAudioPlayer: @unchecked Sendable {
    let player: AVAudioPlayer
    init(_ player: AVAudioPlayer) { self.player = player }
}

private final class PreparedNowPlayingArtwork: @unchecked Sendable {
    let image: UIImage
    init(_ image: UIImage) { self.image = image }
}

@MainActor
private final class CheckpointBackgroundTask {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    static func startIfNeeded(force: Bool = false) -> CheckpointBackgroundTask? {
        guard force || UIApplication.shared.applicationState != .active else { return nil }
        return CheckpointBackgroundTask()
    }

    private init() {
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Save playback position") { [weak self] in
            // UIKit guarantees this callback is on main. End before returning
            // to UIKit rather than enqueueing cleanup behind other actor work.
            MainActor.assumeIsolated {
                playbackLog.info("checkpoint background assertion expiry")
                self?.end()
            }
        }
        playbackLog.info("checkpoint background assertion start id=\(self.identifier.rawValue, privacy: .public)")
    }

    func end() {
        guard identifier != .invalid else { return }
        playbackLog.info("checkpoint background assertion end id=\(self.identifier.rawValue, privacy: .public)")
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

private enum PlaybackError: LocalizedError {
    case couldNotPlay, invalidPath, decodeFailed, interrupted
    var errorDescription: String? {
        switch self {
        case .couldNotPlay: return "iOS could not prepare or start this audio file."
        case .invalidPath: return "This file is outside the app’s music folder."
        case .decodeFailed: return "iOS could not decode the audio file."
        case .interrupted: return "Playback is paused for an audio interruption."
        }
    }
}


