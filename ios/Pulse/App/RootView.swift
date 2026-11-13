import SwiftUI
import SwiftData

/// The tab bar: Today · Sleep · Activity · Trends. Settings opens from the Today screen.
struct RootView: View {
    @Environment(\.modelContext) private var context
    @State private var tab: Tab = Tab(rawValue: LaunchOptions.tab ?? "") ?? .today
    @State private var loader = DemoDataLoader()
    @State private var band = BandManager()
    /// Per-device UI preference (not health data), so UserDefaults is fine here.
    /// (UserDefaults also reads launch arguments, so `-hasSeenWelcome YES` skips it for screenshots.)
    @AppStorage("hasSeenWelcome") private var hasSeenWelcome = false

    enum Tab: String, Hashable { case today, sleep, activity, trends }

    var body: some View {
        TabView(selection: $tab) {
            TodayView()
                .tabItem { Label("Today", systemImage: "sun.max.fill") }
                .tag(Tab.today)
            SleepView()
                .tabItem { Label("Sleep", systemImage: "moon.zzz.fill") }
                .tag(Tab.sleep)
            ActivityView()
                .tabItem { Label("Activity", systemImage: "flame.fill") }
                .tag(Tab.activity)
            TrendsView()
                .tabItem { Label("Trends", systemImage: "chart.xyaxis.line") }
                .tag(Tab.trends)
        }
        .sensoryFeedback(.selection, trigger: tab)                    // light tick when switching tabs
        .sensoryFeedback(.success, trigger: loader.state == .ready)   // when demo data finishes loading
        .environment(loader)
        .environment(band)
        .fullScreenCover(isPresented: Binding(get: { !hasSeenWelcome }, set: { hasSeenWelcome = !$0 })) {
            WelcomeView { hasSeenWelcome = true }
        }
        .task {
            // Until the band is paired, fill the app with demo data on first launch.
            band.onDataChanged = { [loader] in loader.dataChanged() }
            await loader.loadIfEmpty(context: context)
        }
    }
}

#Preview {
    RootView()
        .modelContainer(PulseStore.previewContainer)
}
