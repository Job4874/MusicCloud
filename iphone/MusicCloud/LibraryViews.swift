import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct RootView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var playback: PlaybackController
    @Environment(\.scenePhase) private var scenePhase
    @State private var showNowPlaying = false
    @State private var selectedTab = RootTab.library

    private enum RootTab: Hashable { case library, playlists, transfer }

    var body: some View {
        Group {
        if library.isLibraryProtected {
            VStack(spacing: 16) {
                Image(systemName: "lock.shield").font(.largeTitle)
                Text("MusicCloud cannot safely open this library").font(.title2.bold())
                Text("This build cannot safely use or change the saved library. No library changes were made. Preserve the existing data and use the matching app or a verified migration.")
                    .multilineTextAlignment(.center)
            }.padding(24)
        } else {
        tabsWithPlayer
        .sheet(isPresented: $showNowPlaying) { NowPlayingView() }
        .alert("MusicCloud", isPresented: Binding(get: { library.message != nil },
            set: { if !$0 { library.message = nil } })) {
            Button("OK", role: .cancel) { library.message = nil }
        } message: { Text(library.message ?? "") }
        .alert("Playback", isPresented: Binding(get: { playback.errorMessage != nil },
            set: { if !$0 { playback.errorMessage = nil } })) {
            Button("OK", role: .cancel) { playback.errorMessage = nil }
        } message: { Text(playback.errorMessage ?? "") }
        .task { library.rescan() }
        .onChange(of: scenePhase) { phase in if phase == .active { library.rescan() } }
        .onChange(of: library.tracks) { tracks in
            if library.lastScanSucceeded { playback.reconcile(with: tracks) }
        }
        .onChange(of: library.lastScan) { _ in
            if library.lastScanSucceeded {
                playback.restoreIfNeeded(with: library.tracks)
                playback.reconcile(with: library.tracks)
            }
        }
        }
        }
    }

    @ViewBuilder private var tabsWithPlayer: some View {
        if #available(iOS 26.1, *) {
            tabs(usesPlayerInset: false)
                .tabViewBottomAccessory(isEnabled: playback.currentTrack != nil) { miniPlayer }
                .tabBarMinimizeBehavior(.never)
        } else if #available(iOS 26.0, *) {
            tabs(usesPlayerInset: false)
                .tabViewBottomAccessory { miniPlayer }
                .tabBarMinimizeBehavior(.never)
        } else {
            tabs(usesPlayerInset: true)
        }
    }

    private func tabs(usesPlayerInset: Bool) -> some View {
        TabView(selection: $selectedTab) {
            NavigationStack { tabScreen(LibraryView(), usesPlayerInset: usesPlayerInset) }
                .tabItem { Label("Library", systemImage: "square.stack").accessibilityIdentifier("tab.library") }
                .tag(RootTab.library)
            NavigationStack { tabScreen(PlaylistsView(), usesPlayerInset: usesPlayerInset) }
                .tabItem { Label("Playlists", systemImage: "music.note.list").accessibilityIdentifier("tab.playlists") }
                .tag(RootTab.playlists)
            NavigationStack { tabScreen(TransferView(), usesPlayerInset: usesPlayerInset) }
                .tabItem { Label("Transfer", systemImage: "cable.connector").accessibilityIdentifier("tab.transfer") }
                .tag(RootTab.transfer)
        }
        .toolbar(.visible, for: .tabBar)
    }

    @ViewBuilder private func tabScreen<Content: View>(_ content: Content, usesPlayerInset: Bool) -> some View {
        if usesPlayerInset {
            // Older systems reserve player space inside the navigation content,
            // leaving the TabView itself and its three tab items unobstructed.
            content
                .toolbar(.visible, for: .tabBar)
                .safeAreaInset(edge: .bottom, spacing: 0) { miniPlayer.background(Theme.background) }
        } else {
            content.toolbar(.visible, for: .tabBar)
        }
    }

    @ViewBuilder private var miniPlayer: some View {
        if playback.currentTrack != nil {
            MiniPlayer { showNowPlaying = true }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
        }
    }
}

private enum LibraryFilter: String, CaseIterable {
    case songs = "Songs", favorites = "Favorites", albums = "Albums", artists = "Artists"
}

@MainActor
struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var playback: PlaybackController
    @State private var query = ""
    @State private var filter: LibraryFilter = .songs
    @State private var showImport = false

    private var visibleTracks: [Track] {
        let base = filter == .favorites ? library.favorites : library.tracks
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? base : base.filter { $0.searchableText.localizedStandardContains(query) }
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Your library").font(.title2.bold())
                        Spacer(minLength: 8)
                        Text("\(library.tracks.count) songs").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Text("\(library.totalSize) stored on this iPhone")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Button { playback.playAll(visibleTracks, contextName: filter == .favorites ? "Favorites" : "Your library") } label: {
                            Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                        }.buttonStyle(.borderedProminent).foregroundStyle(Theme.background)
                        Button { playback.playAll(visibleTracks, shuffled: true, contextName: filter == .favorites ? "Favorites" : "Your library") } label: {
                            Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
                        }.buttonStyle(.bordered)
                    }.disabled(visibleTracks.isEmpty)
                }
                .padding(.vertical, 4)
                .listRowBackground(Theme.background)
                .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 8, trailing: 4))
            }
            Section {
                Picker("Library view", selection: $filter) {
                    ForEach(LibraryFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
                    .listRowBackground(Theme.background)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 12, trailing: 0))
                if library.isScanning {
                    HStack { ProgressView(); Text("Reading your music…").font(.subheadline).foregroundStyle(.secondary) }
                        .listRowBackground(Theme.surface)
                }
                if library.isImporting {
                    HStack { ProgressView(); Text("Copying music to this iPhone…").font(.subheadline) }
                        .listRowBackground(Theme.surface)
                }
                if visibleTracks.isEmpty && !library.isScanning {
                    EmptyLibraryView(isLibraryEmpty: library.tracks.isEmpty, isSearch: !query.isEmpty,
                        isFavorites: filter == .favorites, importAction: { showImport = true })
                        .listRowBackground(Theme.surface)
                } else if filter == .albums || filter == .artists {
                    groupRows
                } else {
                    ForEach(visibleTracks) { track in
                        TrackRow(track: track, context: visibleTracks, contextName: filter == .favorites ? "Favorites" : "Your library")
                            .listRowBackground(Theme.surface)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .listStyle(.insetGrouped)
        .navigationTitle("MusicCloud")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Songs, artists, albums")
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button { library.rescan() } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("Rescan music").disabled(library.isScanning)
                Button { showImport = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Import music").disabled(library.isImporting)
            }
        }
        .fileImporter(isPresented: $showImport, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): library.importFiles(urls)
            case .failure(let error): library.message = "Import was not completed: \(error.localizedDescription)"
            }
        }
    }

    @ViewBuilder private var groupRows: some View {
        let groups = Dictionary(grouping: visibleTracks) { track in
            filter == .albums ? "\(track.album)\u{001F}\(track.artist)" : track.artist
        }
        ForEach(groups.keys.sorted { $0.musicSortKey < $1.musicSortKey }, id: \.self) { key in
            let tracks = groups[key] ?? []
            let title = filter == .albums ? (tracks.first?.album ?? "Unknown album") : key
            NavigationLink {
                TrackCollectionView(title: title, subtitle: filter == .albums ? tracks.first?.artist : nil, tracks: tracks)
            } label: {
                HStack(spacing: 12) {
                    ArtworkView(data: tracks.first?.artwork, size: 54, symbol: filter == .artists ? "person.fill" : "opticaldisc")
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.headline).lineLimit(1)
                        Text(filter == .albums ? "\(tracks.first?.artist ?? "") · \(tracks.count) songs" : "\(tracks.count) songs")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }.padding(.vertical, 4)
            }.listRowBackground(Theme.surface)
        }
    }
}

@MainActor
struct TrackCollectionView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var playback: PlaybackController
    let title: String
    var subtitle: String?
    let tracks: [Track]

    private var currentTracks: [Track] {
        tracks.compactMap { library.track(id: $0.id) }
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 16) {
                    ArtworkView(data: currentTracks.first?.artwork, size: 180)
                    if let subtitle { Text(subtitle).foregroundStyle(.secondary) }
                    HStack {
                        Button { playback.playAll(currentTracks, contextName: title) } label: {
                            Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                        }.buttonStyle(.borderedProminent).foregroundStyle(Theme.background)
                        Button { playback.playAll(currentTracks, shuffled: true, contextName: title) } label: {
                            Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
                        }.buttonStyle(.bordered)
                    }.disabled(currentTracks.isEmpty)
                }.frame(maxWidth: .infinity).padding(.vertical)
            }.listRowBackground(Theme.background)
            Section("\(currentTracks.count) songs") {
                ForEach(currentTracks) { TrackRow(track: $0, context: currentTracks, contextName: title).listRowBackground(Theme.surface) }
            }
        }
        .scrollContentBackground(.hidden).background(Theme.background)
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
    }
}

@MainActor
struct TrackRow: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var playback: PlaybackController
    let track: Track
    let context: [Track]
    var playbackIndex: Int? = nil
    var contextName: String? = nil
    var playlistID: UUID? = nil
    @State private var confirmDelete = false
    @State private var showEdit = false

    var body: some View {
        HStack(spacing: 12) {
            Button {
                if let playbackIndex { playback.play(at: playbackIndex, from: context, contextName: contextName, playlistID: playlistID) }
                else { playback.play(track, from: context, contextName: contextName, playlistID: playlistID) }
            } label: {
                HStack(spacing: 12) {
                    ArtworkView(data: track.artwork, size: 46)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(track.title).font(.subheadline.weight(.semibold))
                            .foregroundStyle(playback.currentTrack?.id == track.id ? Theme.accent : .white).lineLimit(1)
                        Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if playback.currentTrack?.id == track.id && playback.isPlaying {
                        Image(systemName: "waveform").foregroundStyle(Theme.accent).accessibilityLabel("Playing")
                    } else {
                        Text(track.duration.musicTime).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            Menu {
                Button { showEdit = true } label: { Label("Edit song details", systemImage: "pencil") }
                Button { playback.playNext(track) } label: { Label("Play next", systemImage: "text.line.first.and.arrowtriangle.forward") }
                Button { library.toggleFavorite(track) } label: {
                    Label(library.state.favoriteIDs.contains(track.id) ? "Remove favorite" : "Favorite",
                        systemImage: library.state.favoriteIDs.contains(track.id) ? "heart.slash" : "heart")
                }
                if !library.state.playlists.isEmpty {
                    Menu {
                        ForEach(library.state.playlists) { playlist in
                            Button(playlist.name) { library.add(track, to: playlist.id) }
                                .disabled(playlist.trackIDs.contains(track.id))
                        }
                    } label: { Label("Add to playlist", systemImage: "text.badge.plus") }
                }
                Button(role: .destructive) { confirmDelete = true } label: {
                    Label("Delete file from iPhone", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Theme.subdued).frame(width: 30, height: 40).contentShape(Rectangle())
            }.accessibilityLabel("Options for \(track.title)")
        }
        .padding(.vertical, 3)
        .sheet(isPresented: $showEdit) { EditSongDetailsView(track: track) }
        .confirmationDialog("Delete \(track.title)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete file from iPhone", role: .destructive) {
                guard library.requireWritableLibrary() else { return }
                playback.prepareForDeletion(track)
                library.deleteFile(track)
            }
        } message: {
            Text("This removes the audio file and its favorite. Playlist entries stay visible as missing files. Keep a backup on your computer.")
        }
    }
}

@MainActor
private struct EditSongDetailsView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let track: Track
    @State private var title: String
    @State private var artist: String
    @State private var album: String
    @State private var error: String?

    init(track: Track) {
        self.track = track
        _title = State(initialValue: track.title)
        _artist = State(initialValue: track.artist)
        _album = State(initialValue: track.album)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Song details") {
                    TextField("Title", text: $title)
                    TextField("Artist", text: $artist)
                    TextField("Album", text: $album)
                }
                Section {
                    Text("Changes appear in MusicCloud. The original audio file is unchanged.")
                        .foregroundStyle(.secondary)
                    if let error { Text(error).foregroundStyle(.red) }
                    if library.state.trackOverrides?[track.id] != nil {
                        Button("Restore original details") {
                            if library.resetMetadata(id: track.id) { dismiss() }
                            else { error = library.message ?? "Could not restore original details." }
                        }
                    }
                }
            }
            .navigationTitle("Edit song")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if library.editMetadata(id: track.id, title: title, artist: artist, album: album) { dismiss() }
                        else { error = library.message ?? "Could not save song details." }
                    }
                }
            }
        }
        .preferredColorScheme(.dark).tint(Theme.accent)
    }
}

@MainActor
struct ArtworkView: View {
    let data: Data?
    let size: CGFloat
    var symbol = "music.note"

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.30, green: 0.23, blue: 0.19), Theme.surface], startPoint: .topLeading, endPoint: .bottomTrailing)
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: symbol).font(.system(size: size * 0.37, weight: .light)).foregroundStyle(Theme.accent.opacity(0.8))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: max(6, size * 0.09), style: .continuous))
        .accessibilityHidden(true)
    }
}

@MainActor
private struct EmptyLibraryView: View {
    let isLibraryEmpty: Bool
    let isSearch: Bool
    let isFavorites: Bool
    let importAction: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: isSearch ? "magnifyingglass" : (isFavorites ? "heart" : "cable.connector"))
                .font(.system(size: 38, weight: .light)).foregroundStyle(Theme.accent)
            Text(isSearch ? "No matches" : (isFavorites ? "Keep your favorites here" : "Make room for your music"))
                .font(.headline)
            Text(isSearch ? "Try another song, artist, album, or filename." : (isFavorites ? "Use a song’s menu to add a favorite." : "Connect your iPhone to your computer and copy audio files to MusicCloud in Apple Devices. Or import files already on your phone."))
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if isLibraryEmpty && !isSearch {
                Button("Import music", action: importAction).buttonStyle(.borderedProminent).foregroundStyle(Theme.background)
            }
        }.frame(maxWidth: .infinity).padding(.vertical, 32)
    }
}


