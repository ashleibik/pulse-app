import Foundation
import SwiftData
import PulseCore

/// Steps for the screens, from the stored band data. The counting is PulseCore's `Steps` (docs/METRICS.md §15).
@MainActor
enum StepsData {
    /// Pulse's count for each reference, kept until its band data could still change (the last two days).
    private static var cache: [UUID: (key: String, checked: Steps.Checked)] = [:]

    /// The resting heart rate Pulse knew for a day.
    static func restingHeartRate(on date: Date, days: [DaySummaryRecord], calendar: Calendar = .current) -> Double? {
        days.first { calendar.isDate($0.date, inSameDayAs: date) }.flatMap { $0.restingHeartRate ?? $0.baselineRestingHeartRate }
    }

    /// Each reference with Pulse's own count for the same time.
    static func checked(_ references: [Steps.Reference], sleeps: [SleepSession], days: [DaySummaryRecord], maxHeartRate: Double,
                        context: ModelContext, calendar: Calendar = .current, now: Date = .now) -> [Steps.Checked] {
        references.map { reference in
            let settled = reference.end < now.addingTimeInterval(-2 * 86_400)
            let key = "\(reference.kind.rawValue)-\(reference.start.timeIntervalSince1970)-\(reference.end.timeIntervalSince1970)-\(reference.steps)-\(maxHeartRate)"
            if settled, let hit = cache[reference.id], hit.key == key { return hit.checked }
            let end = min(reference.end, now)
            let minutes = PulseStore.minutes(from: reference.start.addingTimeInterval(-60), to: end.addingTimeInterval(60), in: context)
            let resting = restingHeartRate(on: reference.start, days: days, calendar: calendar)
            let result: Steps.Checked
            switch reference.kind {
            case .stepTest:
                let counted = Steps.window(minutes: minutes, sleeps: sleeps, from: reference.start, to: end,
                                           restingHeartRate: resting, maxHeartRate: maxHeartRate)
                result = Steps.Checked(reference: reference, uncalibrated: counted.coverage > 0 ? counted.steps : nil,
                                       coverage: counted.coverage)
            case .appleWatchDay:
                let day = Steps.day(minutes: minutes, sleeps: sleeps, dayStart: reference.start, end: end, calendar: calendar,
                                    restingHeartRate: resting, maxHeartRate: maxHeartRate)
                let length = max(1, end.timeIntervalSince(reference.start) / 60)
                result = Steps.Checked(reference: reference, uncalibrated: day?.uncalibrated,
                                       coverage: Double(day?.measuredMinutes ?? 0) / length)
            }
            if settled { cache[reference.id] = (key, result) }
            return result
        }
    }

    /// A day's steps after the personal factor. nil without band data that day.
    static func day(_ day: Date, sleeps: [SleepSession], days: [DaySummaryRecord], maxHeartRate: Double, factor: Steps.Factor,
                    context: ModelContext, calendar: Calendar = .current, now: Date = .now) -> Steps.Day? {
        let start = calendar.startOfDay(for: day)
        let end = min(calendar.date(byAdding: .day, value: 1, to: start) ?? start, now)
        guard end > start else { return nil }
        let minutes = PulseStore.minutes(from: start.addingTimeInterval(-60), to: end.addingTimeInterval(60), in: context)
        return Steps.day(minutes: minutes, sleeps: sleeps, dayStart: start, end: end, calendar: calendar,
                         restingHeartRate: restingHeartRate(on: start, days: days, calendar: calendar),
                         maxHeartRate: maxHeartRate, factor: factor.value)
    }

    /// "Not checked yet", "From 2 step tests", "From 1 step test and 3 Apple Watch days".
    static func calibrationText(_ factor: Steps.Factor) -> String {
        guard factor.isCalibrated else { return "Not checked yet" }
        var parts: [String] = []
        if factor.stepTests > 0 { parts.append("\(factor.stepTests) step test\(factor.stepTests == 1 ? "" : "s")") }
        if factor.appleWatchDays > 0 { parts.append("\(factor.appleWatchDays) Apple Watch day\(factor.appleWatchDays == 1 ? "" : "s")") }
        return "From " + parts.joined(separator: " and ")
    }

    /// "+3.2%" / "−6.0%": one decimal, never rounded to a whole number.
    static func percent(_ difference: Double) -> String {
        let value = difference * 100
        return (value >= 0 ? "+" : "−") + String(format: "%.1f%%", abs(value))
    }
}
