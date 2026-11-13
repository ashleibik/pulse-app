import Foundation

// MARK: - Sleep timeline ("hypnogram")

/// What the sleep timeline shows. Deliberately NOT "REM/deep": HR + motion can't measure stages
/// reliably, so we show calmness instead and say so in the UI.
public enum SleepPhase: String, Sendable, CaseIterable {
    case awake, light, restful

    public var title: String {
        switch self {
        case .awake: "Awake"
        case .light: "Light"
        case .restful: "Restful"
        }
    }
}

public struct SleepSegment: Sendable, Equatable, Identifiable {
    public let start: Date
    public let end: Date
    public let phase: SleepPhase
    public var id: Date { start }
    public var minutes: Int { Int(end.timeIntervalSince(start) / 60) }
}

public enum SleepTimeline {

    /// Classifies each minute of a sleep session, then merges equal neighbours into segments.
    ///
    /// Per minute:
    ///   awake   = not worn, OR moving (the minute's own Cole-Kripke term >= 1, i.e. activity >= ~26),
    ///             OR heart rate >= the night's median + 10
    ///   restful = very still (activity < 3) AND heart rate at or below the night's median
    ///   light   = everything else
    /// Then non-awake runs shorter than 3 minutes are absorbed by their neighbour, so the chart
    /// shows the shape of the night instead of noise.
    public static func build(minutes: [MinuteSample], from start: Date, to end: Date) -> [SleepSegment] {
        let night = minutes.filter { $0.start >= start && $0.start < end }.sorted { $0.start < $1.start }
        let hrs = night.compactMap(\.averageHeartRate)
        guard !night.isEmpty, !hrs.isEmpty else { return [] }
        let median = Stats.median(hrs)
        let movingThreshold = SleepDetector.coleKripkeDivisor / SleepDetector.coleKripkeWeights[4]

        var phases: [SleepPhase] = night.map { m in
            guard let hr = m.averageHeartRate else { return .awake }
            let activity = m.averageActivity
            if activity >= movingThreshold || hr >= median + 10 { return .awake }
            return (activity < 3 && hr <= median) ? .restful : .light
        }
        phases = smooth(phases)

        var segments: [SleepSegment] = []
        var runStart = 0
        for i in 1...phases.count where i == phases.count || phases[i] != phases[runStart] {
            segments.append(SleepSegment(start: night[runStart].start,
                                         end: night[i - 1].start.addingTimeInterval(60),
                                         phase: phases[runStart]))
            runStart = i
        }
        return segments
    }

    /// Absorb restful/light runs shorter than `minRun` into the previous run (awake runs are kept).
    static func smooth(_ phases: [SleepPhase], minRun: Int = 3) -> [SleepPhase] {
        var out = phases
        var i = 0
        while i < out.count {
            var j = i
            while j < out.count && out[j] == out[i] { j += 1 }
            if out[i] != .awake && j - i < minRun && i > 0 && out[i - 1] != .awake {
                for k in i..<j { out[k] = out[i - 1] }
            }
            i = j
        }
        return out
    }

    public static func totals(_ segments: [SleepSegment]) -> [SleepPhase: Int] {
        var totals: [SleepPhase: Int] = [:]
        for s in segments { totals[s.phase, default: 0] += s.minutes }
        return totals
    }
}

// MARK: - Heart-rate zones

/// Zones as % of max heart rate: Z1 50-60, Z2 60-70, Z3 70-80, Z4 80-90, Z5 90+.
/// (A common convention, e.g. the American Heart Association's target-HR guidance.)
public enum HeartRateZones {
    public static let names = ["Very light", "Light", "Moderate", "Hard", "Maximum"]

    /// 0...4, or nil below 50% of max.
    public static func zone(for heartRate: Double, maxHeartRate: Double) -> Int? {
        let pct = heartRate / maxHeartRate
        guard pct >= 0.5 else { return nil }
        return min(4, Int((pct - 0.5) * 10))
    }

    /// Minutes spent in each zone, from per-minute average HR.
    public static func minutesPerZone(_ minuteHR: [Double?], maxHeartRate: Double) -> [Int] {
        var zones = [0, 0, 0, 0, 0]
        for hr in minuteHR {
            if let hr, let z = zone(for: hr, maxHeartRate: maxHeartRate) { zones[z] += 1 }
        }
        return zones
    }
}

// MARK: - Sleep need breakdown

/// The pieces of tonight's sleep need, for "why do I need 8h 30m?". Same formula as Recovery.sleepNeed.
public struct SleepNeedBreakdown: Sendable, Equatable {
    public let goal: Double
    public let strainExtra: Double
    public let debtExtra: Double
    public let total: Double     // capped at 600 minutes

    public init(goal: Double, previousStrain: Double?, previousNeed: Double?, previousAsleep: Double?) {
        self.goal = goal
        strainExtra = previousStrain.map { 6.0 * max(0.0, $0 - 10.0) } ?? 0
        if let n = previousNeed, let a = previousAsleep {
            debtExtra = 0.5 * max(0.0, n - a)
        } else {
            debtExtra = 0
        }
        total = Recovery.sleepNeed(goal: goal, previousStrain: previousStrain,
                                   previousNeed: previousNeed, previousAsleep: previousAsleep)
    }
}
