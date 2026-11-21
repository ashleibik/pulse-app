import Foundation
import SwiftData
import PulseCore

/// Steps for the screens: the minutes the band counted on its 100 Hz stream (docs/METRICS.md §15).
@MainActor
enum StepsData {
    /// Counted minutes in [from, to), oldest first.
    static func minutes(from start: Date, to end: Date, in context: ModelContext) -> [StepMinute] {
        let descriptor = FetchDescriptor<StepMinuteRecord>(
            predicate: #Predicate<StepMinuteRecord> { record in record.start >= start && record.start < end },
            sortBy: [SortDescriptor(\.start)]
        )
        return ((try? context.fetch(descriptor)) ?? []).map(\.value)
    }

    /// A day's steps. nil when the band never counted that day.
    static func day(_ day: Date, context: ModelContext, calendar: Calendar = .current, now: Date = .now) -> Steps.Day? {
        let start = calendar.startOfDay(for: day)
        let end = min(calendar.date(byAdding: .day, value: 1, to: start) ?? start, now)
        guard end > start else { return nil }
        return Steps.day(minutes(from: start, to: end, in: context), dayStart: start, end: end, calendar: calendar)
    }

    /// A day's steps with the minute the stream is filling (BandManager.stepsInProgress), so the cards move while you walk.
    static func live(_ day: Steps.Day?, dayStart: Date, band: BandManager, calendar: Calendar = .current) -> Steps.Day? {
        let inProgress = band.stepsInProgressMinute.map { StepMinute(start: $0, steps: band.stepsInProgress, seconds: 0) }
        return Steps.day(day, adding: inProgress, dayStart: calendar.startOfDay(for: dayStart), calendar: calendar)
    }

    /// "Counted for 9h 12m".
    static func countedText(_ day: Steps.Day) -> String {
        "Counted for \(PulseFormat.duration(minutes: day.countedMinutes))"
    }

    /// The line for a day the band never counted.
    static let notCountedText = "The band counts steps while it streams its motion to your iPhone."

    /// Why the band isn't counting right now (DESIGN.md §4b-8). nil while it counts.
    static func pausedText(_ decision: MotionStreamPolicy.Decision?, connected: Bool) -> String? {
        switch decision {
        case .stream: nil
        case .asleep: "Paused while you sleep."
        case .notWorn: "Paused: the band isn't on your wrist."
        case .lowBattery: "Paused: the band's battery is low."
        case nil: connected ? "Waiting for the band…" : "Not counting: the band isn't connected."
        }
    }

    /// "+3.2%" / "−6.0%": one decimal, never rounded to a whole number.
    static func percent(_ difference: Double) -> String {
        let value = difference * 100
        return (value >= 0 ? "+" : "−") + String(format: "%.1f%%", abs(value))
    }
}
