import Foundation

/// One reason behind today's recovery score, e.g. "HRV: 68 ms vs your normal 61 ms, +12 points".
public struct RecoveryFactor: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable { case hrv, restingHeartRate, sleep }

    public let kind: Kind
    public let title: String
    public let detail: String
    /// Score points this factor added (negative = it pulled the score down).
    public let points: Double

    public var id: String { kind.rawValue }
}

public struct RecoveryBreakdown: Sendable, Equatable {
    public let components: RecoveryComponents
    public let factors: [RecoveryFactor]   // biggest effect first
}

/// Rebuilds the "why" behind a stored daily summary.
public enum RecoveryExplainer {

    /// - Parameters:
    ///   - day: the day to explain.
    ///   - history: other stored days (any order). The 14 days before `day` become the baseline,
    ///     the same rule the engine uses.
    public static func breakdown(for day: DailySummary, history: [DailySummary]) -> RecoveryBreakdown? {
        let previous = history.filter { $0.date < day.date }.sorted { $0.date < $1.date }
            .suffix(MetricsEngine.baselineDays)
        let baseHRV = previous.compactMap(\.hrvRMSSD)
        let baseRHR = previous.compactMap(\.restingHeartRate)
        guard let hrv = day.hrvRMSSD, let rhr = day.restingHeartRate,
              let c = Recovery.components(hrv: hrv, rhr: rhr, sleepMinutes: day.sleepMinutes.map { Double($0) },
                                          need: Double(day.sleepNeedMinutes),
                                          baselineHRV: baseHRV, baselineRHR: baseRHR)
        else { return nil }

        let normalHRV = Stats.mean(baseHRV)
        let normalRHR = Stats.mean(baseRHR)
        var factors = [
            RecoveryFactor(kind: .hrv, title: "Heart rate variability",
                           detail: comparison(hrv, normalHRV, unit: "ms"),
                           points: c.hrvPoints),
            RecoveryFactor(kind: .restingHeartRate, title: "Resting heart rate",
                           detail: comparison(rhr, normalRHR, unit: "bpm"),
                           points: c.restingHRPoints),
            RecoveryFactor(kind: .sleep, title: "Sleep",
                           detail: day.sleepMinutes.map {
                               "\(PulseFormat.duration(minutes: $0)) of the \(PulseFormat.duration(minutes: day.sleepNeedMinutes)) you needed"
                           } ?? "No sleep recorded",
                           points: c.sleepPoints),
        ]
        factors.sort { abs($0.points) > abs($1.points) }
        return RecoveryBreakdown(components: c, factors: factors)
    }

    /// One short line for the Today screen: the single biggest reason behind the score.
    /// (Design rule: one line per metric, details behind a tap.)
    /// - Parameter breakdown: `nil` while there is no baseline yet.
    public static func oneLine(_ breakdown: RecoveryBreakdown?) -> String {
        guard let top = breakdown?.factors.first else { return "Still learning your normal." }
        // Under 3 points nothing really stands out.
        guard abs(top.points) >= 3 else { return "Everything is close to your normal." }
        let helped = top.points > 0
        switch top.kind {
        case .hrv: return helped ? "HRV is above your normal." : "HRV is below your normal."
        case .restingHeartRate:
            // Lower resting HR is the good direction.
            return helped ? "Resting HR is below your normal." : "Resting HR is above your normal."
        case .sleep: return helped ? "You slept as much as you needed." : "You slept less than you needed."
        }
    }

    /// "68 ms vs your normal 61 ms". If both round to the same whole number, show one decimal
    /// ("53.6 bpm vs your normal 54.4 bpm"); otherwise "54 vs 54, +3 points" looks like a contradiction.
    /// (Found in the first real screenshots.)
    static func comparison(_ value: Double, _ normal: Double, unit: String) -> String {
        if Int(value.rounded()) == Int(normal.rounded()) && abs(value - normal) >= 0.05 {
            return String(format: "%.1f %@ vs your normal %.1f %@", value, unit, normal, unit)
        }
        return "\(Int(value.rounded())) \(unit) vs your normal \(Int(normal.rounded())) \(unit)"
    }
}

/// How hard to go today, given recovery. Our own heuristic (docs/METRICS.md): the better recovered,
/// the more load your body can absorb and adapt to.
public enum StrainGuidance {

    public static func targetRange(recovery: Double?) -> ClosedRange<Double> {
        guard let recovery else { return 8...12 }        // no baseline yet: something moderate
        switch RecoveryZone(score: recovery) {
        case .green: return 14...18
        case .yellow: return 10...14
        case .red: return 0...10
        }
    }

    public enum Status: Sendable, Equatable { case below, onTarget, above }

    public static func status(strain: Double, target: ClosedRange<Double>) -> Status {
        if strain < target.lowerBound { return .below }
        if strain > target.upperBound { return .above }
        return .onTarget
    }

    /// One plain-language line for the Today screen.
    public static func advice(strain: Double, recovery: Double?) -> String {
        let target = targetRange(recovery: recovery)
        let range = "\(Int(target.lowerBound))–\(Int(target.upperBound))"
        let state = status(strain: strain, target: target)
        // Red day: the whole message is "rest", until you go past the limit.
        if target.lowerBound == 0 && state != .above {
            return "Rest is the goal today. Keep strain under \(Int(target.upperBound))."
        }
        switch state {
        case .below:
            return "Aim for a strain of \(range) today."
        case .onTarget:
            return "You're in today's target range (\(range)). Nicely balanced."
        case .above:
            return "You're past today's target (\(range)). Prioritise sleep tonight."
        }
    }
}
