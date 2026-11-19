import Foundation

// MARK: - Sleep timeline ("hypnogram")

/// What the sleep timeline shows, from the top of the chart. REM, light and deep are estimates (`NoopSleepStager`).
public enum SleepPhase: String, Sendable, CaseIterable {
    case awake, rem, light, deep

    public var title: String {
        switch self {
        case .awake: "Awake"
        case .rem: "REM"
        case .light: "Light"
        case .deep: "Deep"
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
    /// How far around a sleep `build` needs minutes: the stager's heart-rate windows reach past both ends.
    public static let stagingPadding: TimeInterval = 7 * 60
    /// A wake-up lasts at least this many minutes. A shorter awake stretch between sleeping minutes counts as asleep.
    public static let shortestWake = 3

    /// One phase per minute of a sleep. This is the only place that decides which minutes of a sleep
    /// count as awake, so the night's headline numbers and its phases always add up to the same total.
    ///
    /// Per minute:
    ///   nil     = no band data: unknown, neither asleep nor awake
    ///   awake   = moving, OR heart rate >= the night's median + 10
    ///   light   = asleep. `build` then picks out the deep and REM minutes among them.
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
                    run.append(.light)
                }
                end += 1
            }
            for (offset, phase) in smooth(run).enumerated() { out[i + offset] = phase }
            i = end
        }
        return out
    }

    /// The night as segments. Minutes with no band data belong to no segment.
    /// - Parameter minutes: the night, and `stagingPadding` either side of it for the best stages.
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
        var phases = SleepTimeline.phases(hr: hr, movement: movement)
        let stages = stagesPerMinute(minutes: minutes, from: start, to: end, count: count)
        for index in phases.indices where phases[index] == .light {
            switch stages[index] {
            case .deep: phases[index] = .deep
            case .rem: phases[index] = .rem
            default: break                              // Pulse's own rule decides who is awake
            }
        }
        // A stage lasting a minute or two joins the one before it. Only sleeping minutes swap, so the totals stay.
        phases = smoothRuns(phases)

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

    /// NOOP's stage for each minute: the stage of its first 30 seconds. A minute with no epoch keeps the stage before it.
    private static func stagesPerMinute(minutes: [MinuteSample], from start: Date, to end: Date, count: Int) -> [NoopSleepStager.Stage?] {
        let first = Int(start.timeIntervalSince1970)
        let epochs = NoopSleepStager.stage(start: first, end: Int(end.timeIntervalSince1970),
                                           input: NoopSleepStager.input(from: minutes))
        var stages = [NoopSleepStager.Stage?](repeating: nil, count: count)
        for epoch in epochs {
            let index = (epoch.start - first) / 60
            if stages.indices.contains(index), stages[index] == nil { stages[index] = epoch.stage }
        }
        var previous = epochs.first?.stage
        for index in stages.indices {
            if let stage = stages[index] { previous = stage } else { stages[index] = previous }
        }
        return stages
    }

    /// `smooth` on each stretch of minutes with data.
    static func smoothRuns(_ phases: [SleepPhase?]) -> [SleepPhase?] {
        var out = phases
        var i = 0
        while i < out.count {
            guard out[i] != nil else { i += 1; continue }
            var end = i
            while end < out.count, out[end] != nil { end += 1 }
            let run = smooth(out[i..<end].compactMap { $0 })
            for (offset, phase) in run.enumerated() { out[i + offset] = phase }
            i = end
        }
        return out
    }

    /// First, an awake stretch shorter than `shortestWake` with sleep on both sides becomes light sleep.
    /// Then a sleeping run shorter than `minRun` joins the run before it, unless that run is awake.
    static func smooth(_ phases: [SleepPhase], minRun: Int = 3) -> [SleepPhase] {
        var out = phases
        var i = 0
        while i < out.count {
            var j = i
            while j < out.count && out[j] == out[i] { j += 1 }
            if out[i] == .awake && j - i < shortestWake && i > 0 && j < out.count {
                for k in i..<j { out[k] = .light }
            }
            i = j
        }
        i = 0
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

    /// Times to label under a night chart: the start and the end, and whole hours between them that leave room for the labels.
    /// Every 2 hours on a night over 4 hours, otherwise every hour.
    public static func axisTimes(from start: Date, to end: Date, calendar: Calendar) -> [Date] {
        guard end > start else { return [start] }
        let length = end.timeIntervalSince(start)
        let step: TimeInterval = length > 4 * 3600 ? 7200 : 3600
        let room = max(0.18 * length, 20 * 60)
        guard var hour = calendar.dateInterval(of: .hour, for: start.addingTimeInterval(room))?.start else { return [start, end] }
        if hour < start.addingTimeInterval(room) { hour = hour.addingTimeInterval(3600) }
        var times = [start]
        while hour <= end.addingTimeInterval(-room) {
            times.append(hour)
            hour = hour.addingTimeInterval(step)
        }
        return times + [end]
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
