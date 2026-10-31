import SwiftUI
import AVKit

@MainActor
struct MiniPlayer: View {
    @EnvironmentObject private var playback: PlaybackController
    let open: () -> Void
    var body: some View {
        if let track = playback.currentTrack {
            HStack(spacing: 8) {
                Button(action: open) {
                    HStack(spacing: 12) {
                        ArtworkView(data: track.artwork, size: 44)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(track.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                            Text(track.artist).font(.system(size: 11)).foregroundStyle(Theme.subdued).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Now playing: \(track.title), \(track.artist)")
                Button { playback.togglePlayback() } label: {
                    ZStack {
                        Image(systemName: playback.showsPauseControl ? "pause.fill" : "play.fill").font(.system(size: 20, weight: .semibold))
                        if playback.isLoading { ProgressView().scaleEffect(0.65).offset(x: 12, y: -13) }
                    }.foregroundStyle(.white).frame(width: 42, height: 48)
                }.buttonStyle(.plain).accessibilityLabel(playback.showsPauseControl ? "Pause" : "Play")
                Button { playback.next() } label: {
                    Image(systemName: "forward.end.fill").font(.system(size: 17)).foregroundStyle(.white).frame(width: 36, height: 48)
                }.buttonStyle(.plain).accessibilityLabel("Next song")
            }.padding(.leading, 9).padding(.trailing, 8).padding(.vertical, 8)
                .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 17))
                .overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(.white.opacity(0.07)))
                .overlay(alignment: .bottom) { MiniPlaybackProgress(progress: playback.progress).frame(height: 2).padding(.horizontal, 14).allowsHitTesting(false) }
                .shadow(color: .black.opacity(0.24), radius: 12, y: 4)
        }
    }
}

@MainActor
private struct MiniPlaybackProgress: View {
    @ObservedObject var progress: PlaybackProgress
    var body: some View {
        GeometryReader { geometry in
            Capsule().fill(Theme.accent.opacity(0.8))
                .frame(width: max(0, geometry.size.width * min(1, max(0, progress.elapsed / max(1, progress.duration)))), height: 2)
        }
    }
}

@MainActor
struct NowPlayingView: View {
    @EnvironmentObject private var playback: PlaybackController
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var showQueue = false
    var body: some View {
        GeometryReader { geometry in
            let coverSize = max(120, min(geometry.size.width - 64, geometry.size.height * 0.38, 340))
            ScrollView {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Button { dismiss() } label: { Image(systemName: "chevron.down").font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 44) }
                            .buttonStyle(.plain).accessibilityLabel("Close now playing")
                        Spacer(minLength: 0)
                        VStack(spacing: 5) {
                            Text("PLAYING FROM").font(.system(size: 9, weight: .bold)).tracking(2).foregroundStyle(Theme.subdued)
                            Text(playback.queueTitle).font(.system(size: 12, weight: .medium)).foregroundStyle(.white).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Button { showQueue = true } label: { Image(systemName: "text.line.first.and.arrowtriangle.forward").font(.system(size: 18)).frame(width: 44, height: 44) }
                            .buttonStyle(.plain).accessibilityLabel("Open queue")
                    }.foregroundStyle(.white).padding(.bottom, 18)
                    if let track = playback.currentTrack {
                        ArtworkView(data: track.artwork, size: coverSize)
                            .overlay(RoundedRectangle(cornerRadius: max(7, coverSize * 0.085)).strokeBorder(.white.opacity(0.12)))
                            .shadow(color: .black.opacity(0.4), radius: 24, y: 18)
                            .padding(.bottom, 26)
                        HStack(alignment: .center, spacing: 4) {
                            VStack(alignment: .leading, spacing: 7) {
                                Text(track.title).font(.system(size: 26, weight: .bold)).tracking(-0.4).foregroundStyle(.white).lineLimit(2)
                                Text(track.artist).font(.system(size: 16)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Button { library.toggleLike(track) } label: {
                                Image(systemName: library.isLiked(track) ? "heart.fill" : "heart").font(.system(size: 23))
                                    .foregroundStyle(library.isLiked(track) ? Theme.accent : .white.opacity(0.7)).frame(width: 46, height: 50)
                            }.buttonStyle(.plain).accessibilityLabel(library.isLiked(track) ? "Remove from Liked Songs" : "Add to Liked Songs")
                            SongActionsMenu(track: track)
                        }.padding(.bottom, 14)
                        PlaybackScrubber(progress: playback.progress, seek: { playback.seek(to: $0) })
                            .id("\(track.id)-\(playback.currentIndex ?? 0)")
                            .padding(.bottom, 12)
                        PlayerTransportControls().padding(.bottom, 22)
                        HStack(spacing: 14) {
                            RoutePicker().frame(width: 42, height: 42).accessibilityLabel("Choose audio output")
                            Spacer()
                            MusicStatusPill(text: "On this iPhone")
                            Spacer()
                            Button { showQueue = true } label: {
                                Image(systemName: "list.bullet").font(.system(size: 18)).frame(width: 42, height: 42)
                                    .foregroundStyle(Theme.subdued)
                            }.buttonStyle(.plain).accessibilityLabel("Show play queue")
                        }
                    } else {
                        MusicEmptyState(symbol: "music.note", title: "Pick your next song", detail: "Choose music from Library or a playlist.")
                    }
                }.padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 24).frame(maxWidth: .infinity)
            }.scrollIndicators(.hidden)
                .background {
                    ZStack {
                        Theme.background
                        if let track = playback.currentTrack, track.artwork != nil {
                            ArtworkView(data: track.artwork, size: max(geometry.size.width, 350))
                                .scaleEffect(1.3).blur(radius: 65).opacity(0.22).offset(y: -140)
                        }
                        LinearGradient(colors: [.clear, Theme.background], startPoint: .top, endPoint: .bottom)
                    }.ignoresSafeArea()
                }
        }.preferredColorScheme(.dark).tint(Theme.accent)
            .sheet(isPresented: $showQueue) { QueueView() }
    }
}

@MainActor
private struct PlaybackScrubber: View {
    @ObservedObject var progress: PlaybackProgress
    let seek: (TimeInterval) -> Void
    @State private var isScrubbing = false
    @State private var position: TimeInterval = 0
    private var shown: TimeInterval { isScrubbing ? position : progress.elapsed }
    var body: some View {
        VStack(spacing: 0) {
            Slider(value: Binding(get: { isScrubbing ? position : min(progress.elapsed, max(1, progress.duration)) }, set: { position = $0 }),
                in: 0...max(1, progress.duration)) { editing in
                    if editing { position = progress.elapsed; isScrubbing = true }
                    else { seek(position); isScrubbing = false }
                }.disabled(progress.duration <= 0).tint(Theme.accent).accessibilityLabel("Playback position")
            HStack {
                Text(shown.musicTime)
                Spacer()
                Text("−" + max(0, progress.duration - shown).musicTime)
            }.font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.45))
        }
    }
}

@MainActor
private struct PlayerTransportControls: View {
    @EnvironmentObject private var playback: PlaybackController
    var body: some View {
        HStack(spacing: 0) {
            Button { playback.toggleShuffle() } label: {
                Image(systemName: "shuffle").font(.system(size: 19)).foregroundStyle(playback.isShuffled ? Theme.accent : Theme.subdued).frame(width: 44, height: 50)
            }.buttonStyle(.plain).accessibilityLabel(playback.isShuffled ? "Shuffle on" : "Shuffle off")
            Spacer(minLength: 0)
            Button { playback.previous() } label: { Image(systemName: "backward.end.fill").font(.system(size: 27)).foregroundStyle(.white).frame(width: 48, height: 60) }
                .buttonStyle(.plain).accessibilityLabel("Previous song")
            Spacer(minLength: 0)
            Button { playback.togglePlayback() } label: {
                ZStack {
                    Circle().fill(Theme.accent)
                    Image(systemName: playback.showsPauseControl ? "pause.fill" : "play.fill").font(.system(size: 29, weight: .semibold)).foregroundStyle(Theme.ink)
                    if playback.isLoading { ProgressView().tint(Theme.ink).scaleEffect(0.7).offset(x: 21, y: -21) }
                }.frame(width: 76, height: 76)
            }.buttonStyle(.plain).accessibilityLabel(playback.showsPauseControl ? "Pause" : "Play")
            Spacer(minLength: 0)
            Button { playback.next() } label: { Image(systemName: "forward.end.fill").font(.system(size: 27)).foregroundStyle(.white).frame(width: 48, height: 60) }
                .buttonStyle(.plain).accessibilityLabel("Next song")
            Spacer(minLength: 0)
            Button { playback.repeatMode = playback.repeatMode.next } label: {
                Image(systemName: playback.repeatMode.symbol).font(.system(size: 19)).foregroundStyle(playback.repeatMode == .off ? Theme.subdued : Theme.accent).frame(width: 44, height: 50)
            }.buttonStyle(.plain).accessibilityLabel(playback.repeatMode.label)
        }
    }
}

@MainActor
private struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = UIColor(Theme.subdued); view.activeTintColor = UIColor(Theme.accent)
        return view
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) { }
}

@MainActor
private struct QueueView: View {
    @EnvironmentObject private var playback: PlaybackController
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(playback.queueTitle).font(.title2.bold()).lineLimit(2)
                        Text("\(playback.queue.count) songs in this queue").font(.caption).foregroundStyle(Theme.subdued)
                    }.padding(.vertical, 8)
                }.listRowBackground(Color.clear).listRowSeparator(.hidden)
                Section {
                    if playback.queue.isEmpty { MusicEmptyState(symbol: "music.note.list", title: "Your queue is empty", detail: "Play a playlist or add a song to play next.") }
                    ForEach(Array(playback.queue.enumerated()), id: \.offset) { index, track in
                        HStack(spacing: 10) {
                            Button { playback.jump(to: index) } label: {
                                HStack(spacing: 12) {
                                    ArtworkView(data: track.artwork, size: 50)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(track.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(index == playback.currentIndex ? Theme.accent : .white).lineLimit(1)
                                        Text(track.artist).font(.caption).foregroundStyle(Theme.subdued).lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                    if index == playback.currentIndex { Image(systemName: "waveform").font(.caption).foregroundStyle(Theme.accent) }
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            if index != playback.currentIndex {
                                Button { playback.removeFromQueue(at: index) } label: { Image(systemName: "minus.circle").font(.system(size: 19)).foregroundStyle(Theme.subdued).frame(width: 38, height: 46) }
                                    .buttonStyle(.plain).accessibilityLabel("Remove \(track.title) from queue")
                            }
                        }.padding(.vertical, 6).musicSongListRow()
                    }
                }
            }.listStyle(.plain).scrollContentBackground(.hidden).background(Theme.background)
                .navigationTitle("Up Next").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.fontWeight(.semibold) } }
        }.preferredColorScheme(.dark).tint(Theme.accent)
    }
}
