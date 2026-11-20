import Foundation

/// An estimate of VO₂ max (ml/kg/min) without an exercise test, as NOOP makes it (docs/METRICS.md §16).
/// A trend to watch over weeks, not a lab measurement.
public enum VO2Max {
    /// Nights with a resting heart rate, of the last 7, before there is a number.
    public static let fewestNights = NoopFitness.minCoverageDays

    public enum Method: String, Sendable, Equatable {
        /// Uth 2004: 15.3 × max heart rate ÷ resting heart rate.
        case heartRates
        /// Nes 2011 (HUNT): age, sex, waist, resting heart rate and the week's activity.
        case nonExercise
    }

    public struct Estimate: Sendable, Equatable {
        public var value: Double
        public var method: Method
        /// ± the model's standard error, for the Nes model. nil for Uth, which NOOP gives none for.
        public var standardError: Double?
        /// The median of the week's resting heart rates.
        public var restingHeartRate: Double
        /// Nights with a resting heart rate in the week.
        public var nights: Int
        /// The week's activity index (0 to 15), for the Nes model.
        public var activityIndex: Double?
    }

    /// The estimate for the 7 days ending on `day`. nil with fewer than 4 nights of resting heart rate.
    /// - Parameters:
    ///   - waistCm: with an age and a sex, the Nes model is used; without, Uth's.
    public static func estimate(days: [DailySummary], workouts: [Workout], on day: Date, calendar: Calendar,
                                maxHeartRate: Double, age: Double?, sex: BiologicalSex, waistCm: Double?) -> Estimate? {
        let last = calendar.startOfDay(for: day)
        guard let first = calendar.date(byAdding: .day, value: -6, to: last),
              let after = calendar.date(byAdding: .day, value: 1, to: last) else { return nil }
        let week = days.filter { $0.date >= first && $0.date < after }
        let rates = week.compactMap(\.restingHeartRate).filter { $0 > 0 }
        guard rates.count >= NoopFitness.minCoverageDays else { return nil }
        let resting = Stats.median(rates)

        if let waistCm, waistCm > 0, let age, age > 0, sex != .unspecified {
            let index = activityIndex(workouts.filter { $0.start >= first && $0.start < after && $0.isSuggestion != true },
                                      calendar: calendar)
            return Estimate(value: NoopFitness.estimateVO2max(age: age, sex: sex, waistCm: waistCm, restingHR: resting, paIndex: index),
                            method: .nonExercise, standardError: NoopFitness.standardError(sex), restingHeartRate: resting,
                            nights: rates.count, activityIndex: index)
        }
        return Estimate(value: NoopCalories.vo2max(maxHeartRate: maxHeartRate, restingHeartRate: resting), method: .heartRates,
                        standardError: nil, restingHeartRate: resting, nights: rates.count, activityIndex: nil)
    }

    /// NOOP's HUNT activity index from the week's workouts: days with a workout, their average minutes, and the
    /// share of heart-rate-zone time in zones 4 and 5.
    static func activityIndex(_ workouts: [Workout], calendar: Calendar) -> Double {
        let activeDays = Set(workouts.map { calendar.startOfDay(for: $0.start) }).count
        guard activeDays > 0 else { return 0 }
        let minutes = Double(workouts.reduce(0) { $0 + $1.durationMinutes }) / Double(activeDays)
        let zoned = workouts.reduce(0) { $0 + $1.zoneSeconds.reduce(0, +) }
        let hard = workouts.reduce(0) { $0 + $1.zoneSeconds.dropFirst(3).reduce(0, +) }
        return NoopFitness.physicalActivityIndex(activeDaysPerWeek: activeDays, avgActiveMinutesPerDay: minutes,
                                                 highIntensityFraction: zoned > 0 ? Double(hard) / Double(zoned) : 0)
    }
}
