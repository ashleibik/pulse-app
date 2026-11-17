import Foundation
@testable import PulseCore

// TEST SUPPORT ONLY.

/// A test month: SIMULATED raw minutes, but every summary is computed by the REAL engine.
/// (The generator's own "truth" summaries are only used by tests.)
public enum DemoData {
    public static func make(config: FakeDataConfig, profile: MetricsProfile = MetricsProfile(),
                            calendar: Calendar) -> FakeDataset {
        let raw = FakeDataGenerator.generate(config)
        let result = MetricsEngine.run(minutes: raw.minutes, profile: profile, calendar: calendar, now: config.endDate)
        let workouts = raw.workouts.map { workout -> Workout in
            var w = workout
            let rest = result.days.first { calendar.isDate($0.date, inSameDayAs: w.start) }?.restingHeartRate ?? 55
            w.strain = MetricsEngine.strain(of: raw.minutes, from: w.start, to: w.end, restingHR: rest, profile: profile)
            return w
        }
        return FakeDataset(minutes: config.includeMinuteSamples ? raw.minutes : [],
                           sleeps: result.sleeps, workouts: workouts, days: result.days)
    }
}
