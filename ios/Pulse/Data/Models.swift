import Foundation
import SwiftData
import PulseCore

// SwiftData models: what's saved on the phone.
//
// Pattern: PulseCore has plain value types (MinuteSample, SleepSession, ...) that are easy to test.
// Each @Model below stores one of them. The app converts with `init(_:)` and `.value`.
// Enums are stored as raw strings (`sourceRaw`, `kindRaw`) because SwiftData can't filter on
// custom enum types in predicates.

// MARK: - Raw data

/// One minute of band data (60 HR values + RR intervals + 60 activity values), packed into bytes.
@Model
final class MinuteRecord {
    @Attribute(.unique) var start: Date
    var heartRate: Data       // 60 bytes, 1 per second, 0 = no reading
    var rrIntervals: Data     // UInt16 little-endian, ms
    var activity: Data        // 60 bytes
    var sourceRaw: String

    init(_ sample: MinuteSample) {
        start = sample.start
        heartRate = Data(sample.heartRate)
        rrIntervals = BinaryCoding.encode(sample.rrIntervalsMs)
        activity = Data(sample.activity)
        sourceRaw = sample.source.rawValue
    }

    var value: MinuteSample {
        MinuteSample(start: start, heartRate: [UInt8](heartRate),
                     rrIntervalsMs: BinaryCoding.decodeUInt16(rrIntervals),
                     activity: [UInt8](activity), source: DataSource(rawValue: sourceRaw) ?? .history)
    }
}

// MARK: - Derived data

@Model
final class SleepRecord {
    @Attribute(.unique) var id: UUID
    var start: Date
    var end: Date
    var asleepMinutes: Int
    var awakeMinutes: Int
    var disturbances: Int
    var isNap: Bool
    var sourceRaw: String

    init(_ s: SleepSession) {
        id = s.id
        start = s.start
        end = s.end
        asleepMinutes = s.asleepMinutes
        awakeMinutes = s.awakeMinutes
        disturbances = s.disturbances
        isNap = s.isNap
        sourceRaw = s.source.rawValue
    }

    var value: SleepSession {
        SleepSession(id: id, start: start, end: end, asleepMinutes: asleepMinutes, awakeMinutes: awakeMinutes,
                     disturbances: disturbances, isNap: isNap, source: DataSource(rawValue: sourceRaw) ?? .history)
    }
}

@Model
final class WorkoutRecord {
    @Attribute(.unique) var id: UUID
    var kindRaw: String
    var start: Date
    var end: Date
    var averageHeartRate: Int
    var maxHeartRate: Int
    var strain: Double
    var zoneSeconds: [Int]
    var calories: Int
    var sourceRaw: String
    // Filled in by later phases:
    var healthKitID: UUID?          // Phase 6
    var stravaActivityID: Int?      // Phase 7

    init(_ w: Workout) {
        id = w.id
        kindRaw = w.kind.rawValue
        start = w.start
        end = w.end
        averageHeartRate = w.averageHeartRate
        maxHeartRate = w.maxHeartRate
        strain = w.strain
        zoneSeconds = w.zoneSeconds
        calories = w.calories
        sourceRaw = w.source.rawValue
    }

    var kind: WorkoutKind { WorkoutKind(rawValue: kindRaw) ?? .other }
    var durationMinutes: Int { Int(end.timeIntervalSince(start) / 60) }
}

@Model
final class DaySummaryRecord {
    @Attribute(.unique) var date: Date
    var recoveryScore: Double?
    var strain: Double
    var sleepMinutes: Int?
    var sleepNeedMinutes: Int
    var restingHeartRate: Double?
    var hrvRMSSD: Double?
    var baselineRestingHeartRate: Double?
    var baselineHRV: Double?
    var explanation: String
    var sourceRaw: String
    /// Which version of the metrics engine produced this. Lets us recompute old days when a
    /// formula improves (Phase 3+), without mixing old and new results.
    var algorithmVersion: Int

    init(_ s: DailySummary, algorithmVersion: Int = 0) {
        date = s.date
        recoveryScore = s.recoveryScore
        strain = s.strain
        sleepMinutes = s.sleepMinutes
        sleepNeedMinutes = s.sleepNeedMinutes
        restingHeartRate = s.restingHeartRate
        hrvRMSSD = s.hrvRMSSD
        baselineRestingHeartRate = s.baselineRestingHeartRate
        baselineHRV = s.baselineHRV
        explanation = s.explanation
        sourceRaw = s.source.rawValue
        self.algorithmVersion = algorithmVersion
    }

    var zone: RecoveryZone? { recoveryScore.map(RecoveryZone.init(score:)) }
    var isSimulated: Bool { sourceRaw == DataSource.simulated.rawValue }

    /// Plain value for PulseCore's insight functions.
    var value: DailySummary {
        DailySummary(date: date, recoveryScore: recoveryScore, strain: strain, sleepMinutes: sleepMinutes,
                     sleepNeedMinutes: sleepNeedMinutes, restingHeartRate: restingHeartRate, hrvRMSSD: hrvRMSSD,
                     baselineRestingHeartRate: baselineRestingHeartRate, baselineHRV: baselineHRV,
                     explanation: explanation, source: DataSource(rawValue: sourceRaw) ?? .history)
    }
}

// MARK: - Device, profile, debug

/// The paired band (Phase 5 fills this in).
@Model
final class BandRecord {
    /// CoreBluetooth's per-phone identifier for the peripheral (the band's MAC is random, so we don't use it).
    @Attribute(.unique) var peripheralID: UUID
    var name: String
    var firmwareVersion: String?
    var lastSeenAt: Date?
    var lastHistorySyncAt: Date?
    var batteryPercent: Double?
    var isCharging: Bool

    init(peripheralID: UUID, name: String) {
        self.peripheralID = peripheralID
        self.name = name
        isCharging = false
    }
}

/// The few personal details the formulas need. Stored only on this phone.
@Model
final class ProfileRecord {
    var birthYear: Int?
    var maxHeartRateOverride: Int?
    var sleepGoalMinutes: Int
    var sexRaw: String = BiologicalSex.unspecified.rawValue

    init(sleepGoalMinutes: Int = 480) {
        self.sleepGoalMinutes = sleepGoalMinutes
    }

    var sex: BiologicalSex {
        get { BiologicalSex(rawValue: sexRaw) ?? .unspecified }
        set { sexRaw = newValue.rawValue }
    }

    /// Max HR: your override, else estimated from age (Tanaka 2001), else 190.
    func estimatedMaxHeartRate(now: Date = .now, calendar: Calendar = .current) -> Double {
        if let override = maxHeartRateOverride { return Double(override) }
        if let year = birthYear {
            let age = Double(calendar.component(.year, from: now) - year)
            return Strain.estimatedMaxHeartRate(age: age)
        }
        return 190
    }

    var metricsProfile: MetricsProfile {
        MetricsProfile(maxHeartRate: estimatedMaxHeartRate(), sex: sex, sleepGoalMinutes: Double(sleepGoalMinutes))
    }
}

enum ProfileStore {
    /// The single profile row, created on first use.
    @MainActor
    static func current(in context: ModelContext) -> ProfileRecord {
        if let existing = try? context.fetch(FetchDescriptor<ProfileRecord>()).first { return existing }
        let profile = ProfileRecord()
        context.insert(profile)
        try? context.save()
        return profile
    }
}

/// Raw packets for the hidden Debug screen (Phase 5). Kept as a small ring buffer.
@Model
final class PacketRecord {
    var timestamp: Date
    var characteristic: String
    var hex: String
    var typeName: String

    init(timestamp: Date, characteristic: String, hex: String, typeName: String) {
        self.timestamp = timestamp
        self.characteristic = characteristic
        self.hex = hex
        self.typeName = typeName
    }
}
