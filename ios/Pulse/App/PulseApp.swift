import SwiftUI
import SwiftData

/// App entry point.
@main
struct PulseApp: App {
    /// One database for the whole app (on-device, offline first).
    let container: ModelContainer

    init() {
        let container = PulseStore.makeContainer()
        self.container = container
        BackgroundSync.registerNightly(container: container)
        // A paired band: ask for its connection right away. This is also how a connection that iOS
        // restored in the background (Pulse relaunched for the band) is picked up again.
        BandManager.shared.launch(context: container.mainContext)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)        // the Glow design is dark only
                .tint(DS.Colors.accent)
        }
        .modelContainer(container)
        // iOS wakes the app now and then to pull band data while it is closed (BackgroundSync.swift).
        .backgroundTask(.appRefresh(BackgroundSync.taskID)) { [container] in
            await BackgroundSync.run(container: container)
        }
    }
}
