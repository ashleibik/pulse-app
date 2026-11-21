import Foundation

/// Days in a row with a recorded night (docs/METRICS.md §17), counted with NOOP's streak calculator (`NoopStreak`).
public enum Streak {
    public struct Result: Equatable, Sendable {
        /// Days in a row up to today, or up to yesterday while today's night isn't in yet.
        public var current: Int
        /// The longest run in the history.
        public var longest: Int
        /// The last 7 days, oldest first and today last: true when that day counts.
        public var lastWeek: [Bool]
    }

    /// A day counts when the band recorded its night (it has a main sleep, so a sleep score). NOOP counts days with a recovery
    /// score; Pulse holds recovery back for its first nights while it learns the owner's normal, which would read 0 days then.
    /// Every day with a recovery has a night, so after those first nights the two agree.
    public static func counts(_ day: DailySummary) -> Bool {
        day.sleepMinutes != nil || day.recoveryScore != nil
    }

    public static func days(_ days: [DailySummary], today: Date, calendar: Calendar) -> Result {
        func key(_ date: Date) -> String {
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        }
        let runs = NoopStreak.streaks(dayKeys: days.map { key($0.date) }, qualified: days.map(counts), today: key(today))
        let counted = Set(days.filter(counts).map { key($0.date) })
        let start = calendar.startOfDay(for: today)
        let week = (0..<7).reversed().map { back -> Bool in
            calendar.date(byAdding: .day, value: -back, to: start).map { counted.contains(key($0)) } ?? false
        }
        return Result(current: runs.current, longest: runs.longest, lastWeek: week)
    }
}
