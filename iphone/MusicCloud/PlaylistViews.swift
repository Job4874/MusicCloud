import SwiftUI

@MainActor
struct PlaylistsView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var showCreate = false
    @State private var playlistName = ""
    @State private var deleting: Playlist?

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("A place for every mood.")
                        .font(.system(size: 29, weight: .bold, design: .rounded))
                    Text("Make it yours. Your playlists stay on this iPhone.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }.padding(.vertical, 12)
            }.listRowBackground(Theme.background)
            if library.state.playlists.isEmpty {
                Section {
                    VStack(spacing: 16) {
                        Image(systemName: "music.note.list").font(.system(size: 42, weight: .light)).foregroundStyle(Theme.accent)
                        Text("Your first mix starts here").font(.headline)
                        Text("Add songs, arrange their order, and play them any time.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Create playlist") { showCreate = true }.buttonStyle(.borderedProminent).foregroundStyle(Theme.background)
                    }.frame(maxWidth: .infinity).padding(.vertical, 30)
                }.listRowBackground(Theme.surface)
            } else {
                Section("\(library.state.playlists.count) playlists") {
                    ForEach(library.state.playlists) { playlist in
                        NavigationLink {
                            PlaylistDetailView(playlistID: playlist.id)
                        } label: {
                            HStack(spacing: 12) {
                                ArtworkView(data: library.artwork(for: playlist), size: 60, symbol: "music.note.list")
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(playlist.name).font(.headline).lineLimit(1)
                                    Text("\(library.playlistTracks(playlist).count) available · \(library.playlistEntryCount(playlist)) total")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }.padding(.vertical, 5)
                        }
                        .swipeActions { Button("Delete", role: .destructive) { deleting = playlist } }
                        .listRowBackground(Theme.surface)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden).background(Theme.background)
        .navigationTitle("Playlists")
        .toolbar { Button { playlistName = ""; showCreate = true } label: { Image(systemName: "plus") }.accessibilityLabel("Create playlist") }
        .alert("New playlist", isPresented: $showCreate) {
            TextField("Playlist name", text: $playlistName)
            Button("Create") { library.createPlaylist(name: playlistName); playlistName = "" }
            Button("Cancel", role: .cancel) { playlistName = "" }
        } message: { Text("Give your next mix a name.") }
        .confirmationDialog("Delete playlist?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            if let playlist = deleting {
                Button("Delete \(playlist.name)", role: .destructive) {
                    library.deletePlaylist(id: playlist.id)
                    deleting = nil
                }
            }
        } message: { Text("The audio files will stay in your library.") }
    }
}

private struct PlaylistRowOccurrence: Identifiable {
    enum Identity: Hashable { case entry(UUID), legacyIndex(Int) }
    let id: Identity
    let trackID: String?
    let title: String
    let artist: String
    let status: String
    let playbackIndex: Int?
}

@MainActor
struct PlaylistDetailView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var playback: PlaybackController
    let playlistID: UUID
    @State private var showAdd = false
    @State private var showRename = false
    @State private var updatedName = ""

    private var playlist: Playlist? { library.playlist(id: playlistID) }
    private var tracks: [Track] { playlist.map(library.playlistTracks) ?? [] }
    private var rows: [PlaylistRowOccurrence] {
        guard let playlist else { return [] }
        var result: [PlaylistRowOccurrence] = []
        var playableIndex = 0
        if let entries = playlist.entries {
            for entry in entries {
                let available = entry.trackID.flatMap { library.track(id: $0) } != nil
                result.append(PlaylistRowOccurrence(id: .entry(entry.id), trackID: entry.trackID,
                    title: entry.title, artist: entry.artist, status: entry.status,
                    playbackIndex: available ? playableIndex : nil))
                if available { playableIndex += 1 }
            }
        } else {
            // Older native playlists can repeat a path. Index identity keeps
            // every occurrence visible until an edit promotes it to UUID rows.
            for (offset, id) in playlist.trackIDs.enumerated() {
                let track = library.track(id: id)
                result.append(PlaylistRowOccurrence(id: .legacyIndex(offset), trackID: id,
                    title: track?.title ?? (id as NSString).lastPathComponent,
                    artist: track?.artist ?? "Unknown artist", status: track == nil ? "missing" : "downloaded",
                    playbackIndex: track == nil ? nil : playableIndex))
                if track != nil { playableIndex += 1 }
            }
        }
        return result
    }

    var body: some View {
        List {
            if let playlist {
                Section {
                    VStack(spacing: 14) {
                        ArtworkView(data: library.artwork(for: playlist), size: 160, symbol: "music.note.list")
                        Text("\(tracks.count) available · \(library.playlistEntryCount(playlist)) total · \(tracks.reduce(0) { $0 + $1.duration }.musicTime)")
                            .font(.subheadline).foregroundStyle(.secondary)
                        HStack {
                            Button { playback.playAll(tracks) } label: {
                                Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                            }.buttonStyle(.borderedProminent).foregroundStyle(Theme.background)
                            Button { playback.playAll(tracks, shuffled: true) } label: {
                                Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
                            }.buttonStyle(.bordered)
                        }.disabled(tracks.isEmpty)
                    }.frame(maxWidth: .infinity).padding(.vertical)
                }.listRowBackground(Theme.background)
                Section {
                    if rows.isEmpty {
                        Button { showAdd = true } label: {
                            Label("Add your first songs", systemImage: "plus.circle")
                                .frame(maxWidth: .infinity).padding(.vertical, 24)
                        }.listRowBackground(Theme.surface)
                    }
                    ForEach(rows) { row in
                        if let index = row.playbackIndex, tracks.indices.contains(index) {
                            TrackRow(track: tracks[index], context: tracks, playbackIndex: index)
                                .listRowBackground(Theme.surface)
                        } else {
                            HStack(spacing: 12) {
                                ArtworkView(data: nil, size: 46, symbol: "music.note")
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(row.title.isEmpty ? "Untitled song" : row.title)
                                        .font(.subheadline.weight(.semibold)).lineLimit(2)
                                    Text(row.artist.isEmpty ? "Unknown artist" : row.artist)
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    Text(unavailableStatus(for: row))
                                        .font(.caption).foregroundStyle(Theme.subdued).lineLimit(2)
                                }
                            }.padding(.vertical, 3).listRowBackground(Theme.surface)
                        }
                    }
                    .onDelete { library.removeTracks(at: $0, from: playlistID) }
                    .onMove { library.moveTracks(from: $0, to: $1, in: playlistID) }
                } footer: {
                    if !rows.isEmpty {
                        Text("Tap Edit to drag songs into order or remove them from this playlist.")
                    }
                }
            } else {
                Text("This playlist was deleted.")
            }
        }
        .scrollContentBackground(.hidden).background(Theme.background)
        .navigationTitle(playlist?.name ?? "Playlist").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                EditButton().disabled(rows.isEmpty || library.isLibraryProtected)
                Menu {
                    Button { showAdd = true } label: { Label("Add songs", systemImage: "plus") }
                    Button { updatedName = playlist?.name ?? ""; showRename = true } label: { Label("Rename", systemImage: "pencil") }
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("Playlist options")
            }
        }
        .sheet(isPresented: $showAdd) { AddSongsView(playlistID: playlistID) }
        .alert("Rename playlist", isPresented: $showRename) {
            TextField("Playlist name", text: $updatedName)
            Button("Save") { library.renamePlaylist(id: playlistID, name: updatedName) }
            Button("Cancel", role: .cancel) { }
        }
    }

    private func unavailableStatus(for row: PlaylistRowOccurrence) -> String {
        if row.status.lowercased() == "downloaded" || row.status.lowercased() == "missing" {
            return "File missing on this iPhone"
        }
        let status = row.status.trimmingCharacters(in: .whitespacesAndNewlines)
        return status.isEmpty ? "Unavailable" : status.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

@MainActor
private struct AddSongsView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let playlistID: UUID
    @State private var query = ""

    private var tracks: [Track] {
        query.isEmpty ? library.tracks : library.tracks.filter { $0.searchableText.localizedStandardContains(query) }
    }

    var body: some View {
        NavigationStack {
            List {
                if tracks.isEmpty { Text(library.tracks.isEmpty ? "Import music in the Library tab first." : "No songs match your search.").foregroundStyle(.secondary) }
                ForEach(tracks) { track in
                    let selected = library.playlist(id: playlistID)?.trackIDs.contains(track.id) == true
                    Button {
                        if selected { library.removeTrack(id: track.id, from: playlistID) }
                        else { library.add(track, to: playlistID) }
                    } label: {
                        HStack(spacing: 12) {
                            ArtworkView(data: track.artwork, size: 42)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(track.title).font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                                Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: selected ? "checkmark.circle.fill" : "plus.circle").foregroundStyle(Theme.accent)
                        }.padding(.vertical, 3)
                    }.listRowBackground(Theme.surface)
                    .accessibilityLabel("\(selected ? "Remove" : "Add") \(track.title)")
                }
            }
            .scrollContentBackground(.hidden).background(Theme.background)
            .navigationTitle("Add songs").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Search your library")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.preferredColorScheme(.dark).tint(Theme.accent)
    }
}


