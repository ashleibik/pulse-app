import Foundation

// MARK: - Recovery

/// Traffic-light bands for recovery. Same thresholds as common recovery apps:
/// 67-100 green, 34-66 yellow, 0-33 red.
public enum RecoveryZone: String, Codable, Sendable, CaseIterable {
    case green, yellow, red

    public init(score: Double) {
        switch score {
        case 67...: self = .green
        case 34..<67: self = .yellow
        default: self = .red
        }
    }

    /// Short plain-language label for the Home screen.
    public var headline: String {
        switch self {
        case .green: "Ready to push"
        case .yellow: "Take it steady"
        case .red: "Prioritise rest"
        }
    }
}

// MARK: - Sleep

public struct SleepSession: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    public var start: Date            // fell asleep (or got into bed, if we can't tell)
    public var end: Date              // woke up for the day
    public var asleepMinutes: Int
    public var awakeMinutes: Int      // awake time inside the session
    public var disturbances: Int      // number of times you woke up
    public var isNap: Bool
    public var source: DataSource

    public init(id: UUID = UUID(), start: Date, end: Date, asleepMinutes: Int, awakeMinutes: Int,
                disturbances: Int, isNap: Bool = false, source: DataSource) {
        self.id = id
        self.start = start
        self.end = end
        self.asleepMinutes = asleepMinutes
        self.awakeMinutes = awakeMinutes
        self.disturbances = disturbances
        self.isNap = isNap
        self.source = source
    }

    public var inBedMinutes: Int { Int(end.timeIntervalSince(start) / 60) }

    /// Fraction of time in bed actually spent asleep (0...1).
    public var efficiency: Double {
        inBedMinutes > 0 ? Double(asleepMinutes) / Double(inBedMinutes) : 0
    }
}

// MARK: - Workouts

public enum WorkoutKind: String, Codable, Sendable, CaseIterable {
    case run, ride, strength, walk, hiit, other

    public var displayName: String {
        switch self {
        case .run: "Run"
        case .ride: "Ride"
        case .strength: "Strength"
        case .walk: "Walk"
        case .hiit: "HIIT"
        case .other: "Workout"
        }
    }

    /// SF Symbol name. Just a string here, so PulseCore stays UI-free.
    public var symbolName: String {
        switch self {
        case .run: "figure.run"
        case .ride: "figure.outdoor.cycle"
        case .strength: "dumbbell.fill"
        case .walk: "figure.walk"
        case .hiit: "flame.fill"
        case .other: "heart.fill"
        }
    }
}

public struct Workout: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    public var kind: WorkoutKind
    public var start: Date
    public var end: Date
    public var averageHeartRate: Int
    public var maxHeartRate: Int
    /// 0...21 scale (see Phase 3 for the formula).
    public var strain: Double
    /// Seconds spent in HR zones 1-5 (by % of max HR: 50-60, 60-70, 70-80, 80-90, 90+).
    public var zoneSeconds: [Int]
    /// Rough estimate. Labelled "approx." in the UI.
    public var calories: Int
    public var source: DataSource

    public init(id: UUID = UUID(), kind: WorkoutKind, start: Date, end: Date, averageHeartRate: Int,
                maxHeartRate: Int, strain: Double, zoneSeconds: [Int], calories: Int, source: DataSource) {
        self.id = id
        self.kind = kind
        self.start = start
        self.end = end
        self.averageHeartRate = averageHeartRate
        self.maxHeartRate = maxHeartRate
        self.strain = strain
        self.zoneSeconds = zoneSeconds
        self.calories = calories
        self.source = source
    }

    public var durationMinutes: Int { Int(end.timeIntervalSince(start) / 60) }
}

// MARK: - Daily summary

/// Everything the Home screen needs for one calendar day.
/// A "day" owns the sleep that ENDED on its morning.
public struct DailySummary: Identifiable, Codable, Sendable, Hashable {
    public var date: Date                 // start of the calendar day
    public var recoveryScore: Double?     // 0...100, nil if no sleep data
    public var strain: Double             // 0...21
    public var sleepMinutes: Int?
    public var sleepNeedMinutes: Int
    public var restingHeartRate: Double?
    public var hrvRMSSD: Double?          // ms, from the night's sleep
    public var baselineRestingHeartRate: Double?
    public var baselineHRV: Double?
    /// One or two plain-language sentences: why the numbers are what they are.
    public var explanation: String
    public var source: DataSource

    public init(date: Date, recoveryScore: Double?, strain: Double, sleepMinutes: Int?, sleepNeedMinutes: Int,
                restingHeartRate: Double?, hrvRMSSD: Double?, baselineRestingHeartRate: Double?,
                baselineHRV: Double?, explanation: String, source: DataSource) {
        self.date = date
        self.recoveryScore = recoveryScore
        self.strain = strain
        self.sleepMinutes = sleepMinutes
        self.sleepNeedMinutes = sleepNeedMinutes
        self.restingHeartRate = restingHeartRate
        self.hrvRMSSD = hrvRMSSD
        self.baselineRestingHeartRate = baselineRestingHeartRate
        self.baselineHRV = baselineHRV
        self.explanation = explanation
        self.source = source
    }

    public var id: Date { date }
    public var recoveryZone: RecoveryZone? { recoveryScore.map(RecoveryZone.init(score:)) }
}
