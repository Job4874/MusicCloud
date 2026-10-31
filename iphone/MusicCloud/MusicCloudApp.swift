import SwiftUI

@main
@MainActor
struct MusicCloudApp: App {
    @StateObject private var library: LibraryStore
    @StateObject private var playback: PlaybackController

    init() {
        let store = LibraryStore()
        _library = StateObject(wrappedValue: store)
        _playback = StateObject(wrappedValue: PlaybackController(documentsURL: store.documentsURL, isEnabled: !store.isLibraryProtected))
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
    static let accent = Color(red: 0.60, green: 0.94, blue: 0.77)
    static let background = Color(red: 0.035, green: 0.047, blue: 0.059)
    static let surface = Color(red: 0.075, green: 0.094, blue: 0.11)
    static let elevated = Color(red: 0.12, green: 0.14, blue: 0.16)
    static let subdued = Color(red: 0.57, green: 0.62, blue: 0.65)
    static let ink = Color(red: 0.04, green: 0.12, blue: 0.09)
    static let outline = Color.white.opacity(0.075)
}

struct MusicActionStyle: ButtonStyle {
    var prominent = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .frame(minHeight: 46)
            .padding(.horizontal, 18)
            .foregroundStyle(prominent ? Theme.ink : Color.white)
            .background(prominent ? Theme.accent : Theme.elevated, in: Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct MusicSectionHeading: View {
    let title: String
    var count: Int? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.title3.weight(.bold)).foregroundStyle(.white)
            if let count { Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(Theme.subdued) }
        }.textCase(nil)
    }
}

struct MusicStatusPill: View {
    let text: String
    var symbol = "checkmark.circle.fill"
    var body: some View {
        Label(text, systemImage: symbol).font(.caption2.weight(.medium))
            .foregroundStyle(Theme.subdued)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.white.opacity(0.045), in: Capsule())
    }
}
