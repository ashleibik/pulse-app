import Foundation
import SwiftData
import UserNotifications
import PulseCore

/// Reminders, as local notifications: they are created on the phone and need no server.
///
///   - "Time to wind down": 30 minutes before tonight's bedtime from the Sleep planner.
///   - "Recovery is ready": after a band sync, with this morning's score.
///
/// Off until the user turns them on in Settings (that is when iOS asks for permission).
/// ⚠ Never run on a real phone yet.
@MainActor
enum Notifier {
    private static let enabledKey = "remindersEnabled"
    private static let bedtimeID = "pulse.bedtime"
    private static let recoveryID = "pulse.recovery"

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// Asks iOS for permission. Returns whether reminders are now on.
    static func enable() async -> Bool {
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
        UserDefaults.standard.set(granted, forKey: enabledKey)
        return granted
    }

    static func disable() {
        UserDefaults.standard.set(false, forKey: enabledKey)
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }

    /// Works out tonight's bedtime from the stored data and (re)schedules the reminder.
    /// Call when the app opens and after new data arrives.
    static func refresh(context: ModelContext) {
        guard isEnabled else { return }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [bedtimeID])
        guard let bedtime = bedtime(context: context) else { return }
        let remindAt = bedtime.addingTimeInterval(-30 * 60)
        guard remindAt > .now else { return }

        let content = UNMutableNotificationContent()
        content.title = "Time to wind down"
        content.body = "Be in bed by \(bedtime.formatted(date: .omitted, time: .shortened)) to get the sleep you need."
        content.sound = .default
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: remindAt)
        let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
        center.add(UNNotificationRequest(identifier: bedtimeID, content: content, trigger: trigger))
    }

    /// After a band sync. iOS only shows it when the app is not on screen.
    static func recoveryReady(context: ModelContext) {
        guard isEnabled else { return }
        var descriptor = FetchDescriptor<DaySummaryRecord>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        descriptor.fetchLimit = 1
        guard let today = try? context.fetch(descriptor).first, let score = today.recoveryScore,
              Calendar.current.isDateInToday(today.date) else { return }
        let content = UNMutableNotificationContent()
        content.title = "Recovery \(PulseFormat.percent(score)): \(RecoveryZone(score: score).word)"
        content.body = today.explanation
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: recoveryID, content: content, trigger: trigger))
    }

    /// The Sleep planner's choices (DESIGN.md §4b-10). A wake time of -1 = your usual one.
    nonisolated static let plannerWakeKey = "plannerWakeMinutes"
    nonisolated static let plannerGoalKey = "plannerGoal"

    /// Tonight's sleep need in minutes, after naps since last night. nil before the first day.
    static func tonightsNeed(context: ModelContext) -> Double? {
        let sleeps = ((try? context.fetch(FetchDescriptor<SleepRecord>())) ?? []).map(\.value)
        var descriptor = FetchDescriptor<DaySummaryRecord>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        descriptor.fetchLimit = 1
        guard let today = try? context.fetch(descriptor).first else { return nil }
        let goal = Double(ProfileStore.current(in: context).sleepGoalMinutes)
        // Naps since last night lower tonight's need.
        let lastNight = sleeps.filter { !$0.isNap }.max { $0.end < $1.end }
        let napped = Recovery.napMinutes(sleeps, after: lastNight?.end ?? Calendar.current.startOfDay(for: .now), upTo: .now)
        return Recovery.needAfterNaps(Recovery.sleepNeed(goal: goal, previousStrain: today.strain,
                                                         previousNeed: Double(today.sleepNeedMinutes),
                                                         previousAsleep: today.sleepMinutes.map { Double($0) }),
                                      napMinutes: Double(napped))
    }

    /// Tonight's plan with the planner's saved wake time and goal. nil without a need or a wake time.
    static func plan(context: ModelContext) -> SleepPlanner.Plan? {
        guard let need = tonightsNeed(context: context) else { return nil }
        let sleeps = ((try? context.fetch(FetchDescriptor<SleepRecord>())) ?? []).map(\.value)
        let defaults = UserDefaults.standard
        let wake = defaults.object(forKey: plannerWakeKey) as? Int
        let goal = defaults.string(forKey: plannerGoalKey).flatMap(SleepPlanner.Goal.init(rawValue:)) ?? .peak
        return SleepPlanner.plan(needMinutes: need, goal: goal, wakeMinuteOfDay: (wake ?? -1) >= 0 ? wake : nil,
                                 sleeps: sleeps, now: .now, calendar: .current)
    }

    /// Tonight's bedtime from the Sleep planner, or nil without enough to plan with.
    static func bedtime(context: ModelContext) -> Date? { plan(context: context)?.bedtime }
}
