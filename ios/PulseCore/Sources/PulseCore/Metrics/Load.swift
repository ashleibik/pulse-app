import Foundation

public enum BiologicalSex: String, Codable, Sendable, CaseIterable {
    case male, female, unspecified
}

/// Strain (0-21). Spec: docs/METRICS.md §5.
public enum Strain {
    public static let minHeartRateReserve = 0.2   // our choice: ignore everyday low-intensity minutes
    public static let k = 130.0                   // our choice: hard 60-min run (HRr 0.8) ~= 14
    public static let maximum = 21.0

    /// Banister TRIMP coefficients (Morton, Fitz-Clarke & Banister 1990). Unspecified uses the male set.
    static func coefficients(_ sex: BiologicalSex) -> (a: Double, b: Double) {
        sex == .female ? (0.86, 1.67) : (0.64, 1.92)
    }

    /// Training impulse from per-minute mean HR (nil = no reading, skipped).
    public static func trimp(_ minuteHR: [Double?], resting: Double, maximum maxHR: Double,
                             sex: BiologicalSex = .unspecified) -> Double {
        let (a, b) = coefficients(sex)
        let reserve = maxHR - resting
        guard reserve > 0 else { return 0 }
        var total = 0.0
        for hr in minuteHR {
            guard let hr else { continue }
            var x = (hr - resting) / reserve
            if x < minHeartRateReserve { continue }
            x = min(x, 1.0)
            total += x * a * exp(b * x)
        }
        return total
    }

    public static func fromTRIMP(_ trimp: Double) -> Double {
        maximum * (1.0 - exp(-trimp / k))
    }

    /// Tanaka, Monahan & Seals 2001: 208 - 0.7 x age.
    public static func estimatedMaxHeartRate(age: Double) -> Double {
        208.0 - 0.7 * age
    }
}

/// Sleep need and recovery. Spec: docs/METRICS.md §6-7.
public enum Recovery {
    public static let minimumBaselineNights = 4

    public static func sleepNeed(goal: Double, previousStrain: Double?, previousNeed: Double?,
                                 previousAsleep: Double?) -> Double {
        var need = goal
        if let s = previousStrain { need += 6.0 * max(0.0, s - 10.0) }
        if let n = previousNeed, let a = previousAsleep { need += 0.5 * max(0.0, n - a) }
        return min(need, 600.0)
    }

    /// The need after naps: what they slept is taken off, down to 0. Swift only, on top of the shared formula (docs/METRICS.md §6).
    public static func needAfterNaps(_ need: Double, napMinutes: Double) -> Double {
        max(0, need - max(0, napMinutes))
    }

    /// Minutes asleep in the naps that ended after `after` and no later than `upTo`.
    public static func napMinutes(_ sleeps: [SleepSession], after: Date, upTo: Date) -> Int {
        sleeps.filter { $0.isNap && $0.end > after && $0.end <= upTo }.reduce(0) { $0 + $1.asleepMinutes }
    }

    /// 0-100 recovery score, or nil if there's no HRV/RHR tonight or fewer than 4 baseline nights.
    public static func score(hrv: Double?, rhr: Double?, sleepMinutes: Double?, need: Double,
                             baselineHRV: [Double], baselineRHR: [Double]) -> Double? {
        components(hrv: hrv, rhr: rhr, sleepMinutes: sleepMinutes, need: need,
                   baselineHRV: baselineHRV, baselineRHR: baselineRHR)?.score
    }

    /// The three z-scores behind a recovery score (so the UI can show *why*).
    public static func components(hrv: Double?, rhr: Double?, sleepMinutes: Double?, need: Double,
                                  baselineHRV: [Double], baselineRHR: [Double]) -> RecoveryComponents? {
        guard let hrv, let rhr,
              baselineHRV.count >= minimumBaselineNights, baselineRHR.count >= minimumBaselineNights
        else { return nil }

        let lnBase = baselineHRV.map { log($0) }
        let zHRV = (log(hrv) - Stats.mean(lnBase)) / max(Stats.sampleSD(lnBase), 0.05)
        let zRHR = (rhr - Stats.mean(baselineRHR)) / max(Stats.sampleSD(baselineRHR), 1.0)
        var ratio = 0.0
        if let sleepMinutes, need > 0 { ratio = min(sleepMinutes / need, 1.1) }
        let zSleep = Stats.clamp((ratio - 0.9) / 0.1, -3.0, 2.0)
        return RecoveryComponents(zHRV: zHRV, zRHR: zRHR, zSleep: zSleep)
    }
}

/// z-scores: how far tonight is from YOUR normal, in units of your usual night-to-night variation.
public struct RecoveryComponents: Sendable, Equatable {
    public let zHRV: Double     // + is good
    public let zRHR: Double     // + is bad (heart working harder at rest)
    public let zSleep: Double   // + is good

    /// Weighted sum (docs/METRICS.md §7). Same expression as the spec, so results match Python exactly.
    public var composite: Double { 0.6 * zHRV - 0.25 * zRHR + 0.15 * zSleep }

    public var score: Double { Stats.clamp(100.0 * Stats.phi(composite), 1.0, 99.0) }

    /// Score points each factor adds compared with that factor being exactly at your normal.
    /// (They don't add up exactly to the score because the curve isn't a straight line, but the
    /// signs and sizes are what matter for "why did it change".)
    public var hrvPoints: Double { points(withoutPart: 0.6 * zHRV) }
    public var restingHRPoints: Double { points(withoutPart: -0.25 * zRHR) }
    public var sleepPoints: Double { points(withoutPart: 0.15 * zSleep) }

    private func points(withoutPart part: Double) -> Double {
        100.0 * Stats.phi(composite) - 100.0 * Stats.phi(composite - part)
    }
}
