import SwiftUI
import UniformTypeIdentifiers
import UIKit

@MainActor
struct TransferView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var wifi = WiFiUploadServer()
    @State private var showImport = false
    @State private var showExport = false
    @State private var backupDocument: PlaylistBackup?
    @State private var showRestore = false
    @State private var pendingRestore: Data?
    @State private var isReadingBackup = false

    var body: some View {
        List {
            Section {
                HStack(spacing: 15) {
                    Image(systemName: "iphone").font(.system(size: 28, weight: .light)).foregroundStyle(Theme.accent)
                        .frame(width: 56, height: 64).background(Theme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 15))
                    VStack(alignment: .leading, spacing: 7) {
                        Text("On this iPhone").font(.headline)
                        Text("\(library.tracks.count) songs · \(library.totalSize)").font(.subheadline).foregroundStyle(Theme.subdued)
                        Text("Ready to play without a connection.").font(.caption).foregroundStyle(Theme.subdued)
                    }
                }.padding(.vertical, 5)
            }.listRowBackground(Color.clear)
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "wifi").font(.system(size: 22)).foregroundStyle(Theme.accent).frame(width: 30)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Wi-Fi upload").font(.headline)
                        Text("Add music from your computer.").font(.caption).foregroundStyle(Theme.subdued)
                    }
                    Spacer()
                    if wifi.isRunning { Circle().fill(Theme.accent).frame(width: 8, height: 8) }
                    else if wifi.isStarting { ProgressView().tint(Theme.accent) }
                }.padding(.vertical, 5)
                if let address = wifi.address {
                    VStack(alignment: .leading, spacing: 13) {
                        Text("Open this link on a computer connected to the same Wi-Fi:").font(.caption).foregroundStyle(Theme.subdued)
                        Text(address.absoluteString).font(.system(size: 12, design: .monospaced)).foregroundStyle(.white)
                            .textSelection(.enabled).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Theme.background, in: RoundedRectangle(cornerRadius: 10))
                        HStack(spacing: 20) {
                            Button { UIPasteboard.general.string = address.absoluteString } label: { Label("Copy link", systemImage: "doc.on.doc") }
                            ShareLink(item: address) { Label("Share", systemImage: "square.and.arrow.up") }
                        }.font(.subheadline.weight(.medium)).buttonStyle(.borderless)
                    }.padding(.vertical, 5)
                }
                Button {
                    if wifi.isRunning || wifi.isStarting { wifi.stop() }
                    else if !library.isLibraryProtected { wifi.start(documentsURL: library.documentsURL) { library.rescan() } }
                } label: {
                    Label(wifi.isRunning || wifi.isStarting ? "Stop transfer" : "Start Wi-Fi transfer", systemImage: wifi.isRunning || wifi.isStarting ? "stop.fill" : "arrow.up.arrow.down")
                        .frame(maxWidth: .infinity)
                }.buttonStyle(MusicActionStyle(prominent: !wifi.isRunning)).disabled(library.isLibraryProtected).padding(.vertical, 5)
                Text(wifi.status).font(.caption).foregroundStyle(Theme.subdued)
            } footer: {
                Text(wifi.isRunning ? "Keep this screen open. Anyone on this Wi-Fi with the link can upload until you stop the transfer." : "Your phone and computer must use the same private Wi-Fi. Files up to 512 MB are supported.")
                    .font(.caption).foregroundStyle(Theme.subdued)
            }.listRowBackground(Theme.surface)
            Section("More ways to add music") {
                Button { showImport = true } label: { Label("Import from Files", systemImage: "folder.badge.plus").font(.subheadline.weight(.medium)).padding(.vertical, 5) }
                DisclosureGroup {
                    TransferStep(number: "1", title: "Connect your iPhone", detail: "Use a USB cable. Open Apple Devices on Windows, or Finder on a Mac.")
                    TransferStep(number: "2", title: "Copy your audio", detail: "Select your iPhone, open Files, then MusicCloud. Add your audio files and wait for the copy to finish.")
                    TransferStep(number: "3", title: "Refresh your library", detail: "Return to Library and pull down to refresh, or use Refresh library below.")
                } label: { Label("Copy over USB", systemImage: "cable.connector").font(.subheadline.weight(.medium)).foregroundStyle(.white) }
            }.listRowBackground(Theme.surface)
            Section("Your library") {
                LabeledContent("Songs", value: "\(library.tracks.count)")
                LabeledContent("Playlists", value: "\(library.state.playlists.count)")
                LabeledContent("Storage", value: library.totalSize)
                Button { library.rescan() } label: {
                    HStack { Label("Refresh library", systemImage: "arrow.clockwise"); Spacer(); if library.isScanning { ProgressView().tint(Theme.accent) } }
                }.disabled(library.isScanning)
            }.font(.subheadline).listRowBackground(Theme.surface)
            Section("Keep a backup") {
                Button {
                    do { backupDocument = PlaylistBackup(data: try library.makeBackup()); showExport = true }
                    catch { library.message = "Could not prepare backup: \(error.localizedDescription)" }
                } label: { Label("Export library backup", systemImage: "square.and.arrow.up") }
                Button { showRestore = true } label: {
                    HStack { Label("Restore library backup", systemImage: "arrow.counterclockwise"); Spacer(); if isReadingBackup { ProgressView() } }
                }.disabled(isReadingBackup)
            } footer: {
                Text("A library backup keeps your playlists, liked songs and detail edits. Keep separate copies of your audio files.").font(.caption).foregroundStyle(Theme.subdued)
            }.font(.subheadline).listRowBackground(Theme.surface)
            Section {
                DisclosureGroup("Supported audio") {
                    Text("MP3, M4A, AAC, WAV, AIFF, FLAC and CAF. Playback depends on the file’s codec and iOS support. Protected subscription downloads cannot be imported.")
                        .font(.caption).foregroundStyle(Theme.subdued).padding(.vertical, 5)
                }.font(.subheadline)
                HStack {
                    Image(systemName: "waveform").foregroundStyle(Theme.accent)
                    Text("MusicCloud").font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"))")
                        .font(.caption).foregroundStyle(Theme.subdued)
                }.padding(.vertical, 5)
            }.listRowBackground(Theme.surface)
        }.scrollContentBackground(.hidden).background(Theme.background)
            .navigationTitle("Transfer")
            .onDisappear { wifi.stop() }
            .onChange(of: scenePhase) { phase in if phase == .background { wifi.stop() } }
            .onChange(of: library.isLibraryProtected) { protected in if protected { wifi.stop() } }
            .fileImporter(isPresented: $showImport, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
                switch result { case .success(let urls): library.importFiles(urls); case .failure(let error): library.message = "Import was not completed: \(error.localizedDescription)" }
            }
            .fileExporter(isPresented: $showExport, document: backupDocument, contentType: .json, defaultFilename: "MusicCloud-library-backup") { result in
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
            .confirmationDialog("Restore this library backup?", isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } }), titleVisibility: .visible) {
                if let data = pendingRestore {
                    Button("Replace library from backup", role: .destructive) {
                        pendingRestore = nil
                        do { try library.restoreBackup(data) }
                        catch { library.message = "Could not restore backup: \(error.localizedDescription)" }
                    }
                }
            } message: {
                Text("This replaces your playlists and liked songs. A newer-format backup also replaces song detail edits; older backups preserve them. Your audio files stay intact. Export a backup first to keep today’s changes.")
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
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

private struct TransferStep: View {
    let number: String
    let title: String
    let detail: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number).font(.caption.weight(.bold)).foregroundStyle(Theme.accent).frame(width: 25, height: 25).background(Theme.accent.opacity(0.10), in: Circle())
            VStack(alignment: .leading, spacing: 5) { Text(title).font(.subheadline.weight(.semibold)); Text(detail).font(.caption).foregroundStyle(Theme.subdued) }
        }.padding(.vertical, 7)
    }
}
