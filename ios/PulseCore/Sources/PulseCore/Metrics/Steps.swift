import Foundation

/// Steps the band counted on its 100 Hz motion stream (docs/METRICS.md §15), and the owner's step tests.
///
/// Steps are counted, never estimated: time without the stream counts no steps, and `Day.countedMinutes` says how long the band
/// counted.
public enum Steps {
    /// A minute with at least this many steps is walking (about one step a second).
    public static let walkingStepsPerMinute = 60
    /// A minute with at least this many steps is running.
    public static let runningStepsPerMinute = 140

    public struct Day: Sendable, Equatable {
        public var total: Int
        /// Steps in each hour of the day, from its start (24 hours, or 23 or 25 on a clock change).
        public var hourly: [Int]
        /// How long the band sent its motion that day.
        public var countedMinutes: Int
    }

    /// A day's steps. nil when the band never counted that day.
    /// - Parameters:
    ///   - minutes: counted minutes, any order. Minutes outside the day are ignored.
    ///   - end: the end of the day, or now for a day still going.
    public static func day(_ minutes: [StepMinute], dayStart: Date, end: Date, calendar: Calendar) -> Day? {
        let inDay = minutes.filter { $0.start >= dayStart && $0.start < end }
        guard !inDay.isEmpty else { return nil }
        let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
        let hours = max(1, Int((nextDay.timeIntervalSince(dayStart) / 3600).rounded()))
        var hourly = [Int](repeating: 0, count: hours)
        for minute in inDay {
            let hour = Int(minute.start.timeIntervalSince(dayStart) / 3600)
            if hour >= 0 && hour < hours { hourly[hour] += minute.steps }
        }
        let seconds = inDay.reduce(0) { $0 + $1.seconds }
        return Day(total: inDay.reduce(0) { $0 + $1.steps }, hourly: hourly,
                   countedMinutes: Int((Double(seconds) / 60).rounded()))
    }

    // MARK: - Step tests

    /// A count the band is checked against. `appleWatchDay` entries come from earlier versions: they are kept in backups but
    /// no longer used.
    public struct Reference: Codable, Equatable, Sendable, Identifiable {
        public enum Kind: String, Codable, Sendable { case stepTest, appleWatchDay }
        public var id: UUID
        public var kind: Kind
        public var start: Date
        public var end: Date
        /// The owner's own count.
        public var steps: Int
        public var createdAt: Date
        /// A step test: the band's 100 Hz count of the same walk. nil when the stream sent nothing.
        public var liveSteps: Int?

        public init(id: UUID = UUID(), kind: Kind, start: Date, end: Date, steps: Int, createdAt: Date, liveSteps: Int? = nil) {
            self.id = id
            self.kind = kind
            self.start = start
            self.end = end
            self.steps = steps
            self.createdAt = createdAt
            self.liveSteps = liveSteps
        }

        /// (band − yours) ÷ yours, for a step test with a band count.
        public var difference: Double? {
            guard kind == .stepTest, let liveSteps, steps > 0 else { return nil }
            return Double(liveSteps - steps) / Double(steps)
        }
    }

    /// The average size of the differences of the step tests that have one. nil without any.
    public static func averageDifference(_ references: [Reference]) -> Double? {
        let differences = references.compactMap(\.difference).map(abs)
        guard !differences.isEmpty else { return nil }
        return differences.reduce(0, +) / Double(differences.count)
    }
}
