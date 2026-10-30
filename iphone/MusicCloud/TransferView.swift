import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct TransferView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var showExport = false
    @State private var backupDocument: PlaylistBackup?
    @State private var showRestore = false
    @State private var pendingRestore: Data?
    @State private var isReadingBackup = false

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    Image(systemName: "cable.connector").font(.system(size: 44, weight: .light)).foregroundStyle(Theme.accent)
                    Text("Plug in. Fill up. Go.")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("MusicCloud plays files stored on your iPhone. Your computer can be turned off after the copy finishes.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }.padding(.vertical, 12)
            }.listRowBackground(Theme.background)
            Section("From your Windows computer") {
                TransferStep(number: "1", title: "Connect with a USB cable", detail: "Unlock your iPhone, tap Trust if asked, then open Apple Devices on your computer.")
                TransferStep(number: "2", title: "Copy files to MusicCloud", detail: "Select your iPhone → Files → MusicCloud. Add your audio files and wait until the transfer finishes. Keep the originals on your computer.")
                TransferStep(number: "3", title: "Open your library", detail: "Return to MusicCloud. It scans when you open the app. Tap the circular arrow in Library to rescan at any time.")
            }.listRowBackground(Theme.surface)
            Section("Already on your iPhone?") {
                Label("Tap + in Library to copy audio from Files.", systemImage: "plus.circle")
                    .font(.subheadline).listRowBackground(Theme.surface)
                Text("Duplicate filenames receive a number. Imports never replace an existing file.")
                    .font(.caption).foregroundStyle(.secondary).listRowBackground(Theme.surface)
            }
            Section("Your library") {
                LabeledContent("Songs", value: "\(library.tracks.count)")
                LabeledContent("Audio storage", value: library.totalSize)
                LabeledContent("Playlists", value: "\(library.state.playlists.count)")
                if let lastScan = library.lastScan {
                    LabeledContent("Last scan") { Text(lastScan, style: .time).foregroundStyle(.secondary) }
                }
                Button { library.rescan() } label: { Label("Rescan music", systemImage: "arrow.clockwise") }
                    .disabled(library.isScanning)
            }.listRowBackground(Theme.surface)
            Section("Library backup") {
                Button {
                    do {
                        backupDocument = PlaylistBackup(data: try library.makeBackup())
                        showExport = true
                    } catch { library.message = "Could not prepare backup: \(error.localizedDescription)" }
                } label: { Label("Export library backup", systemImage: "square.and.arrow.up") }
                Button { showRestore = true } label: { Label("Restore library backup", systemImage: "arrow.counterclockwise") }
                    .disabled(isReadingBackup)
                if isReadingBackup { ProgressView("Opening backup…") }
                Text("Save the JSON file in On My iPhone → MusicCloud, then copy it to your computer in Apple Devices. The backup includes favorites, ordered playlists, and song detail edits; keep separate copies of your audio.")
                    .font(.caption).foregroundStyle(.secondary)
            }.listRowBackground(Theme.surface)
            Section("Formats and backups") {
                Text("MP3, M4A, AAC, WAV, AIFF, FLAC, and CAF filenames are indexed. Playback depends on the file’s codec and iOS support. Protected subscription downloads do not work.")
                Text("Keep your audio originals, a playlist export, and a device backup. Deleting the app deletes its local music, favorites, and playlists. Renaming or moving a file changes its library identity.")
            }.font(.subheadline).foregroundStyle(.secondary).listRowBackground(Theme.surface)
            Section {
                VStack(alignment: .leading, spacing: 7) {
                    Text("MUSICCLOUD").font(.system(size: 11, weight: .bold)).tracking(3).foregroundStyle(Theme.accent)
                    Text("Personal. Offline. Yours.").font(.subheadline)
                    Text("No account, advertisements, analytics, server, or app network requests. Only import music you have permission to copy.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Version 1.0 · Source build").font(.caption2).foregroundStyle(Theme.subdued)
                }.padding(.vertical, 8)
            }.listRowBackground(Theme.surface)
        }
        .scrollContentBackground(.hidden).background(Theme.background)
        .navigationTitle("USB transfer").navigationBarTitleDisplayMode(.inline)
        .fileExporter(isPresented: $showExport, document: backupDocument, contentType: .json,
            defaultFilename: "MusicCloud-playlists") { result in
                if case .failure(let error) = result { library.message = "Backup was not exported: \(error.localizedDescription)" }
            }
        .fileImporter(isPresented: $showRestore, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url):
                isReadingBackup = true
                Task {
                    defer { isReadingBackup = false }
                    do { pendingRestore = try await LibraryStore.readBackup(from: url) }
                    catch { library.message = "Could not open backup: \(error.localizedDescription)" }
                }
            case .failure(let error): library.message = "Backup was not opened: \(error.localizedDescription)"
            }
        }
        .confirmationDialog("Restore library backup?", isPresented: Binding(get: { pendingRestore != nil },
            set: { if !$0 { pendingRestore = nil } }), titleVisibility: .visible) {
                if let data = pendingRestore {
                    Button("Replace from backup", role: .destructive) {
                        pendingRestore = nil
                        do { try library.restoreBackup(data) }
                        catch { library.message = "Could not restore backup: \(error.localizedDescription)" }
                    }
                }
            } message: {
                Text("This replaces favorites and playlists. A newer-format backup replaces all current song edits, even if it contains none; an older-format backup preserves current song edits. Audio files are not changed. Export your current library first if you want to keep it.")
            }
    }
}

private struct PlaylistBackup: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

@MainActor
private struct TransferStep: View {
    let number: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(number).font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.background).frame(width: 28, height: 28).background(Theme.accent, in: Circle())
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(.vertical, 8)
    }
}

