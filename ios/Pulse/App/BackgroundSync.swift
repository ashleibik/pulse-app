import Foundation
import BackgroundTasks
import SwiftData
import WidgetKit
import PulseCore

/// Syncing while Pulse is closed.
///
/// iOS wakes the app now and then ("background app refresh", roughly hourly at best; iOS decides,
/// based on how often you use the app and the battery). Each time, Pulse connects to the band,
/// downloads what's new, recalculates, then updates the widget and tonight's reminder.
///
/// Limits (Apple's, not ours):
/// - iOS gives about 30 seconds. A long backlog is downloaded in parts over several wake-ups;
///   that is safe because every batch is acknowledged to the band only after it is saved.
/// - Nothing runs after the app is force-quit (swiped away), or with Background App Refresh off.
@MainActor
enum BackgroundSync {
    /// Must match BGTaskSchedulerPermittedIdentifiers in project.yml.
    static let taskID = "dev.pulse.app.sync"

    /// Ask iOS for the next wake-up. Called whenever the app goes to the background.
    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: taskID)
        request.earliestBeginDate = Date.now.addingTimeInterval(45 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    static func run(container: ModelContainer) async {
        schedule()      // book the next one first, whatever happens below
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
        band.syncIfDue(context: context)    // at most every 15 minutes
        let deadline = Date.now.addingTimeInterval(25)
        while band.isBusy && Date.now < deadline {
            try? await Task.sleep(for: .milliseconds(500))
        }
        // Out of time: stop cleanly. Everything acknowledged is saved; the rest comes next time.
        if band.isBusy { band.cancel() }
        WidgetBridge.publish(context: context)
    }
}

/// Writes today's numbers for the widget and asks iOS to redraw it.
@MainActor
enum WidgetBridge {
    static func publish(context: ModelContext) {
        var newest = FetchDescriptor<DaySummaryRecord>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        newest.fetchLimit = 1
        guard let today = try? context.fetch(newest).first else { return }
        let snapshot = WidgetSnapshot(day: today.date, recovery: today.recoveryScore, zone: today.zone?.rawValue,
                                      word: today.zone?.word ?? "Learning", strain: today.strain,
                                      sleepMinutes: today.sleepMinutes,
                                      simulated: false, updated: .now)
        if snapshot.save() { WidgetCenter.shared.reloadAllTimelines() }
    }
}
