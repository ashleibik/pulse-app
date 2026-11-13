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
                // Follows the system's light / dark setting. Monochrome: controls are black / white.
                .tint(DS.Colors.primary)
        }
        .modelContainer(container)
    }
}
