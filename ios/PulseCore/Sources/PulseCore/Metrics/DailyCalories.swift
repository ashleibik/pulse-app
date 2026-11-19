import Foundation

/// Estimated calories burned in a day. Spec: docs/METRICS.md §9. Shown in the app only.
///
/// Every minute costs at least your resting rate (Mifflin-St Jeor). Only a minute at or above 40% of your
/// heart-rate reserve counts as active (`OpenStrapCalories`). Keytel was built from exercise data, so
/// it is not used for everyday heart rates.
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
        /// What the body burns at rest over the time counted.
        public let resting: Int
        /// What activity added on top.
        public let active: Int
    }

    /// Resting calories per day. Both formulas differ by sex, so nil when it isn't set.
    /// Mifflin MD et al., Am J Clin Nutr 1990;51:241-247.
    public static func restingPerDay(_ body: Body) -> Double? {
        let base = 10 * body.weightKg + 6.25 * body.heightCm - 5 * body.age
        switch body.sex {
        case .male: return base + 5
        case .female: return base - 161
        case .unspecified: return nil
        }
    }

    /// Calories per minute at a heart rate. Keytel LR et al., J Sports Sci 2005;23:289-297.
    public static func keytelPerMinute(heartRate: Double, body: Body) -> Double? {
        let kilojoules: Double
        switch body.sex {
        case .male:
            kilojoules = -55.0969 + 0.6309 * heartRate + 0.1988 * body.weightKg + 0.2017 * body.age
        case .female:
            kilojoules = -20.4022 + 0.4472 * heartRate - 0.1263 * body.weightKg + 0.074 * body.age
        case .unspecified:
            return nil
        }
        return kilojoules / 4.184
    }

    /// - Parameters:
    ///   - minutes: raw minutes, in any order. Minutes outside the day are ignored.
    ///   - dayStart: start of the day.
    ///   - end: the end of the day, or now for a day still going.
    ///   - maxHeartRate, restingHeartRate: what "clearly raised" is measured against.
    /// - Returns: nil when the sex or resting heart rate is unknown or the band recorded nothing that day:
    ///   without data there is no estimate to show.
    public static func estimate(minutes: [MinuteSample], body: Body, dayStart: Date, end: Date, maxHeartRate: Double,
                                restingHeartRate: Double?) -> Estimate? {
        guard let perDay = restingPerDay(body), end > dayStart else { return nil }
        let inDay = minutes.filter { $0.start >= dayStart && $0.start < end && $0.source != .simulated && $0.isWorn }
        guard !inDay.isEmpty else { return nil }
        let restingPerMinute = perDay / 1440
        let resting = restingPerMinute * end.timeIntervalSince(dayStart) / 60
        guard let restingHeartRate,
              let active = OpenStrapCalories.dailyActive(minuteHeartRates: inDay.map(\.averageHeartRate), body: body, basalPerMinute: restingPerMinute,
                                                         maxHeartRate: maxHeartRate, restingHeartRate: restingHeartRate) else { return nil }
        let restingWhole = Int(resting.rounded())
        let activeWhole = Int(active.rounded())
        return Estimate(total: restingWhole + activeWhole, resting: restingWhole, active: activeWhole)
    }
}

/// Which day's numbers "last night" means.
public enum LastNight {
    /// The newest day that has a night's sleep. Today's row can exist before the night has synced.
    public static func day(in days: [DailySummary]) -> DailySummary? {
        days.filter { $0.sleepMinutes != nil }.max { $0.date < $1.date }
    }
}
