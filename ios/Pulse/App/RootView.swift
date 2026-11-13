import SwiftUI
import SwiftData

/// The tab bar: Today · Sleep · Activity · Trends. Settings opens from the Today screen.
struct RootView: View {
    @Environment(\.modelContext) private var context
    @State private var tab: Tab = Tab(rawValue: LaunchOptions.tab ?? "") ?? .today
    @State private var loader = DemoDataLoader()
    @State private var band = BandManager()
    @State private var health = HealthExporter()
    @State private var cloud = CloudManager()
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
        .environment(health)
        .environment(cloud)
        .fullScreenCover(isPresented: Binding(get: { !hasSeenWelcome }, set: { hasSeenWelcome = !$0 })) {
            WelcomeView { hasSeenWelcome = true }
        }
        .task {
            // Until the band is paired, fill the app with demo data on first launch.
            band.onDataChanged = { [loader, health, cloud, context] in
                loader.dataChanged()
                // New band data: pass it on, but only to what the user turned on.
                Task {
                    await health.export(context: context)       // Apple Health
                    await cloud.sync(context: context)          // own cloud (summaries only)
                }
            }
            await cloud.load()
            await loader.loadIfEmpty(context: context)
        }
    }
}

#Preview {
    RootView()
        .modelContainer(PulseStore.previewContainer)
}
