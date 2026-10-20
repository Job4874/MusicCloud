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
                                ArtworkView(data: library.playlistTracks(playlist).first?.artwork, size: 60, symbol: "music.note.list")
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(playlist.name).font(.headline).lineLimit(1)
                                    Text("\(playlist.trackIDs.count) songs").font(.caption).foregroundStyle(.secondary)
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

    var body: some View {
        List {
            if let playlist {
                Section {
                    VStack(spacing: 14) {
                        ArtworkView(data: tracks.first?.artwork, size: 160, symbol: "music.note.list")
                        Text("\(tracks.count) available songs · \(tracks.reduce(0) { $0 + $1.duration }.musicTime)")
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
                    if playlist.trackIDs.isEmpty {
                        Button { showAdd = true } label: {
                            Label("Add your first songs", systemImage: "plus.circle")
                                .frame(maxWidth: .infinity).padding(.vertical, 24)
                        }.listRowBackground(Theme.surface)
                    }
                    ForEach(playlist.trackIDs, id: \.self) { id in
                        if let track = library.track(id: id) {
                            TrackRow(track: track, context: tracks).listRowBackground(Theme.surface)
                        } else {
                            VStack(alignment: .leading, spacing: 5) {
                                Text((id as NSString).lastPathComponent).font(.subheadline)
                                Text("File missing. Copy it back to the same path, or remove this entry.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.listRowBackground(Theme.surface)
                        }
                    }
                    .onDelete { library.removeTracks(at: $0, from: playlistID) }
                    .onMove { library.moveTracks(from: $0, to: $1, in: playlistID) }
                } footer: {
                    if !playlist.trackIDs.isEmpty {
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
                EditButton().disabled(playlist?.trackIDs.isEmpty ?? true)
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
