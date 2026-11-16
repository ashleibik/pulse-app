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
                .preferredColorScheme(.dark)        // the Glow design is dark only
                .tint(DS.Colors.accent)
        }
        .modelContainer(container)
        // iOS wakes the app now and then to sync the band while it is closed (BackgroundSync.swift).
        .backgroundTask(.appRefresh(BackgroundSync.taskID)) { [container] in
            await BackgroundSync.run(container: container)
        }
    }
}
