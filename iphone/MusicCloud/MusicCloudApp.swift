import SwiftUI

@main
@MainActor
struct MusicCloudApp: App {
    @StateObject private var library: LibraryStore
    @StateObject private var playback: PlaybackController

    init() {
        let store = LibraryStore()
        _library = StateObject(wrappedValue: store)
        _playback = StateObject(wrappedValue: PlaybackController(documentsURL: store.documentsURL))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(library)
                .environmentObject(playback)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .onOpenURL { library.importFiles([$0]) }
        }
    }
}

enum Theme {
    static let accent = Color(red: 1, green: 0.72, blue: 0.30)
    static let background = Color(red: 0.055, green: 0.063, blue: 0.075)
    static let surface = Color(red: 0.105, green: 0.117, blue: 0.137)
    static let subdued = Color(red: 0.57, green: 0.61, blue: 0.66)
}
