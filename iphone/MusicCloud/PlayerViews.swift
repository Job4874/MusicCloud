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
                            Text(track.title).font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                            Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Open now playing: \(track.title)")
                Button { playback.togglePlayback() } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 21)).frame(width: 40, height: 44)
                }.accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
                Button { playback.next() } label: {
                    Image(systemName: "forward.end.fill").font(.system(size: 19)).frame(width: 34, height: 44)
                }.accessibilityLabel("Next song")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(alignment: .bottomLeading) {
                GeometryReader { geometry in
                    Rectangle().fill(Theme.accent)
                        .frame(width: geometry.size.width * min(1, max(0, playback.elapsed / max(1, playback.duration))), height: 2)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }.clipShape(RoundedRectangle(cornerRadius: 14)).allowsHitTesting(false)
            }
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
                VStack(spacing: 22) {
                    HStack {
                        Button { dismiss() } label: {
                            Image(systemName: "chevron.down").frame(width: 44, height: 44)
                        }.accessibilityLabel("Close now playing")
                        Spacer()
                        VStack(spacing: 4) {
                            Text("NOW PLAYING").font(.system(size: 10, weight: .bold)).tracking(2)
                            Text("On this iPhone").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { showQueue = true } label: {
                            Image(systemName: "list.bullet").frame(width: 44, height: 44)
                        }.accessibilityLabel("Show queue")
                    }
                    if let track = playback.currentTrack {
                        ArtworkView(data: track.artwork, size: min(geometry.size.width - 56, 360))
                            .shadow(color: .black.opacity(0.4), radius: 30, y: 18)
                            .padding(.vertical, 12)
                        HStack(alignment: .center, spacing: 18) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(track.title).font(.system(size: 25, weight: .bold, design: .rounded)).lineLimit(3)
                                Text(track.artist).font(.body).foregroundStyle(.secondary)
                                Text(track.album).font(.caption).foregroundStyle(Theme.subdued).lineLimit(2)
                            }
                            Spacer(minLength: 0)
                            Button { library.toggleFavorite(track) } label: {
                                Image(systemName: library.state.favoriteIDs.contains(track.id) ? "heart.fill" : "heart")
                                    .font(.system(size: 23)).frame(width: 44, height: 44)
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
                            }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 0) {
                            Button { playback.toggleShuffle() } label: {
                                Image(systemName: "shuffle").font(.system(size: 21))
                                    .foregroundStyle(playback.isShuffled ? Theme.accent : Theme.subdued).frame(width: 48, height: 48)
                            }.accessibilityLabel(playback.isShuffled ? "Shuffle on" : "Shuffle off")
                            Spacer(minLength: 6)
                            Button { playback.previous() } label: {
                                Image(systemName: "backward.end.fill").font(.system(size: 29)).frame(width: 48, height: 56)
                            }.accessibilityLabel("Previous song")
                            Spacer(minLength: 6)
                            Button { playback.togglePlayback() } label: {
                                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 29, weight: .semibold))
                                    .foregroundStyle(Theme.background).frame(width: 76, height: 76)
                                    .background(Theme.accent, in: Circle())
                            }.accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
                            Spacer(minLength: 6)
                            Button { playback.next() } label: {
                                Image(systemName: "forward.end.fill").font(.system(size: 29)).frame(width: 48, height: 56)
                            }.accessibilityLabel("Next song")
                            Spacer(minLength: 6)
                            Button { playback.repeatMode = playback.repeatMode.next } label: {
                                Image(systemName: playback.repeatMode.symbol).font(.system(size: 21))
                                    .foregroundStyle(playback.repeatMode == .off ? Theme.subdued : Theme.accent).frame(width: 48, height: 48)
                            }.accessibilityLabel(playback.repeatMode.label)
                        }.foregroundStyle(.white)
                        Label("OFFLINE · YOUR LIBRARY", systemImage: "iphone")
                            .font(.system(size: 10, weight: .semibold)).tracking(1.6).foregroundStyle(Theme.subdued)
                            .padding(.top, 10)
                    } else {
                        Text("Choose a song from your library.").foregroundStyle(.secondary).padding(.vertical, 80)
                    }
                }.padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 36)
            }
        }
        .background(LinearGradient(colors: [Color(red: 0.17, green: 0.14, blue: 0.12), Theme.background], startPoint: .top, endPoint: .bottom))
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
                            Button { playback.removeFromQueue(id: track.id) } label: {
                                Image(systemName: "minus.circle").foregroundStyle(.secondary).frame(width: 34, height: 44)
                            }.buttonStyle(.plain).accessibilityLabel("Remove \(track.title) from queue")
                        }
                    }.listRowBackground(Theme.surface)
                }
            }
            .scrollContentBackground(.hidden).background(Theme.background)
            .navigationTitle("Play queue").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.preferredColorScheme(.dark).tint(Theme.accent)
    }
}
