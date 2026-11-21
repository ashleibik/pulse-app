import Foundation

/// Estimated calories burned in a day, by NOOP's whole-day method (`NoopCalories`). Spec: docs/METRICS.md §9.
/// Shown in the app only.
public enum DailyCalories {
    public struct Body: Sendable, Equatable {
        public var weightKg: Double
        public var heightCm: Double
        public var age: Double
        public var sex: BiologicalSex

        public init(weightKg: Double, heightCm: Double, age: Double, sex: BiologicalSex) {
            self.weightKg = weightKg
            self.heightCm = heightCm
            self.age = age
            self.sex = sex
        }
    }

    public struct Estimate: Sendable, Equatable {
        public let total: Int
        /// What the body burns at rest over the time the band measured.
        public let resting: Int
        /// What activity added on top.
        public let active: Int
        /// How much of the day the band measured.
        public let measuredMinutes: Int
        /// true = the band measured under 90% of the day so far, so the total leaves some of it out.
        public let isPartial: Bool
    }

    /// Below this share of the day so far, the card says how much was measured.
    public static let fullCoverage = 0.90

    /// - Parameters:
    ///   - minutes: raw minutes, in any order. Minutes outside the day are ignored.
    ///   - steps: the band's counted minutes (§15). Walking under NOOP's heart-rate gate adds its ACSM cost.
    ///   - dayStart: start of the day.
    ///   - end: the end of the day, or now for a day still going.
    ///   - maxHeartRate, restingHeartRate: what "clearly raised" is measured against.
    /// - Returns: nil when the sex or resting heart rate is unknown or the band recorded nothing that day:
    ///   without data there is no estimate to show.
    public static func estimate(minutes: [MinuteSample], steps: [StepMinute] = [], body: Body, dayStart: Date, end: Date,
                                maxHeartRate: Double, restingHeartRate: Double?) -> Estimate? {
        guard body.sex != .unspecified, end > dayStart, let restingHeartRate else { return nil }
        let inDay = minutes.filter { $0.start >= dayStart && $0.start < end && $0.source != .simulated && $0.isWorn }
        guard !inDay.isEmpty,
              let energy = NoopCalories.dayEnergy(minutes: inDay, body: body, maxHeartRate: maxHeartRate,
                                                  restingHeartRate: restingHeartRate) else { return nil }
        let walking = walkingKcal(steps.filter { $0.start >= dayStart && $0.start < end }, minutes: inDay, body: body,
                                  maxHeartRate: maxHeartRate, restingHeartRate: restingHeartRate)
        let resting = Int(energy.restingKcal.rounded())
        let active = Int((energy.activeKcal + walking).rounded())
        return Estimate(total: resting + active, resting: resting, active: active,
                        measuredMinutes: Int((energy.observedSeconds / 60).rounded()),
                        isPartial: energy.observedSeconds < fullCoverage * end.timeIntervalSince(dayStart))
    }

    // MARK: - Walking (docs/METRICS.md §9)

    /// Step length in metres: the usual pedometer rule from height.
    public static func stepLength(_ body: Body) -> Double {
        let share: Double
        switch body.sex {
        case .male: share = 0.415
        case .female: share = 0.413
        case .unspecified: share = 0.414
        }
        return share * body.heightCm / 100
    }

    /// ACSM's cost of a minute of counted steps above rest, in kcal: net VO₂ of 0.1 ml/kg/min per m/min walking (0.2 running,
    /// from 140 steps a minute) at 5 kcal per litre of oxygen. Over the minute the speed cancels out: 0.0005 × steps × step
    /// length × weight walking, twice that running.
    public static func walkingKcal(_ minute: StepMinute, body: Body) -> Double {
        guard minute.steps > 0 else { return 0 }
        let perMetre = minute.cadence >= Double(Steps.runningStepsPerMinute) ? 0.2 : 0.1
        return perMetre / 1000 * 5 * Double(minute.steps) * stepLength(body) * body.weightKg
    }

    /// Walking the heart-rate method leaves out: counted minutes whose average heart rate is under NOOP's whole-day gate
    /// (resting + 50% of reserve). Minutes at or above it already count by heart rate.
    static func walkingKcal(_ steps: [StepMinute], minutes: [MinuteSample], body: Body, maxHeartRate: Double,
                            restingHeartRate: Double) -> Double {
        let gate = restingHeartRate + NoopCalories.dayActiveReserveShare * max(0, maxHeartRate - restingHeartRate)
        var heartRates: [Date: Double] = [:]
        for minute in minutes { heartRates[minute.start] = minute.averageHeartRate }
        return steps.reduce(0) { total, minute in
            if let rate = heartRates[minute.start], rate >= gate { return total }
            return total + walkingKcal(minute, body: body)
        }
    }
}

/// Which day's numbers "last night" means.
public enum LastNight {
    /// The newest day that has a night's sleep. Today's row can exist before the night has synced.
    public static func day(in days: [DailySummary]) -> DailySummary? {
        days.filter { $0.sleepMinutes != nil }.max { $0.date < $1.date }
    }
}
