import SwiftUI

@MainActor
struct MiniPlayer: View {
    @EnvironmentObject private var playback: PlaybackController
    let open: () -> Void

    var body: some View {
        if let track = playback.currentTrack {
            HStack(spacing: 12) {
                Button(action: open) {
                    HStack(spacing: 12) {
                        ArtworkView(data: track.artwork, size: 42)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(track.title).font(.subheadline.weight(.bold)).foregroundStyle(.white).lineLimit(1)
                            Text(track.artist).font(.caption).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Open now playing: \(track.title), \(track.artist)")
                Button { playback.togglePlayback() } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 21)).frame(width: 40, height: 44)
                }.accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
                Button { playback.next() } label: {
                    Image(systemName: "forward.end.fill").font(.system(size: 19)).frame(width: 34, height: 44)
                }.accessibilityLabel("Next song")
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(
                LinearGradient(colors: [Color(red: 0.20, green: 0.17, blue: 0.15), Theme.surface],
                    startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottomLeading) {
                GeometryReader { geometry in
                    Rectangle().fill(Theme.accent)
                        .frame(width: geometry.size.width * min(1, max(0, playback.elapsed / max(1, playback.duration))), height: 2)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }.clipShape(RoundedRectangle(cornerRadius: 18)).allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(0.25), radius: 12, y: 5)
        }
    }
}

@MainActor
struct NowPlayingView: View {
    @EnvironmentObject private var playback: PlaybackController
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var showQueue = false
    @State private var isScrubbing = false
    @State private var scrubPosition: Double = 0

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 24) {
                    HStack {
                        Button { dismiss() } label: {
                            Image(systemName: "chevron.down").font(.system(size: 16, weight: .semibold))
                                .frame(width: 44, height: 44)
                                .background(.white.opacity(0.07), in: Circle())
                        }.accessibilityLabel("Close now playing")
                        Spacer()
                        VStack(spacing: 4) {
                            Text("NOW PLAYING").font(.system(size: 10, weight: .bold)).tracking(2.4)
                            Text(playback.queueTitle).font(.caption).foregroundStyle(.white.opacity(0.62)).lineLimit(1)
                        }
                        Spacer()
                        Button { showQueue = true } label: {
                            Image(systemName: "text.line.first.and.arrowtriangle.forward")
                                .font(.system(size: 16, weight: .semibold)).frame(width: 44, height: 44)
                                .background(.white.opacity(0.07), in: Circle())
                        }.accessibilityLabel("Show queue")
                    }
                    if let track = playback.currentTrack {
                        ArtworkView(data: track.artwork, size: min(max(0, geometry.size.width - 64), 340))
                            .overlay {
                                RoundedRectangle(cornerRadius: max(6, min(max(0, geometry.size.width - 64), 340) * 0.09), style: .continuous)
                                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                            }
                            .shadow(color: .black.opacity(0.48), radius: 32, y: 20)
                            .padding(.vertical, 14)
                        HStack(alignment: .center, spacing: 18) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(track.title).font(.title2.weight(.bold))
                                Text(track.artist).font(.body.weight(.medium)).foregroundStyle(.white.opacity(0.72))
                                Text(track.album).font(.caption).foregroundStyle(.white.opacity(0.5))
                            }
                            Spacer(minLength: 0)
                            Button { library.toggleFavorite(track) } label: {
                                Image(systemName: library.state.favoriteIDs.contains(track.id) ? "heart.fill" : "heart")
                                    .font(.system(size: 21)).foregroundStyle(Theme.accent)
                                    .frame(width: 48, height: 48)
                                    .background(.white.opacity(0.07), in: Circle())
                            }.accessibilityLabel(library.state.favoriteIDs.contains(track.id) ? "Remove favorite" : "Favorite")
                        }
                        VStack(spacing: 6) {
                            Slider(value: Binding(get: { isScrubbing ? scrubPosition : min(playback.elapsed, max(1, playback.duration)) },
                                set: { scrubPosition = $0 }), in: 0...max(1, playback.duration)) { editing in
                                    if editing { scrubPosition = playback.elapsed; isScrubbing = true }
                                    else { playback.seek(to: scrubPosition); isScrubbing = false }
                                }
                                .disabled(playback.duration <= 0)
                                .accessibilityLabel("Playback position")
                            HStack {
                                Text((isScrubbing ? scrubPosition : playback.elapsed).musicTime)
                                Spacer()
                                Text("−" + max(0, playback.duration - (isScrubbing ? scrubPosition : playback.elapsed)).musicTime)
                            }.font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.55))
                        }
                        HStack(spacing: 0) {
                            Button { playback.toggleShuffle() } label: {
                                Image(systemName: "shuffle").font(.system(size: 21))
                                    .foregroundStyle(playback.isShuffled ? Theme.accent : Theme.subdued).frame(width: 48, height: 48)
                            }.accessibilityLabel(playback.isShuffled ? "Shuffle on" : "Shuffle off")
                            Spacer(minLength: 0)
                            Button { playback.previous() } label: {
                                Image(systemName: "backward.end.fill").font(.system(size: 29)).frame(width: 48, height: 56)
                            }.accessibilityLabel("Previous song")
                            Spacer(minLength: 0)
                            Button { playback.togglePlayback() } label: {
                                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 29, weight: .semibold))
                                    .foregroundStyle(Theme.background).frame(width: 72, height: 72)
                                    .background(LinearGradient(colors: [Color(red: 1, green: 0.82, blue: 0.48), Theme.accent],
                                        startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
                                    .shadow(color: Theme.accent.opacity(0.25), radius: 18, y: 7)
                            }.accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
                            Spacer(minLength: 0)
                            Button { playback.next() } label: {
                                Image(systemName: "forward.end.fill").font(.system(size: 29)).frame(width: 48, height: 56)
                            }.accessibilityLabel("Next song")
                            Spacer(minLength: 0)
                            Button { playback.repeatMode = playback.repeatMode.next } label: {
                                Image(systemName: playback.repeatMode.symbol).font(.system(size: 21))
                                    .foregroundStyle(playback.repeatMode == .off ? Theme.subdued : Theme.accent).frame(width: 48, height: 48)
                            }.accessibilityLabel(playback.repeatMode.label)
                        }.foregroundStyle(.white)
                        Label("Stored on this iPhone", systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.medium)).foregroundStyle(.white.opacity(0.58))
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            .background(.white.opacity(0.05), in: Capsule())
                            .padding(.top, 8)
                    } else {
                        Text("Choose a song from your library.").foregroundStyle(.secondary).padding(.vertical, 80)
                    }
                }.padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 36)
            }
        }
        .background {
            ZStack(alignment: .topTrailing) {
                Theme.background
                LinearGradient(colors: [Color(red: 0.30, green: 0.21, blue: 0.16), Theme.background],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
                Circle().fill(Theme.accent.opacity(0.11)).frame(width: 300, height: 300)
                    .blur(radius: 80).offset(x: 120, y: -130)
            }.ignoresSafeArea()
        }
        .preferredColorScheme(.dark).tint(Theme.accent)
        .sheet(isPresented: $showQueue) { QueueView() }
        .onChange(of: playback.currentTrack?.id) { _ in isScrubbing = false; scrubPosition = 0 }
    }
}

@MainActor
private struct QueueView: View {
    @EnvironmentObject private var playback: PlaybackController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if playback.queue.isEmpty { Text("Your queue is empty.").foregroundStyle(.secondary) }
                ForEach(Array(playback.queue.enumerated()), id: \.element.id) { index, track in
                    HStack(spacing: 12) {
                        Button { playback.jump(to: index) } label: {
                            HStack(spacing: 12) {
                                ArtworkView(data: track.artwork, size: 44)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(track.title).font(.subheadline.weight(.semibold))
                                        .foregroundStyle(index == playback.currentIndex ? Theme.accent : .white).lineLimit(1)
                                    Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                if index == playback.currentIndex { Image(systemName: "speaker.wave.2.fill").foregroundStyle(Theme.accent) }
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        if index != playback.currentIndex {
                            Button { playback.removeFromQueue(at: index) } label: {
                                Image(systemName: "minus.circle").foregroundStyle(.secondary).frame(width: 34, height: 44)
                            }.buttonStyle(.plain).accessibilityLabel("Remove \(track.title) from queue")
                        }
                    }.listRowBackground(Theme.surface)
                }
            }
            .scrollContentBackground(.hidden)
            .background(LinearGradient(colors: [Color(red: 0.20, green: 0.16, blue: 0.13), Theme.background],
                startPoint: .top, endPoint: .bottom))
            .navigationTitle("Play queue").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.preferredColorScheme(.dark).tint(Theme.accent)
    }
}


