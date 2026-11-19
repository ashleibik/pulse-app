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
    ///   - dayStart: start of the day.
    ///   - end: the end of the day, or now for a day still going.
    ///   - maxHeartRate, restingHeartRate: what "clearly raised" is measured against.
    /// - Returns: nil when the sex or resting heart rate is unknown or the band recorded nothing that day:
    ///   without data there is no estimate to show.
    public static func estimate(minutes: [MinuteSample], body: Body, dayStart: Date, end: Date, maxHeartRate: Double,
                                restingHeartRate: Double?) -> Estimate? {
        guard body.sex != .unspecified, end > dayStart, let restingHeartRate else { return nil }
        let inDay = minutes.filter { $0.start >= dayStart && $0.start < end && $0.source != .simulated && $0.isWorn }
        guard !inDay.isEmpty,
              let energy = NoopCalories.dayEnergy(minutes: inDay, body: body, maxHeartRate: maxHeartRate,
                                                  restingHeartRate: restingHeartRate) else { return nil }
        let resting = Int(energy.restingKcal.rounded())
        let active = Int(energy.activeKcal.rounded())
        return Estimate(total: resting + active, resting: resting, active: active,
                        measuredMinutes: Int((energy.observedSeconds / 60).rounded()),
                        isPartial: energy.observedSeconds < fullCoverage * end.timeIntervalSince(dayStart))
    }
}

/// Which day's numbers "last night" means.
public enum LastNight {
    /// The newest day that has a night's sleep. Today's row can exist before the night has synced.
    public static func day(in days: [DailySummary]) -> DailySummary? {
        days.filter { $0.sleepMinutes != nil }.max { $0.date < $1.date }
    }
}
