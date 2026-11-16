import SwiftUI
import SwiftData

/// App entry point.
@main
struct PulseApp: App {
    /// One database for the whole app (on-device, offline first).
    let container: ModelContainer = PulseStore.makeContainer()
    /// "dark" (default) | "light" | "system". Changed in Settings > Appearance.
    @AppStorage("appearance") private var appearance = "dark"

    private var colorScheme: ColorScheme? {
        switch appearance {
        case "light": return .light
        case "system": return nil       // follow the iPhone's own setting
        default: return .dark
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)        // the Glow design is dark only
                // Monochrome: controls are black / white.
                .tint(DS.Colors.accent)
        }
        .modelContainer(container)
    }
}
