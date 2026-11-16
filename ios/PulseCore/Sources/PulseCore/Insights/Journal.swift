import Foundation

// Journal (habits and what they do to your recovery), period reports, and data export.

// MARK: - Journal

/// Things you can log for a day. Raw values are stored, so don't rename them.
public enum Habit: String, CaseIterable, Sendable, Codable, Hashable {
    case alcohol, lateCaffeine, lateMeal, screenInBed, stressfulDay, feltSick, hydrated, stretched

    public var title: String {
        switch self {
        case .alcohol: "Alcohol"
        case .lateCaffeine: "Late caffeine"
        case .lateMeal: "Late meal"
        case .screenInBed: "Screen in bed"
        case .stressfulDay: "Stressful day"
        case .feltSick: "Felt sick"
        case .hydrated: "Drank enough water"
        case .stretched: "Stretched"
        }
    }

    public var symbolName: String {
        switch self {
        case .alcohol: "wineglass"
        case .lateCaffeine: "cup.and.saucer"
        case .lateMeal: "fork.knife"
        case .screenInBed: "iphone"
        case .stressfulDay: "bolt"
        case .feltSick: "thermometer.medium"
        case .hydrated: "drop"
        case .stretched: "figure.flexibility"
        }
    }
}

/// What a habit did to the next morning's recovery, on average.
public struct HabitImpact: Identifiable, Sendable, Equatable {
    public let habit: Habit
    public let daysWith: Int
    public let averageWith: Double
    public let averageWithout: Double
    /// Recovery points with the habit minus without (negative = recovery was lower).
    public var delta: Double { averageWith - averageWithout }
    public var id: String { habit.rawValue }

    /// One plain line, e.g. "Recovery is 12 points lower the morning after (4 days)."
    public var sentence: String {
        let points = Int(abs(delta).rounded())
        if points < 2 { return "No clear effect on next-morning recovery so far (\(daysWith) days)." }
        return "Recovery is \(points) points \(delta < 0 ? "lower" : "higher") the morning after (\(daysWith) days)."
    }
}

public enum JournalInsights {

    /// Compares the NEXT morning's recovery on days with a habit against logged days without it.
    ///
    /// Honest limits: this is a simple average, not proof of cause. Habits often come together
    /// (alcohol and a late night), and a handful of days is a small sample. A habit is only
    /// reported once it has at least `minimum` days with and `minimum` days without.
    ///
    /// - Parameter entries: start of day -> the habits logged for that day. Only logged days count.
    public static func impacts(entries: [Date: Set<Habit>], days: [DailySummary], calendar: Calendar,
                               minimum: Int = 3) -> [HabitImpact] {
        // Recovery of the morning after each logged day.
        var nextMorning: [(habits: Set<Habit>, recovery: Double)] = []
        for (day, habits) in entries {
            guard let next = calendar.date(byAdding: .day, value: 1, to: day),
                  let summary = days.first(where: { calendar.isDate($0.date, inSameDayAs: next) }),
                  let recovery = summary.recoveryScore else { continue }
            nextMorning.append((habits, recovery))
        }
        var result: [HabitImpact] = []
        for habit in Habit.allCases {
            let with = nextMorning.filter { $0.habits.contains(habit) }.map(\.recovery)
            let without = nextMorning.filter { !$0.habits.contains(habit) }.map(\.recovery)
            guard with.count >= minimum, without.count >= minimum else { continue }
            result.append(HabitImpact(habit: habit, daysWith: with.count,
                                      averageWith: Stats.mean(with), averageWithout: Stats.mean(without)))
        }
        return result.sorted { abs($0.delta) > abs($1.delta) }
    }
}

// MARK: - Weekly / monthly report

/// A period in a few lines: averages, how they changed, best and toughest day.
public struct PeriodReport: Sendable, Equatable {
    public struct Line: Identifiable, Sendable, Equatable {
        public let label: String
        public let value: String
        public let note: String
        public var id: String { label }
    }

    public let lines: [Line]

    public static func make(days: [DailySummary], sleeps: [SleepSession], workouts: [Workout],
                            period: Int, calendar: Calendar) -> PeriodReport {
        let sorted = days.sorted { $0.date < $1.date }
        let current = Array(sorted.suffix(period))
        guard let firstDay = current.first?.date else { return PeriodReport(lines: []) }
        let before = "vs the \(period) days before"
        let whole: (Double) -> String = { String(format: "%.0f", $0) }
        let duration: (Double) -> String = { PulseFormat.duration(minutes: Int($0.rounded())) }
        let dayName: (Date) -> String = { date in
            var style = Date.FormatStyle(timeZone: calendar.timeZone)
            style.calendar = calendar
            return date.formatted(style.weekday(.wide))
        }
        var lines: [Line] = []

        let recovery = TrendInsights.compare(days, period: period, \.recoveryScore)
        if let value = recovery.current {
            lines.append(Line(label: "Recovery", value: PulseFormat.percent(value),
                              note: "\(TrendInsights.changeCaption(recovery.delta, higherIsBetter: true)) \(before)"))
        }
        let scored = current.filter { $0.recoveryScore != nil }
        if let best = scored.max(by: { ($0.recoveryScore ?? 0) < ($1.recoveryScore ?? 0) }),
           let worst = scored.min(by: { ($0.recoveryScore ?? 0) < ($1.recoveryScore ?? 0) }), scored.count >= 2 {
            lines.append(Line(label: "Best day", value: PulseFormat.percent(best.recoveryScore ?? 0), note: dayName(best.date)))
            lines.append(Line(label: "Toughest day", value: PulseFormat.percent(worst.recoveryScore ?? 0), note: dayName(worst.date)))
        }

        let sleep = TrendInsights.compare(days, period: period) { $0.sleepMinutes.map { Double($0) } }
        if let value = sleep.current {
            lines.append(Line(label: "Sleep per night", value: duration(value),
                              note: "\(TrendInsights.changeCaption(sleep.delta, higherIsBetter: true, format: duration)) \(before)"))
        }
        let nights = sleeps.filter { $0.end >= firstDay }
        if let consistency = SleepConsistency.score(nights, calendar: calendar) {
            lines.append(Line(label: "Sleep consistency", value: PulseFormat.percent(consistency),
                              note: "how regular your bed and wake times were"))
        }

        let strain = TrendInsights.compare(days, period: period) { $0.strain }
        if let value = strain.current {
            lines.append(Line(label: "Strain per day", value: PulseFormat.strain(value),
                              note: recovery.current.map { _ in "of 21" } ?? "of 21"))
        }
        let done = workouts.filter { $0.start >= firstDay }
        let minutes = done.reduce(0) { $0 + $1.durationMinutes }
        lines.append(Line(label: "Workouts", value: "\(done.count)",
                          note: done.isEmpty ? "none in this period" : "\(PulseFormat.duration(minutes: minutes)) in total"))

        let hrv = TrendInsights.compare(days, period: period, \.hrvRMSSD)
        if let value = hrv.current {
            lines.append(Line(label: "HRV", value: "\(whole(value)) ms",
                              note: "\(TrendInsights.changeCaption(hrv.delta, higherIsBetter: true)) \(before)"))
        }
        let resting = TrendInsights.compare(days, period: period, \.restingHeartRate)
        if let value = resting.current {
            lines.append(Line(label: "Resting heart rate", value: "\(whole(value)) bpm",
                              note: "\(TrendInsights.changeCaption(resting.delta, higherIsBetter: false)) \(before)"))
        }
        return PeriodReport(lines: lines)
    }
}

// MARK: - Export

/// "Export my data": everything Pulse has worked out, as one readable JSON file.
/// (Raw heartbeats are not included: a month of them is tens of megabytes.)
public enum DataExport {
    struct JournalDay: Encodable {
        let day: String
        let habits: [String]
    }

    struct File: Encodable {
        let app: String
        let exported_at: String
        let algorithm_version: Int
        let days: [CloudRows.Day]
        let sleep_sessions: [CloudRows.Sleep]
        let workouts: [CloudRows.WorkoutRow]
        let journal: [JournalDay]
    }

    public static func json(days: [DailySummary], sleeps: [SleepSession], workouts: [Workout],
                            journal: [Date: Set<Habit>], calendar: Calendar, now: Date) throws -> Data {
        let dayString: (Date) -> String = { date in
            let c = calendar.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        }
        let file = File(
            app: "Pulse",
            exported_at: StravaExport.iso(now),
            algorithm_version: MetricsEngine.algorithmVersion,
            days: days.sorted { $0.date < $1.date }.map { CloudRows.day($0, calendar: calendar) },
            sleep_sessions: sleeps.sorted { $0.start < $1.start }.map(CloudRows.sleep),
            workouts: workouts.sorted { $0.start < $1.start }.map(CloudRows.workout),
            journal: journal.keys.sorted().map { key in
                JournalDay(day: dayString(key), habits: (journal[key] ?? []).map(\.rawValue).sorted())
            })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(file)
    }
}
