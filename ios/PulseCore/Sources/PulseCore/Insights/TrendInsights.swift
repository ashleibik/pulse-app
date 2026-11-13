import Foundation

/// Average of a metric this period vs the period before (e.g. this week vs last week).
public struct PeriodComparison: Sendable, Equatable {
    public let current: Double?
    public let previous: Double?
    public var delta: Double? {
        guard let current, let previous else { return nil }
        return current - previous
    }
}

/// A short, plain-language observation for the Trends screen.
public struct Insight: Identifiable, Sendable, Equatable {
    public enum Tone: String, Sendable { case positive, neutral, caution }
    public let id: String
    public let title: String
    public let detail: String
    public let symbolName: String
    public let tone: Tone
}

public enum TrendInsights {

    /// `days` in any order. Compares the last `period` days with the `period` days before them.
    public static func compare(_ days: [DailySummary], period: Int,
                               _ value: (DailySummary) -> Double?) -> PeriodComparison {
        let sorted = days.sorted { $0.date < $1.date }
        let current = sorted.suffix(period)
        let previous = sorted.dropLast(period).suffix(period)
        func avg(_ slice: ArraySlice<DailySummary>) -> Double? {
            let values = slice.compactMap(value)
            return values.isEmpty ? nil : Stats.mean(values)
        }
        return PeriodComparison(current: avg(current), previous: avg(previous))
    }

    /// Up to four observations, most useful first. Needs at least 14 days with recovery data
    /// for the comparisons to mean anything; otherwise returns a single "keep going" note.
    public static func insights(_ days: [DailySummary]) -> [Insight] {
        let sorted = days.sorted { $0.date < $1.date }
        guard sorted.filter({ $0.recoveryScore != nil }).count >= 14 else {
            return [Insight(id: "learning", title: "Building your trends",
                            detail: "Insights appear after two weeks of recovery data. Keep wearing your band, including at night.",
                            symbolName: "hourglass", tone: .neutral)]
        }
        var out: [Insight] = []

        // 1. Sleep -> recovery
        let scored = sorted.filter { $0.recoveryScore != nil && $0.sleepMinutes != nil }
        let longNights = scored.filter { $0.sleepMinutes! >= 420 }.map { $0.recoveryScore! }
        let shortNights = scored.filter { $0.sleepMinutes! < 420 }.map { $0.recoveryScore! }
        if longNights.count >= 3 && shortNights.count >= 3 {
            let a = Stats.mean(longNights), b = Stats.mean(shortNights)
            if a - b >= 5 {
                out.append(Insight(id: "sleep-recovery", title: "Sleep pays off",
                                   detail: "Your recovery averages \(PulseFormat.percent(a)) after 7+ hours of sleep, vs \(PulseFormat.percent(b)) after shorter nights.",
                                   symbolName: "bed.double.fill", tone: .positive))
            }
        }

        // 2. HRV this week vs last week
        let hrv = compare(sorted, period: 7, \.hrvRMSSD)
        if let c = hrv.current, let p = hrv.previous, p > 0 {
            let pct = Int(((c / p - 1) * 100).rounded())
            if pct >= 5 {
                out.append(Insight(id: "hrv-trend", title: "HRV is rising",
                                   detail: "Your average HRV is up \(pct)% this week vs last week, a sign your body is adapting well.",
                                   symbolName: "arrow.up.right", tone: .positive))
            } else if pct <= -5 {
                out.append(Insight(id: "hrv-trend", title: "HRV is dipping",
                                   detail: "Your average HRV is down \(-pct)% this week vs last week. Stress, poor sleep, alcohol or hard training can all do this.",
                                   symbolName: "arrow.down.right", tone: .caution))
            }
        }

        // 3. Resting HR this week vs last week
        let rhr = compare(sorted, period: 7, \.restingHeartRate)
        if let d = rhr.delta {
            let bpm = Int(d.rounded())
            if bpm >= 2 {
                out.append(Insight(id: "rhr-trend", title: "Resting heart rate is up",
                                   detail: "It's \(bpm) bpm higher than last week. If it keeps climbing, take it easy: it can be an early sign of fatigue or illness.",
                                   symbolName: "heart.fill", tone: .caution))
            } else if bpm <= -2 {
                out.append(Insight(id: "rhr-trend", title: "Resting heart rate is down",
                                   detail: "It's \(-bpm) bpm lower than last week, usually a sign of good recovery or improving fitness.",
                                   symbolName: "heart.fill", tone: .positive))
            }
        }

        // 4. Load vs recovery balance over the last week
        let week = sorted.suffix(7)
        let strainAvg = Stats.mean(week.map(\.strain))
        let recoveryValues = week.compactMap(\.recoveryScore)
        if !recoveryValues.isEmpty {
            let recoveryAvg = Stats.mean(recoveryValues)
            if strainAvg >= 13 && recoveryAvg < 45 {
                out.append(Insight(id: "balance", title: "Lots of load, not much recovery",
                                   detail: "This week averaged strain \(PulseFormat.strain(strainAvg)) with recovery \(PulseFormat.percent(recoveryAvg)). An easier day could help you bounce back.",
                                   symbolName: "exclamationmark.triangle.fill", tone: .caution))
            } else if strainAvg < 8 && recoveryAvg >= 60 {
                out.append(Insight(id: "balance", title: "Room to push",
                                   detail: "Recovery has been good (\(PulseFormat.percent(recoveryAvg))) while strain stayed light (\(PulseFormat.strain(strainAvg))). You could add a harder session.",
                                   symbolName: "bolt.fill", tone: .positive))
            }
        }

        if out.isEmpty {
            out.append(Insight(id: "steady", title: "Steady week",
                               detail: "No big changes compared with last week. Consistency is exactly what builds fitness.",
                               symbolName: "checkmark.seal.fill", tone: .neutral))
        }
        return Array(out.prefix(4))
    }
}
