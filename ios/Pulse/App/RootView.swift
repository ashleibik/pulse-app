import SwiftUI
import SwiftData

/// The tab bar: Today · Sleep · Activity · Trends. Settings opens from the Today screen.
struct RootView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab: Tab = Tab(rawValue: LaunchOptions.tab ?? "") ?? .today
    @State private var loader = DataLoader()
    /// Shared with BackgroundSync, which can run before (or without) this screen.
    @State private var band = BandManager.shared
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
        .environment(loader)
        .environment(band)
        .environment(health)
        .environment(cloud)
        .fullScreenCover(isPresented: Binding(get: { !hasSeenWelcome }, set: { hasSeenWelcome = !$0 })) {
            WelcomeView { hasSeenWelcome = true }
        }
        // Every time the app opens (or comes back): cached data is already on screen; pull what's
        // new right away. It slides in when it's saved. No sheet, no popup.
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active {
                band.appBecameActive(context: context)
                Notifier.refresh(context: context)      // tonight's bedtime reminder
                WidgetBridge.publish(context: context)
                // Data pulled while the app was closed reaches Apple Health now.
                if loader.rawDataReady { Task { await health.export(context: context) } }
            } else if phase == .background {
                BackgroundSync.schedule()               // wake-ups while the app is closed
            }
        }
        // While the app is open: pull every few minutes over the kept connection.
        .task(id: scenePhase == .active) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                if !Task.isCancelled { band.pullIfDue() }
            }
        }
        // Demo month generated, band synced, recalculated: the widget follows.
        .onChange(of: loader.revision) { _, _ in WidgetBridge.publish(context: context) }
        .onChange(of: loader.state) { _, state in
            if state == .ready { WidgetBridge.publish(context: context) }
        }
        .task {
            band.onDataChanged = { [loader, health, cloud, context] in
                loader.dataChanged()
                Notifier.refresh(context: context)
                Notifier.recoveryReady(context: context)
                // New band data: pass it on, but only to what the user turned on.
                Task {
                    await health.export(context: context)       // Apple Health
                    await cloud.sync(context: context)          // own cloud (summaries only)
                }
            }
            await cloud.load()
            await loader.prepare(context: context)      // also removes old simulated data, once
        }
    }
}

#Preview {
    RootView()
        .modelContainer(PulseStore.previewContainer)
}
