import SwiftUI
import SwiftData

/// App entry point.
@main
struct PulseApp: App {
    /// One database for the whole app (on-device, offline first).
    let container: ModelContainer = PulseStore.makeContainer()

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)   // dark mode first; a light theme can come later
                .tint(Theme.accent)
        }
        .modelContainer(container)
    }
}
