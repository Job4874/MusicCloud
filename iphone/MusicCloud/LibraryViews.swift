import SwiftUI
import UniformTypeIdentifiers
import ImageIO

@MainActor
struct RootView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var playback: PlaybackController
    @State private var showNowPlaying = false
    @State private var selectedTab = RootTab.library
    private enum RootTab: Hashable { case library, playlists, transfer }

    var body: some View {
        Group {
            if library.isLibraryProtected {
                VStack(spacing: 20) {
                    Image(systemName: "lock.shield").font(.system(size: 46, weight: .light)).foregroundStyle(Theme.accent)
                    Text("Your library needs attention").font(.title2.bold())
                    Text(library.message ?? "Your saved music has been preserved. A compatible library backup is needed before making changes.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.background)
            } else {
                tabsWithPlayer
                    .sheet(isPresented: $showNowPlaying) { NowPlayingView() }
                    .alert("MusicCloud", isPresented: Binding(get: { library.message != nil }, set: { if !$0 { library.message = nil } })) {
                        Button("OK", role: .cancel) { library.message = nil }
                    } message: { Text(library.message ?? "") }
                    .alert("Playback", isPresented: Binding(get: { playback.errorMessage != nil }, set: { if !$0 { playback.errorMessage = nil } })) {
                        Button("OK", role: .cancel) { playback.errorMessage = nil }
                    } message: { Text(playback.errorMessage ?? "") }
                    .task { if library.lastScan == nil { library.rescan() } }
                    .onChange(of: library.tracksRevision) { _ in
                        guard library.lastScanSucceeded else { return }
                        playback.restoreIfNeeded(with: library.tracks)
                        playback.reconcile(with: library.tracks)
                    }
            }
        }
    }

    @ViewBuilder private var tabsWithPlayer: some View {
        if #available(iOS 26.1, *) {
            tabs(usesInset: false).tabViewBottomAccessory(isEnabled: playback.currentTrack != nil) { miniPlayer }.tabBarMinimizeBehavior(.never)
        } else if #available(iOS 26.0, *) {
            tabs(usesInset: false).tabViewBottomAccessory { miniPlayer }.tabBarMinimizeBehavior(.never)
        } else { tabs(usesInset: true) }
    }
    private func tabs(usesInset: Bool) -> some View {
        TabView(selection: $selectedTab) {
            NavigationStack { screen(LibraryView(), inset: usesInset) }
                .tabItem { Label("Library", systemImage: "square.stack.fill").accessibilityIdentifier("tab.library") }.tag(RootTab.library)
            NavigationStack { screen(PlaylistsView(), inset: usesInset) }
                .tabItem { Label("Playlists", systemImage: "music.note.list").accessibilityIdentifier("tab.playlists") }.tag(RootTab.playlists)
            NavigationStack { screen(TransferView(), inset: usesInset) }
                .tabItem { Label("Transfer", systemImage: "arrow.down.circle").accessibilityIdentifier("tab.transfer") }.tag(RootTab.transfer)
        }.toolbar(.visible, for: .tabBar)
    }
    @ViewBuilder private func screen<Content: View>(_ content: Content, inset: Bool) -> some View {
        if inset {
            content.toolbar(.visible, for: .tabBar).safeAreaInset(edge: .bottom, spacing: 0) { miniPlayer.background(Theme.background) }
        } else { content.toolbar(.visible, for: .tabBar) }
    }
    @ViewBuilder private var miniPlayer: some View {
        if playback.currentTrack != nil { MiniPlayer { showNowPlaying = true }.padding(.horizontal, 8).padding(.vertical, 4) }
    }
}

struct MusicCatalogCollection: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let tracks: [Track]
    let covers: [Data]
    let searchKey: String
}

struct MusicCatalogSnapshot {
    var tracks: [Track] = []
    var searchKeys: [String: String] = [:]
    var albums: [MusicCatalogCollection] = []
    var artists: [MusicCatalogCollection] = []
    init(tracks: [Track] = []) {
        self.tracks = tracks
        searchKeys = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0.searchableText.musicSortKey) })
        let keys = searchKeys
        let albumsByKey = Dictionary(grouping: tracks) { $0.album + "\u{001F}" + $0.artist }
        albums = albumsByKey.map { key, values in
            MusicCatalogCollection(id: key, title: values[0].album, subtitle: values[0].artist, tracks: values,
                covers: musicCoverSamples(values), searchKey: values.map { keys[$0.id] ?? "" }.joined(separator: " "))
        }.sorted { $0.title.musicSortKey < $1.title.musicSortKey }
        let artistsByKey = Dictionary(grouping: tracks, by: \.artist)
        artists = artistsByKey.map { key, values in
            MusicCatalogCollection(id: key, title: key, subtitle: "\(values.count) songs", tracks: values,
                covers: musicCoverSamples(values), searchKey: values.map { keys[$0.id] ?? "" }.joined(separator: " "))
        }.sorted { $0.title.musicSortKey < $1.title.musicSortKey }
    }
    func matching(_ query: String) -> [Track] {
        let key = query.trimmingCharacters(in: .whitespacesAndNewlines).musicSortKey
        return key.isEmpty ? tracks : tracks.filter { searchKeys[$0.id]?.contains(key) == true }
    }
}

func musicCoverSamples(_ tracks: [Track], fallback: Data? = nil) -> [Data] {
    var result: [Data] = []
    for track in tracks {
        if let art = track.artwork, !result.contains(art) { result.append(art) }
        if result.count == 4 { break }
    }
    if result.isEmpty, let fallback { result.append(fallback) }
    return result
}

private enum LibraryFilter: String, CaseIterable { case songs = "Songs", albums = "Albums", artists = "Artists" }

@MainActor
struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var playback: PlaybackController
    @State private var query = ""
    @State private var filter: LibraryFilter = .songs
    @State private var showImport = false
    @State private var snapshot = MusicCatalogSnapshot()
    @State private var visibleTracks: [Track] = []
    @State private var visibleCollections: [MusicCatalogCollection] = []
    @State private var likedCovers: [Data] = []

    var body: some View {
        List {
            if query.isEmpty {
                Section {
                    LikedSongsLink(covers: likedCovers)
                }.listRowInsets(EdgeInsets(top: 8, leading: 18, bottom: 16, trailing: 18)).listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
            Section {
                HStack(spacing: 8) {
                    ForEach(LibraryFilter.allCases, id: \.self) { option in
                        Button { filter = option; refreshFilter() } label: {
                            Text(option.rawValue).font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 18).padding(.vertical, 10)
                                .foregroundStyle(filter == option ? Theme.ink : Theme.subdued)
                                .background(filter == option ? Theme.accent : Theme.surface, in: Capsule())
                        }.buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                }
            }.listRowInsets(EdgeInsets(top: 0, leading: 18, bottom: 12, trailing: 18)).listRowBackground(Color.clear).listRowSeparator(.hidden)
            if library.isScanning || library.isImporting {
                Section {
                    HStack(spacing: 10) {
                        ProgressView().tint(Theme.accent)
                        Text(library.isImporting ? "Adding your music…" : "Updating library…").font(.caption).foregroundStyle(Theme.subdued)
                    }
                }.listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
            Section {
                if filter == .songs {
                    if visibleTracks.isEmpty { emptyState }
                    ForEach(Array(visibleTracks.enumerated()), id: \.element.id) { index, track in
                        TrackRow(track: track, context: visibleTracks, playbackIndex: index, contextName: query.isEmpty ? "Your library" : "Search results")
                            .musicSongListRow()
                    }
                } else {
                    if visibleCollections.isEmpty { emptyState }
                    ForEach(visibleCollections) { collection in
                        NavigationLink {
                            TrackCollectionView(title: collection.title, subtitle: collection.subtitle, tracks: collection.tracks)
                        } label: {
                            HStack(spacing: 14) {
                                CollectionArtwork(covers: collection.covers, size: 68, symbol: filter == .artists ? "person.fill" : "opticaldisc")
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(collection.title).font(.headline).foregroundStyle(.white).lineLimit(1)
                                    Text(filter == .albums ? collection.subtitle : "\(collection.tracks.count) songs").font(.caption).foregroundStyle(Theme.subdued).lineLimit(1)
                                }
                            }.padding(.vertical, 5)
                        }.musicSongListRow()
                    }
                }
            } header: {
                HStack {
                    MusicSectionHeading(title: query.isEmpty ? (filter == .songs ? "All songs" : filter.rawValue) : "Results",
                        count: filter == .songs ? visibleTracks.count : visibleCollections.count)
                    Spacer()
                    if filter == .songs, !visibleTracks.isEmpty {
                        Button { playback.playAll(visibleTracks, shuffled: true, contextName: "Your library") } label: {
                            Image(systemName: "shuffle").font(.subheadline.weight(.semibold)).frame(width: 44, height: 38)
                        }.accessibilityLabel("Shuffle all songs")
                    }
                }.padding(.bottom, 6).textCase(nil)
            }
        }
        .listStyle(.plain).scrollContentBackground(.hidden).background(Theme.background)
        .refreshable { await MainActor.run { library.rescan() } }
        .navigationTitle("Library")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Songs, artists, albums")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button { showImport = true } label: { Label("Import from Files", systemImage: "square.and.arrow.down") }
                    Button { library.rescan() } label: { Label("Refresh library", systemImage: "arrow.clockwise") }
                        .disabled(library.isScanning)
                } label: { Image(systemName: "plus").font(.body.weight(.semibold)).frame(width: 40, height: 40).background(Theme.surface, in: Circle()) }
                .accessibilityLabel("Add music")
            }
        }
        .fileImporter(isPresented: $showImport, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): library.importFiles(urls)
            case .failure(let error): library.message = "Import was not completed: \(error.localizedDescription)"
            }
        }
        .onAppear { reload() }
        .onChange(of: library.catalogRevision) { _ in reload() }
        .onChange(of: query) { _ in refreshFilter() }
    }
    private var emptyState: some View {
        MusicEmptyState(symbol: query.isEmpty ? "music.note" : "magnifyingglass", title: query.isEmpty ? "Your music starts here" : "No matches",
            detail: query.isEmpty ? "Import audio from Files or use Transfer to add music from your computer." : "Try a different song, artist or album.")
            .listRowBackground(Color.clear).listRowSeparator(.hidden)
    }
    private func reload() {
        snapshot = MusicCatalogSnapshot(tracks: library.tracks)
        likedCovers = musicCoverSamples(library.likedTracks)
        refreshFilter()
    }
    private func refreshFilter() {
        visibleTracks = snapshot.matching(query)
        let collections = filter == .albums ? snapshot.albums : snapshot.artists
        let key = query.trimmingCharacters(in: .whitespacesAndNewlines).musicSortKey
        visibleCollections = key.isEmpty ? collections : collections.filter { $0.searchKey.contains(key) }
    }
}

@MainActor
struct LikedSongsLink: View {
    @EnvironmentObject private var library: LibraryStore
    var covers: [Data] = []
    var body: some View {
        NavigationLink {
            if let id = library.likedPlaylistID { PlaylistDetailView(playlistID: id) }
            else { TrackCollectionView(title: "Liked Songs", subtitle: "Your saved music", tracks: library.likedTracks) }
        } label: {
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "heart.fill").font(.system(size: 21)).foregroundStyle(Theme.accent)
                    Text("Liked Songs").font(.system(size: 25, weight: .bold)).foregroundStyle(.white)
                    Text("\(library.likedTracks.count) on your iPhone").font(.caption).foregroundStyle(.white.opacity(0.6))
                }
                Spacer(minLength: 8)
                CollectionArtwork(covers: covers, size: 94, symbol: "heart.fill")
                    .rotationEffect(.degrees(5)).shadow(color: .black.opacity(0.2), radius: 10, y: 5)
            }.padding(20)
                .background(LinearGradient(colors: [Color(red: 0.10, green: 0.24, blue: 0.20), Theme.surface], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 22))
                .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Theme.accent.opacity(0.10)))
        }.buttonStyle(.plain).accessibilityLabel("Liked Songs, \(library.likedTracks.count) songs on this iPhone")
    }
}

@MainActor
struct TrackCollectionView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var playback: PlaybackController
    let title: String
    var subtitle: String?
    let tracks: [Track]
    @State private var currentTracks: [Track] = []
    @State private var covers: [Data] = []
    var body: some View {
        List {
            Section {
                HStack(spacing: 18) {
                    CollectionArtwork(covers: covers, size: 112)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(title).font(.title2.bold()).lineLimit(3)
                        if let subtitle { Text(subtitle).font(.caption).foregroundStyle(Theme.subdued).lineLimit(2) }
                        Text("\(currentTracks.count) songs").font(.caption).foregroundStyle(Theme.subdued)
                    }
                }.padding(.vertical, 8)
                HStack(spacing: 10) {
                    Button { playback.playAll(currentTracks, contextName: title) } label: { Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity) }.buttonStyle(MusicActionStyle())
                    Button { playback.playAll(currentTracks, shuffled: true, contextName: title) } label: { Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity) }.buttonStyle(MusicActionStyle(prominent: false))
                }.disabled(currentTracks.isEmpty).padding(.bottom, 12)
            }.listRowBackground(Color.clear).listRowSeparator(.hidden)
            Section {
                ForEach(Array(currentTracks.enumerated()), id: \.offset) { index, track in
                    TrackRow(track: track, context: currentTracks, playbackIndex: index, contextName: title).musicSongListRow()
                }
            }
        }.listStyle(.plain).scrollContentBackground(.hidden).background(Theme.background)
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .onAppear { reload() }.onChange(of: library.catalogRevision) { _ in reload() }
    }
    private func reload() { currentTracks = tracks.compactMap { library.track(id: $0.id) }; covers = musicCoverSamples(currentTracks) }
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
    private var selected: Bool { playback.currentTrack?.id == track.id && (playlistID == nil || playback.sourcePlaylistID == playlistID) }
    var body: some View {
        HStack(spacing: 2) {
            Button {
                if let playbackIndex { playback.play(at: playbackIndex, from: context, contextName: contextName, playlistID: playlistID) }
                else { playback.play(track, from: context, contextName: contextName, playlistID: playlistID) }
            } label: {
                HStack(spacing: 13) {
                    ArtworkView(data: track.artwork, size: 54)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(track.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(selected ? Theme.accent : .white).lineLimit(1)
                        Text(track.artist).font(.system(size: 12)).foregroundStyle(Theme.subdued).lineLimit(1)
                    }
                    Spacer(minLength: 2)
                    if selected {
                        if playback.isLoading { ProgressView().scaleEffect(0.7).tint(Theme.accent) }
                        else if playback.isPlaying { Image(systemName: "waveform").font(.caption).foregroundStyle(Theme.accent) }
                    }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            Button { library.toggleLike(track) } label: {
                Image(systemName: library.isLiked(track) ? "heart.fill" : "heart")
                    .font(.system(size: 16)).foregroundStyle(library.isLiked(track) ? Theme.accent : Theme.subdued.opacity(0.6))
                    .frame(width: 44, height: 50).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(library.isLiked(track) ? "Unlike \(track.title)" : "Like \(track.title)")
            SongActionsMenu(track: track)
        }.padding(.vertical, 6)
    }
}

@MainActor
struct SongActionsMenu: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var playback: PlaybackController
    let track: Track
    @State private var confirmDelete = false
    @State private var showEdit = false
    var body: some View {
        Menu {
            Button { playback.playNext(track) } label: { Label("Play next", systemImage: "text.line.first.and.arrowtriangle.forward") }
            Button { library.toggleLike(track) } label: { Label(library.isLiked(track) ? "Remove from Liked Songs" : "Add to Liked Songs", systemImage: library.isLiked(track) ? "heart.slash" : "heart") }
            if !library.visiblePlaylists.isEmpty {
                Menu {
                    ForEach(library.visiblePlaylists) { playlist in Button(playlist.name) { library.add(track, to: playlist.id) } }
                } label: { Label("Add to playlist", systemImage: "text.badge.plus") }
            }
            Button { showEdit = true } label: { Label("Edit song details", systemImage: "pencil") }
            Button(role: .destructive) { confirmDelete = true } label: { Label("Delete audio file", systemImage: "trash") }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.subdued)
                .frame(width: 44, height: 50).contentShape(Rectangle())
        }.accessibilityLabel("Options for \(track.title)")
            .sheet(isPresented: $showEdit) { EditSongDetailsView(track: track) }
            .confirmationDialog("Delete audio file?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete from iPhone", role: .destructive) {
                    guard library.requireWritableLibrary() else { return }
                    playback.prepareForDeletion(track); library.deleteFile(track)
                }
            } message: { Text("\(track.title) will be removed from this iPhone. Its playlist entries stay visible as missing files. Keep a copy of your original audio.") }
    }
}

@MainActor
struct EditSongDetailsView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let track: Track
    @State private var title: String
    @State private var artist: String
    @State private var album: String
    @State private var error: String?
    init(track: Track) {
        self.track = track; _title = State(initialValue: track.title); _artist = State(initialValue: track.artist); _album = State(initialValue: track.album)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section { HStack(spacing: 16) { ArtworkView(data: track.artwork, size: 72); VStack(alignment: .leading, spacing: 5) { Text(track.title).font(.headline); Text(track.artist).font(.caption).foregroundStyle(Theme.subdued) } }.padding(.vertical, 8) }
                Section("Details") { TextField("Title", text: $title); TextField("Artist", text: $artist); TextField("Album", text: $album) }
                if let error { Section { Text(error).foregroundStyle(.red) } }
                Section {
                    if library.state.trackOverrides?[track.id] != nil {
                        Button("Reset to original details") {
                            if library.resetMetadata(id: track.id) { dismiss() } else { error = library.message ?? "Could not restore details." }
                        }
                    }
                    Text("These details are saved in MusicCloud. Your original audio stays intact.").font(.caption).foregroundStyle(Theme.subdued)
                }
            }.scrollContentBackground(.hidden).background(Theme.background)
                .navigationTitle("Edit song").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Save") { if library.editMetadata(id: track.id, title: title, artist: artist, album: album) { dismiss() } else { error = library.message ?? "Could not save details." } }.fontWeight(.semibold) }
                }
        }.preferredColorScheme(.dark).tint(Theme.accent)
    }
}

@MainActor
private final class DecodedMusicArtwork {
    static let shared = DecodedMusicArtwork()
    private let cache = NSCache<MusicArtworkCacheKey, UIImage>()
    private var pending: [MusicArtworkRequest: Task<UIImage?, Never>] = [:]
    private init() { cache.totalCostLimit = 80 * 1024 * 1024; cache.countLimit = 240 }
    func load(data: Data, pixels: Int) async -> UIImage? {
        let key = MusicArtworkCacheKey(data: data, pixels: pixels)
        if let cached = cache.object(forKey: key) { return cached }
        let request = MusicArtworkRequest(data: data, pixels: pixels)
        if let task = pending[request] { return await task.value }
        let task = Task.detached(priority: .utility) { () -> UIImage? in
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: pixels,
                kCGImageSourceShouldCacheImmediately: true]
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return UIImage(cgImage: image)
        }
        pending[request] = task
        let image = await task.value
        pending.removeValue(forKey: request)
        if let image {
            cache.setObject(image, forKey: key, cost: (image.cgImage?.bytesPerRow ?? pixels * 4) * (image.cgImage?.height ?? pixels))
        }
        return image
    }
}

private struct MusicArtworkRequest: Hashable { let data: Data?; let pixels: Int }

private final class MusicArtworkCacheKey: NSObject {
    let data: NSData
    let pixels: Int
    init(data: Data, pixels: Int) { self.data = data as NSData; self.pixels = pixels; super.init() }
    override var hash: Int { data.hash ^ pixels.hashValue }
    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? MusicArtworkCacheKey else { return false }
        return pixels == other.pixels && data == other.data
    }
}

@MainActor
struct ArtworkView: View {
    let data: Data?
    let size: CGFloat
    var symbol = "music.note"
    @Environment(\.displayScale) private var displayScale
    @State private var decoded: UIImage?
    private var pixels: Int { let target = Int(size * displayScale); return target <= 200 ? 200 : (target <= 450 ? 450 : 1024) }
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.16, green: 0.23, blue: 0.24), Theme.surface], startPoint: .topLeading, endPoint: .bottomTrailing)
            if let decoded { Image(uiImage: decoded).resizable().scaledToFill() }
            else { Image(systemName: symbol).font(.system(size: size * 0.32, weight: .light)).foregroundStyle(Theme.accent.opacity(0.65)) }
        }.frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: max(7, size * 0.085), style: .continuous))
            .accessibilityHidden(true)
            .task(id: MusicArtworkRequest(data: data, pixels: pixels)) {
                decoded = nil
                guard let data, !data.isEmpty else { return }
                let result = await DecodedMusicArtwork.shared.load(data: data, pixels: pixels)
                guard !Task.isCancelled else { return }
                decoded = result
            }
    }
}

@MainActor
struct CollectionArtwork: View {
    let covers: [Data]
    let size: CGFloat
    var symbol = "music.note.list"
    var body: some View {
        Group {
            if covers.count < 2 { ArtworkView(data: covers.first, size: size, symbol: symbol) }
            else {
                VStack(spacing: 1) {
                    HStack(spacing: 1) { tile(0); tile(1) }
                    HStack(spacing: 1) { tile(2); tile(3) }
                }.frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: max(9, size * 0.08)))
            }
        }.accessibilityHidden(true)
    }
    private func tile(_ index: Int) -> some View { ArtworkView(data: covers[index % covers.count], size: (size - 1) / 2, symbol: symbol) }
}

struct MusicEmptyState: View {
    let symbol: String
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 36, weight: .light)).foregroundStyle(Theme.accent).padding(.bottom, 3)
            Text(title).font(.headline).foregroundStyle(.white)
            Text(detail).font(.subheadline).foregroundStyle(Theme.subdued).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity).padding(.horizontal, 24).padding(.vertical, 36)
    }
}

extension View {
    func musicSongListRow() -> some View {
        self.listRowInsets(EdgeInsets(top: 0, leading: 18, bottom: 0, trailing: 12))
            .listRowBackground(Color.clear).listRowSeparator(.hidden)
    }
}
