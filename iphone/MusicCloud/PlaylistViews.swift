import SwiftUI

private struct PlaylistCardSnapshot: Identifiable {
    let id: UUID
    let name: String
    let available: Int
    let total: Int
    let covers: [Data]
    let searchKey: String
}

@MainActor
struct PlaylistsView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var query = ""
    @State private var showCreate = false
    @State private var playlistName = ""
    @State private var deletingID: UUID?
    @State private var createdID: UUID?
    @State private var cards: [PlaylistCardSnapshot] = []
    @State private var filtered: [PlaylistCardSnapshot] = []
    @State private var likedCovers: [Data] = []
    var body: some View {
        List {
            if query.isEmpty || "liked songs".contains(query.musicSortKey) {
                Section { LikedSongsLink(covers: likedCovers) }
                    .listRowInsets(EdgeInsets(top: 8, leading: 18, bottom: 18, trailing: 18))
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
            Section {
                if filtered.isEmpty {
                    MusicEmptyState(symbol: query.isEmpty ? "music.note.list" : "magnifyingglass", title: query.isEmpty ? "Make a playlist" : "No matching playlists",
                        detail: query.isEmpty ? "Bring your favorite songs together for a drive, a workout, or any moment." : "Try another playlist name.")
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
                ForEach(filtered) { card in
                    NavigationLink { PlaylistDetailView(playlistID: card.id) } label: {
                        HStack(spacing: 15) {
                            CollectionArtwork(covers: card.covers, size: 72)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(card.name).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white).lineLimit(2)
                                Text(card.available == card.total ? "\(card.total) songs" : "\(card.available) on iPhone · \(card.total) saved")
                                    .font(.caption).foregroundStyle(Theme.subdued)
                            }
                        }.padding(.vertical, 7)
                    }.musicSongListRow()
                        .swipeActions { Button("Delete", role: .destructive) { deletingID = card.id } }
                }
            } header: { MusicSectionHeading(title: "Your playlists", count: cards.count).padding(.vertical, 6) }
        }.listStyle(.plain).scrollContentBackground(.hidden).background(Theme.background)
            .navigationTitle("Playlists")
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Find a playlist")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { playlistName = ""; showCreate = true } label: {
                        Image(systemName: "plus").font(.body.weight(.semibold)).frame(width: 40, height: 40).background(Theme.surface, in: Circle())
                    }.accessibilityLabel("Create playlist")
                }
            }
            .alert("New playlist", isPresented: $showCreate) {
                TextField("Playlist name", text: $playlistName)
                Button("Create") { createdID = library.createPlaylist(name: playlistName); playlistName = "" }
                Button("Cancel", role: .cancel) { playlistName = "" }
            }
            .navigationDestination(isPresented: Binding(get: { createdID != nil }, set: { if !$0 { createdID = nil } })) {
                if let id = createdID { PlaylistDetailView(playlistID: id) }
            }
            .confirmationDialog("Delete playlist?", isPresented: Binding(get: { deletingID != nil }, set: { if !$0 { deletingID = nil } }), titleVisibility: .visible) {
                if let id = deletingID {
                    Button("Delete playlist", role: .destructive) { library.deletePlaylist(id: id); deletingID = nil }
                }
            } message: { Text("Your audio files stay on this iPhone.") }
            .onAppear { reload() }.onChange(of: library.catalogRevision) { _ in reload() }
            .onChange(of: query) { _ in filterCards() }
    }
    private func reload() {
        cards = library.visiblePlaylists.map { playlist in
            let tracks = library.playlistTracks(playlist)
            return PlaylistCardSnapshot(id: playlist.id, name: playlist.name, available: tracks.count,
                total: library.playlistEntryCount(playlist), covers: musicCoverSamples(tracks, fallback: library.artwork(for: playlist)), searchKey: playlist.name.musicSortKey)
        }
        likedCovers = musicCoverSamples(library.likedTracks)
        filterCards()
    }
    private func filterCards() {
        let key = query.trimmingCharacters(in: .whitespacesAndNewlines).musicSortKey
        filtered = key.isEmpty ? cards : cards.filter { $0.searchKey.contains(key) }
    }
}

private struct PlaylistRowOccurrence: Identifiable {
    enum Identity: Hashable { case entry(UUID), legacyIndex(Int) }
    let id: Identity
    let sourceOffset: Int
    let trackID: String?
    let title: String
    let artist: String
    let status: String
    let artwork: Data?
    let track: Track?
    let playbackIndex: Int?
    let searchKey: String
}

@MainActor
struct PlaylistDetailView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var playback: PlaybackController
    let playlistID: UUID
    @State private var showAdd = false
    @State private var showRename = false
    @State private var updatedName = ""
    @State private var query = ""
    @State private var rows: [PlaylistRowOccurrence] = []
    @State private var visibleRows: [PlaylistRowOccurrence] = []
    @State private var tracks: [Track] = []
    @State private var covers: [Data] = []
    @State private var totalDuration: TimeInterval = 0
    private var playlist: Playlist? { library.playlist(id: playlistID) }
    private var canonical: Bool { library.likedPlaylistID == playlistID }

    var body: some View {
        List {
            if let playlist {
                if query.isEmpty {
                    Section {
                        HStack(alignment: .center, spacing: 18) {
                            CollectionArtwork(covers: covers, size: 128, symbol: canonical ? "heart.fill" : "music.note.list")
                                .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
                            VStack(alignment: .leading, spacing: 9) {
                                Text(canonical ? "SAVED MUSIC" : "PLAYLIST").font(.system(size: 10, weight: .bold)).tracking(1.5).foregroundStyle(Theme.accent)
                                Text(canonical ? "Liked Songs" : playlist.name).font(.system(size: 25, weight: .bold)).lineLimit(3)
                                Text("\(tracks.count) on iPhone · \(rows.count) saved").font(.caption).foregroundStyle(Theme.subdued)
                                Text(totalDuration.musicTime + " of music").font(.caption2).foregroundStyle(Theme.subdued)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.padding(.top, 12).padding(.bottom, 14)
                        HStack(spacing: 10) {
                            Button { playback.playAll(tracks, contextName: canonical ? "Liked Songs" : playlist.name, playlistID: playlistID) } label: {
                                Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                            }.buttonStyle(MusicActionStyle())
                            Button { playback.playAll(tracks, shuffled: true, contextName: canonical ? "Liked Songs" : playlist.name, playlistID: playlistID) } label: {
                                Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
                            }.buttonStyle(MusicActionStyle(prominent: false))
                        }.disabled(tracks.isEmpty).padding(.bottom, 10)
                    }.listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
                Section {
                    if visibleRows.isEmpty {
                        if query.isEmpty {
                            Button { showAdd = true } label: { Label("Add songs", systemImage: "plus.circle.fill").frame(maxWidth: .infinity).padding(.vertical, 24) }
                                .listRowBackground(Color.clear).listRowSeparator(.hidden)
                        } else {
                            MusicEmptyState(symbol: "magnifyingglass", title: "No matches", detail: "Try another song or artist.")
                                .listRowBackground(Color.clear).listRowSeparator(.hidden)
                        }
                    }
                    ForEach(visibleRows) { row in
                        if let track = row.track {
                            TrackRow(track: track, context: tracks, playbackIndex: row.playbackIndex,
                                contextName: canonical ? "Liked Songs" : playlist.name, playlistID: playlistID).musicSongListRow()
                        } else {
                            HStack(spacing: 13) {
                                ArtworkView(data: row.artwork, size: 54, symbol: "icloud.slash")
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(row.title.isEmpty ? "Untitled song" : row.title).font(.system(size: 15, weight: .medium)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                                    Text(row.artist.isEmpty ? "Unknown artist" : row.artist).font(.system(size: 12)).foregroundStyle(Theme.subdued).lineLimit(1)
                                    Text(row.status == "downloaded" || row.status == "missing" ? "Not on this iPhone" : "Unavailable")
                                        .font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.subdued.opacity(0.8))
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "icloud.slash").font(.caption).foregroundStyle(Theme.subdued.opacity(0.45)).frame(width: 36)
                            }.padding(.vertical, 7).musicSongListRow()
                        }
                    }
                    .onDelete(perform: removeRows)
                    .onMove { source, destination in if query.isEmpty { library.moveTracks(from: source, to: destination, in: playlistID) } }
                    .moveDisabled(!query.isEmpty)
                } header: { MusicSectionHeading(title: query.isEmpty ? "Songs" : "Results", count: visibleRows.count).padding(.vertical, 6) }
                footer: {
                    if !rows.isEmpty { Text("Songs not on this iPhone stay saved in your playlist.").font(.caption).foregroundStyle(Theme.subdued).padding(.top, 10) }
                }
            } else { MusicEmptyState(symbol: "music.note.list", title: "Playlist removed", detail: "Your audio files are still in your library.") }
        }.listStyle(.plain).scrollContentBackground(.hidden).background(Theme.background)
            .navigationTitle(canonical ? "Liked Songs" : "Playlist").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Search this playlist")
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button { showAdd = true } label: { Image(systemName: "plus").frame(width: 32, height: 40) }.accessibilityLabel("Add songs")
                    EditButton().font(.subheadline).disabled(rows.isEmpty || library.isLibraryProtected)
                    if !canonical {
                        Menu { Button("Rename playlist") { updatedName = playlist?.name ?? ""; showRename = true } }
                            label: { Image(systemName: "ellipsis").frame(width: 30, height: 40) }.accessibilityLabel("Playlist options")
                    }
                }
            }
            .sheet(isPresented: $showAdd) { AddSongsView(playlistID: playlistID) }
            .alert("Rename playlist", isPresented: $showRename) {
                TextField("Playlist name", text: $updatedName)
                Button("Save") { library.renamePlaylist(id: playlistID, name: updatedName) }
                Button("Cancel", role: .cancel) { }
            }
            .onAppear { reload() }.onChange(of: library.catalogRevision) { _ in reload() }
            .onChange(of: query) { _ in filterRows() }
    }

    private func reload() {
        guard let playlist else { rows = []; visibleRows = []; tracks = []; covers = []; totalDuration = 0; return }
        var nextRows: [PlaylistRowOccurrence] = []
        var nextTracks: [Track] = []
        if let entries = playlist.entries {
            for (offset, entry) in entries.enumerated() {
                let track = library.track(for: entry)
                nextRows.append(PlaylistRowOccurrence(id: .entry(entry.id), sourceOffset: offset, trackID: entry.trackID,
                    title: entry.title, artist: entry.artist, status: entry.status, artwork: library.artwork(for: entry), track: track,
                    playbackIndex: track == nil ? nil : nextTracks.count,
                    searchKey: (entry.title + " " + entry.artist + " " + (track?.searchableText ?? "")).musicSortKey))
                if let track { nextTracks.append(track) }
            }
        } else {
            for (offset, path) in playlist.trackIDs.enumerated() {
                let track = library.track(id: path)
                let title = track?.title ?? (path as NSString).lastPathComponent
                let artist = track?.artist ?? "Unknown artist"
                nextRows.append(PlaylistRowOccurrence(id: .legacyIndex(offset), sourceOffset: offset, trackID: path,
                    title: title, artist: artist, status: "missing", artwork: track?.artwork, track: track,
                    playbackIndex: track == nil ? nil : nextTracks.count, searchKey: (title + " " + artist).musicSortKey))
                if let track { nextTracks.append(track) }
            }
        }
        rows = nextRows; tracks = nextTracks
        totalDuration = nextTracks.reduce(0) { $0 + $1.duration }
        covers = musicCoverSamples(nextTracks, fallback: library.artwork(for: playlist))
        filterRows()
    }
    private func filterRows() {
        let key = query.trimmingCharacters(in: .whitespacesAndNewlines).musicSortKey
        visibleRows = key.isEmpty ? rows : rows.filter { $0.searchKey.contains(key) }
    }
    private func removeRows(_ offsets: IndexSet) {
        guard let current = playlist else { return }
        let selected = offsets.compactMap { visibleRows.indices.contains($0) ? visibleRows[$0] : nil }
        let actualOffsets: IndexSet
        if let entries = current.entries {
            let ids = Set(selected.compactMap { row -> UUID? in if case .entry(let id) = row.id { return id }; return nil })
            actualOffsets = IndexSet(entries.indices.filter { ids.contains(entries[$0].id) })
        } else {
            actualOffsets = IndexSet(selected.compactMap { row in
                current.trackIDs.indices.contains(row.sourceOffset) && current.trackIDs[row.sourceOffset] == row.trackID ? row.sourceOffset : nil
            })
        }
        library.removeTracks(at: actualOffsets, from: playlistID)
    }
}

@MainActor
private struct AddSongsView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let playlistID: UUID
    @State private var query = ""
    @State private var snapshot = MusicCatalogSnapshot()
    @State private var tracks: [Track] = []
    @State private var selectedIDs: Set<String> = []
    private var canonical: Bool { library.likedPlaylistID == playlistID }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    if tracks.isEmpty { MusicEmptyState(symbol: "magnifyingglass", title: "No songs found", detail: "Import music in Library or try another search.").listRowBackground(Color.clear) }
                    ForEach(tracks) { track in
                        let selected = selectedIDs.contains(track.id)
                        Button {
                            if canonical { library.toggleLike(track) }
                            else if selected { library.removeTrack(id: track.id, from: playlistID) }
                            else { library.add(track, to: playlistID) }
                        } label: {
                            HStack(spacing: 13) {
                                ArtworkView(data: track.artwork, size: 50)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(track.title).font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                                    Text(track.artist).font(.caption).foregroundStyle(Theme.subdued).lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: selected ? "checkmark.circle.fill" : "plus.circle").font(.system(size: 23)).foregroundStyle(selected ? Theme.accent : Theme.subdued)
                            }.padding(.vertical, 6).contentShape(Rectangle())
                        }.buttonStyle(.plain).musicSongListRow().accessibilityLabel("\(selected ? "Remove" : "Add") \(track.title)")
                    }
                } header: { Text("\(selectedIDs.count) selected").font(.caption).foregroundStyle(Theme.subdued).textCase(nil) }
            }.listStyle(.plain).scrollContentBackground(.hidden).background(Theme.background)
                .navigationTitle(canonical ? "Add liked songs" : "Add songs").navigationBarTitleDisplayMode(.inline)
                .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Find a song")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.fontWeight(.semibold) } }
                .onAppear { reload() }.onChange(of: library.catalogRevision) { _ in reload() }
                .onChange(of: query) { _ in tracks = snapshot.matching(query) }
        }.preferredColorScheme(.dark).tint(Theme.accent)
    }
    private func reload() {
        snapshot = MusicCatalogSnapshot(tracks: library.tracks)
        selectedIDs = canonical ? Set(library.likedTracks.map(\.id)) : Set(library.playlist(id: playlistID)?.trackIDs ?? [])
        tracks = snapshot.matching(query)
    }
}
