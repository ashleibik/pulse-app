import SwiftUI
import SwiftData

/// The tab bar: Today · Sleep · Activity · Trends. Settings opens from the Today screen.
struct RootView: View {
    @Environment(\.modelContext) private var context
    @State private var tab: Tab = .today
    @State private var loader = DemoDataLoader()

    enum Tab: Hashable { case today, sleep, activity, trends }

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
        .sensoryFeedback(.selection, trigger: tab)     // light haptic tick when switching tabs
        .environment(loader)
        .task {
            // Until the band is paired, fill the app with demo data on first launch.
            await loader.loadIfEmpty(context: context)
        }
    }
}

#Preview {
    RootView()
        .modelContainer(PulseStore.previewContainer)
        .preferredColorScheme(.dark)
}
