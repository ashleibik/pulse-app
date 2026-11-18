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

    /// A minute with this much movement (`MinuteSample.movement`) is awake.
    public static let awakeMovement = 6.0
    /// A minute with less movement than this can be restful.
    public static let restfulMovement = 1.0

    /// One phase per minute of a sleep. This is the only place that decides which minutes of a sleep
    /// count as awake, so the night's headline numbers and its phases always add up to the same total.
    ///
    /// Per minute:
    ///   nil     = no band data: unknown, neither asleep nor awake
    ///   awake   = moving, OR heart rate >= the night's median + 10
    ///   restful = very still AND heart rate at or below the night's median
    ///   light   = everything else
    /// Then non-awake runs shorter than 3 minutes are absorbed by their neighbour, so the chart
    /// shows the shape of the night instead of noise.
    public static func phases(hr: [Double?], movement: [Double?]) -> [SleepPhase?] {
        let rates = hr.compactMap { $0 }
        guard !rates.isEmpty else { return hr.map { _ in nil } }
        let median = Stats.median(rates)
        var out = [SleepPhase?](repeating: nil, count: hr.count)
        var i = 0
        while i < hr.count {
            guard hr[i] != nil, movement[i] != nil else { i += 1; continue }
            var end = i
            var run: [SleepPhase] = []
            while end < hr.count, let rate = hr[end], let moved = movement[end] {
                if moved >= awakeMovement || rate >= median + 10 {
                    run.append(.awake)
                } else {
                    run.append((moved < restfulMovement && rate <= median) ? .restful : .light)
                }
                end += 1
            }
            for (offset, phase) in smooth(run).enumerated() { out[i + offset] = phase }
            i = end
        }
        return out
    }

    /// The night as segments. Minutes with no band data belong to no segment.
    public static func build(minutes: [MinuteSample], from start: Date, to end: Date) -> [SleepSegment] {
        let count = Int((end.timeIntervalSince(start) / 60).rounded(.up))
        guard count > 0 else { return [] }
        var hr = [Double?](repeating: nil, count: count)
        var movement = [Double?](repeating: nil, count: count)
        for minute in minutes where minute.start >= start && minute.start < end && minute.isWorn {
            let index = Int(minute.start.timeIntervalSince(start) / 60)
            hr[index] = minute.averageHeartRate
            movement[index] = minute.movement
        }
        guard hr.contains(where: { $0 != nil }) else { return [] }
        let phases = SleepTimeline.phases(hr: hr, movement: movement)

        var segments: [SleepSegment] = []
        var runStart = 0
        for i in 1...count where i == count || phases[i] != phases[runStart] {
            if let phase = phases[runStart] {
                segments.append(SleepSegment(start: start.addingTimeInterval(Double(runStart) * 60),
                                             end: min(end, start.addingTimeInterval(Double(i) * 60)),
                                             phase: phase))
            }
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
