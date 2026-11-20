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
    /// 60 bytes: how far the wrist turned each second. nil on minutes saved before Pulse stored this.
    var wristAngle: Data?

    init(_ sample: MinuteSample) {
        wristAngle = sample.wristAngle.map { Data($0) }
        start = sample.start
        heartRate = Data(sample.heartRate)
        rrIntervals = BinaryCoding.encode(sample.rrIntervalsMs)
        activity = Data(sample.activity)
        sourceRaw = sample.source.rawValue
    }

    /// Adds band data to a minute that is already stored. Needed because a history batch can end
    /// in the middle of a minute (the next batch brings the other seconds), and because the band
    /// sends a batch again if our ack got lost. A second with a reading wins over one without.
    func merge(_ sample: MinuteSample) {
        var hr = [UInt8](heartRate)
        var movement = [UInt8](activity)
        let count = min(min(hr.count, movement.count), min(sample.heartRate.count, sample.activity.count))
        for second in 0..<count where sample.heartRate[second] > 0 {
            hr[second] = sample.heartRate[second]
            movement[second] = sample.activity[second]
        }
        heartRate = Data(hr)
        activity = Data(movement)
        if !sample.rrIntervalsMs.isEmpty {
            rrIntervals = BinaryCoding.encode(BinaryCoding.decodeUInt16(rrIntervals) + sample.rrIntervalsMs)
        }
        wristAngle = WristAngle.merged(existing: wristAngle.map { [UInt8]($0) }, incoming: sample.wristAngle).map { Data($0) }
        sourceRaw = sample.source.rawValue
    }

    var value: MinuteSample {
        MinuteSample(start: start, heartRate: [UInt8](heartRate),
                     rrIntervalsMs: BinaryCoding.decodeUInt16(rrIntervals),
                     activity: [UInt8](activity), source: DataSource(rawValue: sourceRaw) ?? .history,
                     wristAngle: wristAngle.map { [UInt8]($0) })
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
    /// Why Pulse asks "Is this right?" about this sleep. nil = nothing to ask.
    var reviewReasonRaw: String?

    init(_ s: SleepSession) {
        id = s.id
        start = s.start
        end = s.end
        asleepMinutes = s.asleepMinutes
        awakeMinutes = s.awakeMinutes
        disturbances = s.disturbances
        isNap = s.isNap
        sourceRaw = s.source.rawValue
        reviewReasonRaw = s.reviewReason?.rawValue
    }

    var value: SleepSession {
        SleepSession(id: id, start: start, end: end, asleepMinutes: asleepMinutes, awakeMinutes: awakeMinutes,
                     disturbances: disturbances, isNap: isNap, source: DataSource(rawValue: sourceRaw) ?? .history,
                     reviewReason: reviewReasonRaw.flatMap(SleepReviewReason.init(rawValue:)))
    }
}

/// A sleep the user edited or said wasn't sleep. Sleeps are rebuilt from the raw minutes on every
/// recalculation, so the user's word is kept here and applied on top each time.
@Model
final class SleepCorrectionRecord {
    @Attribute(.unique) var id: UUID
    var detectedStart: Date
    var detectedEnd: Date
    var start: Date?
    var end: Date?
    var createdAt: Date

    init(_ c: SleepCorrection) {
        id = c.id
        detectedStart = c.detectedStart
        detectedEnd = c.detectedEnd
        start = c.start
        end = c.end
        createdAt = c.createdAt
    }

    var value: SleepCorrection {
        SleepCorrection(id: id, detectedStart: detectedStart, detectedEnd: detectedEnd, start: start, end: end,
                        createdAt: createdAt)
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
    var healthKitID: UUID?          // no longer used; kept so existing installs and backups still load
    var stravaActivityID: Int?      // unused: Strava's ids are not stored (its 7-day cache rule)
    /// When Pulse sent this workout to Strava (Phase 7). Our own mark, not Strava data.
    var stravaUploadedAt: Date?
    /// true = "Was this a walk?" hasn't been answered yet.
    var isSuggestion: Bool?

    init(_ w: Workout) {
        isSuggestion = w.isSuggestion
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
    var isSimulated: Bool { sourceRaw == DataSource.simulated.rawValue }

    var value: Workout {
        Workout(id: id, kind: kind, start: start, end: end, averageHeartRate: averageHeartRate,
                maxHeartRate: maxHeartRate, strain: strain, zoneSeconds: zoneSeconds, calories: calories,
                source: DataSource(rawValue: sourceRaw) ?? .history, isSuggestion: isSuggestion)
    }
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

/// One day of the habit journal (Today > Journal). A day with a record but no habits means
/// "none of these happened", which is information too.
@Model
final class JournalRecord {
    @Attribute(.unique) var day: Date       // start of the day
    var habitsRaw: [String]

    init(day: Date, habits: Set<Habit>) {
        self.day = day
        habitsRaw = habits.map(\.rawValue)
    }

    var habits: Set<Habit> {
        get { Set(habitsRaw.compactMap(Habit.init(rawValue:))) }
        set { habitsRaw = newValue.map(\.rawValue).sorted() }
    }
}

/// The few personal details the formulas need. Stored only on this phone.
@Model
final class ProfileRecord {
    var birthYear: Int?
    var maxHeartRateOverride: Int?
    var sleepGoalMinutes: Int
    var sexRaw: String = BiologicalSex.unspecified.rawValue
    /// For the calorie estimate. nil = not entered (no estimate is shown).
    var weightKg: Double?
    var heightCm: Double?
    /// Daily step goal (Settings > Steps).
    var stepGoal: Int = 10_000
    /// Optional. With it, VO₂ max uses the Nes model instead of heart rates alone (docs/METRICS.md §16).
    var waistCm: Double?

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

    /// Years this calendar year, from the birth year. nil when not entered.
    func age(now: Date = .now, calendar: Calendar = .current) -> Double? {
        birthYear.map { Double(calendar.component(.year, from: now) - $0) }
    }

    var metricsProfile: MetricsProfile {
        MetricsProfile(maxHeartRate: estimatedMaxHeartRate(), sex: sex, sleepGoalMinutes: Double(sleepGoalMinutes))
    }

    /// What the calorie estimate needs. nil until all of it has been entered: nothing is guessed.
    func calorieBody(now: Date = .now, calendar: Calendar = .current) -> DailyCalories.Body? {
        guard let weightKg, let heightCm, let birthYear, sex != .unspecified else { return nil }
        return DailyCalories.Body(weightKg: weightKg, heightCm: heightCm,
                                  age: Double(calendar.component(.year, from: now) - birthYear), sex: sex)
    }
}

/// A count the step estimate is checked against: a step test counted by hand, or an Apple Watch day total
/// (docs/METRICS.md §15). The user's own entries, so "Delete all band data" keeps them.
@Model
final class StepReferenceRecord {
    @Attribute(.unique) var id: UUID
    var kindRaw: String
    var start: Date
    var end: Date
    var steps: Int
    var createdAt: Date

    init(_ r: Steps.Reference) {
        id = r.id
        kindRaw = r.kind.rawValue
        start = r.start
        end = r.end
        steps = r.steps
        createdAt = r.createdAt
    }

    var value: Steps.Reference {
        Steps.Reference(id: id, kind: Steps.Reference.Kind(rawValue: kindRaw) ?? .stepTest, start: start, end: end, steps: steps,
                        createdAt: createdAt)
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
