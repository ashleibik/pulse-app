import Foundation
import BackgroundTasks
import SwiftData
import WidgetKit
import PulseCore

/// Pulling band data while Pulse is not on screen.
///
/// The main path is the kept connection (BandManager): with the band connected, iOS wakes Pulse
/// for the band's own messages and a running pull simply continues in the background. On top:
/// - "Background app refresh" (`taskID`): short wake-ups now and then (iOS decides when).
/// - A nightly processing task (`nightlyID`): iOS runs it when the phone is idle, usually at night
///   on the charger, with more time. It pulls the night so far and recalculates, so sleep and HRV
///   are mostly ready before you open the app in the morning.
///
/// Limits (Apple's, not ours): iOS decides if and when these run; nothing runs after the app is
/// force-quit (swiped away) or with Background App Refresh off. A pull cut short is safe: every
/// batch is acknowledged to the band only after it is saved.
@MainActor
enum BackgroundSync {
    /// Must match BGTaskSchedulerPermittedIdentifiers in project.yml.
    static let taskID = "dev.pulse.app.sync"
    static let nightlyID = "dev.pulse.app.nightly"

    /// Ask iOS for the next wake-ups. Called whenever the app goes to the background.
    static func schedule() {
        let refresh = BGAppRefreshTaskRequest(identifier: taskID)
        refresh.earliestBeginDate = Date.now.addingTimeInterval(BandManager.backgroundInterval)
        try? BGTaskScheduler.shared.submit(refresh)

        let nightly = BGProcessingTaskRequest(identifier: nightlyID)
        nightly.requiresNetworkConnectivity = false
        nightly.requiresExternalPower = false
        nightly.earliestBeginDate = Date.now.addingTimeInterval(60 * 60)
        try? BGTaskScheduler.shared.submit(nightly)
    }

    /// The nightly task is registered by hand (SwiftUI's `.backgroundTask` only knows app refresh).
    /// Must run before the app finishes launching (PulseApp.init).
    static func registerNightly(container: ModelContainer) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: nightlyID, using: .main) { task in
            let work = Task { @MainActor in
                await run(container: container, seconds: 120)
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    /// Connect if needed, pull what's new, wait for it (at most `seconds`), refresh the widget.
    static func run(container: ModelContainer, seconds: TimeInterval = 25) async {
        schedule()      // book the next ones first, whatever happens below
        let context = container.mainContext
        let band = BandManager.shared
        // When iOS launched the app just for this, no screen exists yet to react to new data.
        if band.onDataChanged == nil {
            band.onDataChanged = {
                Notifier.refresh(context: context)
                Notifier.recoveryReady(context: context)
                WidgetBridge.publish(context: context)
            }
        }
        band.launch(context: context)
        let deadline = Date.now.addingTimeInterval(seconds)
        var asked = false
        while Date.now < deadline && !Task.isCancelled {
            if band.isConnected && !asked {
                band.pullIfDue(olderThan: 60)
                asked = true
            }
            if asked && band.stage != .syncing { break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        // Out of time: nothing to stop. With the band connected the pull goes on as iOS allows.
        WidgetBridge.publish(context: context)
    }
}

/// Writes last night's numbers for the widget and asks iOS to redraw it.
@MainActor
enum WidgetBridge {
    static func publish(context: ModelContext) {
        let days = (try? context.fetch(FetchDescriptor<DaySummaryRecord>())) ?? []
        guard let night = LastNight.day(in: days.map(\.value)),
              let record = days.first(where: { $0.date == night.date }) else {
            // No night yet: the widget shows empty values, never made-up ones.
            if WidgetSnapshot.empty.save() { WidgetCenter.shared.reloadAllTimelines() }
            return
        }
        let sleeps = (try? context.fetch(FetchDescriptor<SleepRecord>())) ?? []
        let snapshot = WidgetSnapshot(day: record.date, recovery: record.recoveryScore,
                                      sleepScore: NightVitals.performance(for: record, sleeps: sleeps)?.score,
                                      zone: record.zone?.rawValue, word: record.zone?.word ?? "Learning",
                                      strain: record.strain, sleepMinutes: record.sleepMinutes,
                                      simulated: false, updated: .now)
        if snapshot.save() { WidgetCenter.shared.reloadAllTimelines() }
    }
}
