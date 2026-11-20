import Foundation

/// How well a night went, 0-100, from four parts the sleep page shows one by one.
///
/// Pulse's own formula (documented here, not WHOOP's):
///   score = weighted mean of the parts that are known:
///           hours vs needed x 0.6, sleep efficiency x 0.2, sleep consistency x 0.2.
///   Sleep stress is shown next to it but not scored (it is a rough estimate).
/// Each part also gets a level (poor / sufficient / optimal) for the three-step indicator.
public struct SleepPerformance: Sendable, Equatable {
    public enum Level: Int, Sendable, CaseIterable { case poor, sufficient, optimal }

    /// Time asleep / sleep need, capped at 100.
    public let hoursVsNeeded: Double
    /// Time asleep / time in bed. nil if the night has no length.
    public let efficiency: Double?
    /// Same bed and wake times as your recent nights (SleepConsistency). nil with fewer than 3 nights.
    public let consistency: Double?
    /// Share of the classified sleep minutes with a high stress level. Lower is better. nil = unknown.
    public let sleepStress: Double?
    public let score: Double

    public static func make(asleepMinutes: Int, awakeMinutes: Int, needMinutes: Int,
                            consistency: Double?, sleepStress: Double? = nil) -> SleepPerformance {
        let hours = needMinutes > 0 ? min(100, 100 * Double(asleepMinutes) / Double(needMinutes)) : 0
        let inBed = asleepMinutes + awakeMinutes
        let efficiency = inBed > 0 ? 100 * Double(asleepMinutes) / Double(inBed) : nil
        var parts: [(value: Double, weight: Double)] = [(hours, 0.6)]
        if let efficiency { parts.append((efficiency, 0.2)) }
        if let consistency { parts.append((consistency, 0.2)) }
        let weight = parts.reduce(0) { $0 + $1.weight }
        let score = parts.reduce(0) { $0 + $1.value * $1.weight } / weight
        return SleepPerformance(hoursVsNeeded: hours, efficiency: efficiency, consistency: consistency,
                                sleepStress: sleepStress, score: score)
    }

    public static func hoursLevel(_ value: Double) -> Level { value >= 85 ? .optimal : value >= 70 ? .sufficient : .poor }
    public static func efficiencyLevel(_ value: Double) -> Level { value >= 90 ? .optimal : value >= 80 ? .sufficient : .poor }
    public static func consistencyLevel(_ value: Double) -> Level { value >= 80 ? .optimal : value >= 65 ? .sufficient : .poor }
    /// Lower is better.
    public static func stressLevel(_ value: Double) -> Level { value <= 5 ? .optimal : value <= 15 ? .sufficient : .poor }
    public static func scoreLevel(_ value: Double) -> Level { value >= 85 ? .optimal : value >= 70 ? .sufficient : .poor }

    /// % of the night's still minutes that classify as high stress (StressMonitor rules).
    public static func sleepStress(minutes: [MinuteSample], restingHR: Double, maxHR: Double) -> Double? {
        let levels = minutes.compactMap { StressMonitor.level(for: $0, restingHR: restingHR, maxHR: maxHR) }
        guard levels.count >= 30 else { return nil }
        return 100 * Double(levels.filter { $0 == .high }.count) / Double(levels.count)
    }
}

/// Restorative sleep: deep + REM, the stages the body and brain recover in (docs/METRICS.md §12). Shown next to the
/// sleep performance, not part of its score. The credit is NOOP's restorative sub-score (`NoopRestorative`).
public struct RestorativeSleep: Sendable, Equatable {
    /// Deep + REM.
    public let minutes: Int
    /// (deep + REM) ÷ asleep, 0...1.
    public let share: Double
    /// 0...1: the share against 50%, scaled down (to half at most) when deep is under 13% of the sleep.
    public let credit: Double

    /// Pulse's three steps over NOOP's credit: optimal from 0.8 (40% restorative with enough deep), sufficient from 0.6.
    public var level: SleepPerformance.Level { credit >= 0.8 ? .optimal : credit >= 0.6 ? .sufficient : .poor }

    /// nil without minutes asleep.
    public static func make(deepMinutes: Int, remMinutes: Int, asleepMinutes: Int) -> RestorativeSleep? {
        guard asleepMinutes > 0 else { return nil }
        let restorative = deepMinutes + remMinutes
        let credit = NoopRestorative.score(restorativeSeconds: Double(restorative * 60), deepSeconds: Double(deepMinutes * 60),
                                           tstSeconds: Double(asleepMinutes * 60))
        return RestorativeSleep(minutes: restorative, share: Double(restorative) / Double(asleepMinutes), credit: credit)
    }

    /// From a night's stage totals (`SleepTimeline.totals`).
    public static func make(totals: [SleepPhase: Int]) -> RestorativeSleep? {
        let deep = totals[.deep] ?? 0, rem = totals[.rem] ?? 0
        return make(deepMinutes: deep, remMinutes: rem, asleepMinutes: deep + rem + (totals[.light] ?? 0))
    }
}

/// "Within your range": is today's value inside your usual night-to-night spread?
public enum HealthMonitor {
    /// - Parameters:
    ///   - history: previous values (e.g. the last 30 days), today excluded.
    ///   - minSpread: smallest band around the average (so a very steady history isn't too strict).
    /// - Returns: nil with fewer than 3 earlier values (no range yet).
    public static func withinRange(_ today: Double, history: [Double], minSpread: Double) -> Bool? {
        guard history.count >= 3 else { return nil }
        let mean = Stats.mean(history)
        let spread = max(minSpread, 1.5 * Stats.sampleSD(history))
        return abs(today - mean) <= spread
    }
}
