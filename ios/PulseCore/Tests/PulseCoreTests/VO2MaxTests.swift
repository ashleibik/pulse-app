import Foundation
import Testing
@testable import PulseCore

// VO₂ max (docs/METRICS.md §16). NOOP's own known values first, then Pulse's week.

@Test func noopNesKnownValues() {
    // NOOP FitnessAgeEngineTests: 100.27 − 0.296·40 + 0.226·5 − 0.369·90 − 0.155·65 = 46.275
    #expect(abs(NoopFitness.estimateVO2max(age: 40, sex: .male, waistCm: 90, restingHR: 65, paIndex: 5) - 46.275) < 1e-3)
    // 74.74 − 0.247·40 + 0.198·5 − 0.259·80 − 0.114·65 = 37.72
    #expect(abs(NoopFitness.estimateVO2max(age: 40, sex: .female, waistCm: 80, restingHR: 65, paIndex: 5) - 37.72) < 1e-3)
    // Unspecified uses the men's model, as NOOP does.
    #expect(NoopFitness.estimateVO2max(age: 40, sex: .unspecified, waistCm: 90, restingHR: 65, paIndex: 5)
            == NoopFitness.estimateVO2max(age: 40, sex: .male, waistCm: 90, restingHR: 65, paIndex: 5))
}

@Test func noopActivityIndexBuckets() {
    #expect(NoopFitness.physicalActivityIndex(activeDaysPerWeek: 0, avgActiveMinutesPerDay: 0, highIntensityFraction: 0) == 0)
    #expect(NoopFitness.physicalActivityIndex(activeDaysPerWeek: 7, avgActiveMinutesPerDay: 75, highIntensityFraction: 0.8) == 15)
    #expect(abs(NoopFitness.physicalActivityIndex(activeDaysPerWeek: 3, avgActiveMinutesPerDay: 40, highIntensityFraction: 0.3) - 3.75) < 1e-9)
}

private var calendar: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(secondsFromGMT: 0)!
    return c
}

private let today = Date(timeIntervalSince1970: 1_750_032_000)

private func days(_ rates: [Double?]) -> [DailySummary] {
    // rates[0] is today, rates[1] yesterday, ...
    rates.enumerated().map { index, rate in
        DailySummary(date: calendar.date(byAdding: .day, value: -index, to: today)!, recoveryScore: nil, strain: 8,
                     sleepMinutes: 450, sleepNeedMinutes: 480, restingHeartRate: rate, hrvRMSSD: nil,
                     baselineRestingHeartRate: nil, baselineHRV: nil, explanation: "", source: .history)
    }
}

private func workout(daysAgo: Int, minutes: Int, zones: [Int]) -> Workout {
    let start = calendar.date(byAdding: .day, value: -daysAgo, to: today)!.addingTimeInterval(17 * 3600)
    return Workout(kind: .run, start: start, end: start.addingTimeInterval(Double(minutes) * 60), averageHeartRate: 150,
                   maxHeartRate: 175, strain: 12, zoneSeconds: zones, calories: 0, source: .history)
}

@Test func withoutAWaistItIsUthFromTheWeeksMedianRestingHeartRate() throws {
    let estimate = try #require(VO2Max.estimate(days: days([52, 55, 53, nil, 60, 54, nil]), workouts: [], on: today,
                                                calendar: calendar, maxHeartRate: 194, age: 23, sex: .male, waistCm: nil))
    #expect(estimate.method == .heartRates)
    #expect(estimate.restingHeartRate == 54)        // median of 52, 53, 54, 55, 60
    #expect(estimate.nights == 5)
    #expect(abs(estimate.value - 15.3 * 194 / 54) < 1e-9)
    #expect(estimate.standardError == nil)
}

@Test func withAWaistItIsNesWithTheWeeksActivity() throws {
    // Three days of 40-minute workouts, 30% of the zone time in zones 4 and 5: NOOP's moderate week, 3.75.
    let workouts = (0..<3).map { workout(daysAgo: $0 * 2, minutes: 40, zones: [300, 600, 780, 480, 240]) }
    let estimate = try #require(VO2Max.estimate(days: days([65, 65, 65, 65, 65, 65, 65]), workouts: workouts, on: today,
                                                calendar: calendar, maxHeartRate: 180, age: 40, sex: .male, waistCm: 90))
    #expect(estimate.method == .nonExercise)
    #expect(abs((estimate.activityIndex ?? 0) - 3.75) < 1e-9)
    #expect(abs(estimate.value - NoopFitness.estimateVO2max(age: 40, sex: .male, waistCm: 90, restingHR: 65, paIndex: 3.75)) < 1e-9)
    #expect(estimate.standardError == 5.70)
}

@Test func aWaistWithoutAgeOrSexStaysWithUth() throws {
    let estimate = try #require(VO2Max.estimate(days: days([60, 60, 60, 60]), workouts: [], on: today, calendar: calendar,
                                                maxHeartRate: 190, age: nil, sex: .unspecified, waistCm: 85))
    #expect(estimate.method == .heartRates)
}

@Test func fewerThanFourNightsGiveNoNumber() {
    #expect(VO2Max.estimate(days: days([55, 56, 57, nil, nil, nil, nil]), workouts: [], on: today, calendar: calendar,
                            maxHeartRate: 190, age: 30, sex: .male, waistCm: nil) == nil)
}

@Test func onlyTheLastSevenDaysCount() {
    // Four nights, but the fourth is 8 days ago.
    #expect(VO2Max.estimate(days: days([55, 56, 57, nil, nil, nil, nil, nil, 50]), workouts: [], on: today, calendar: calendar,
                            maxHeartRate: 190, age: 30, sex: .male, waistCm: nil) == nil)
}
