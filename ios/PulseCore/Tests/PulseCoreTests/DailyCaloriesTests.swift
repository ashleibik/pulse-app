import Foundation
import Testing
@testable import PulseCore

// Estimated daily calories (docs/METRICS.md §9) and which day counts as "last night".

private let dayStart = Date(timeIntervalSince1970: 1_750_000_020)
private let man = DailyCalories.Body(weightKg: 80, heightCm: 180, age: 30, sex: .male)
private let woman = DailyCalories.Body(weightKg: 60, heightCm: 165, age: 30, sex: .female)
private let unknown = DailyCalories.Body(weightKg: 80, heightCm: 180, age: 30, sex: .unspecified)

private func minute(_ index: Int, bpm: UInt8, source: DataSource = .history) -> MinuteSample {
    MinuteSample(start: dayStart.addingTimeInterval(Double(index) * 60), heartRate: [UInt8](repeating: bpm, count: 60),
                 rrIntervalsMs: [], activity: [UInt8](repeating: 0, count: 60), source: source)
}

private func estimate(_ minutes: [MinuteSample], body: DailyCalories.Body = man, hours: Double = 24) -> DailyCalories.Estimate? {
    DailyCalories.estimate(minutes: minutes, body: body, dayStart: dayStart, end: dayStart.addingTimeInterval(hours * 3600))
}

@Test func mifflinStJeorMatchesWorkedExamples() throws {
    #expect(try #require(DailyCalories.restingPerDay(man)) == 1780)         // 800 + 1125 - 150 + 5
    #expect(try #require(DailyCalories.restingPerDay(woman)) == 1320.25)    // 600 + 1031.25 - 150 - 161
    #expect(DailyCalories.restingPerDay(unknown) == nil)
}

@Test func keytelMatchesWorkedExamples() throws {
    let male = try #require(DailyCalories.keytelPerMinute(heartRate: 140, body: man))
    #expect(abs(male - 13.189) < 0.001)
    let female = try #require(DailyCalories.keytelPerMinute(heartRate: 140, body: woman))
    #expect(abs(female - 8.807) < 0.001)
    #expect(DailyCalories.keytelPerMinute(heartRate: 140, body: unknown) == nil)
}

@Test func aQuietDayIsJustTheRestingRate() throws {
    let day = try #require(estimate((0..<1440).map { minute($0, bpm: 60) }))
    #expect(day.resting == 1780 && day.active == 0 && day.total == 1780)
}

@Test func hardMinutesAddWhatTheyCostAboveRest() throws {
    let day = try #require(estimate((0..<60).map { minute($0, bpm: 140) }))
    let extra = 60 * (13.189 - 1780.0 / 1440)
    #expect(abs(Double(day.active) - extra) < 1)
    #expect(day.total == day.resting + day.active)
}

@Test func lowHeartRatesNeverAddCaloriesAndNeverSubtract() throws {
    #expect(try #require(estimate([minute(0, bpm: 89)])).active == 0)
    // Keytel goes negative for a heavy body at a low heart rate: it must not subtract from the day.
    let heavy = DailyCalories.Body(weightKg: 200, heightCm: 170, age: 20, sex: .female)
    #expect(try #require(DailyCalories.keytelPerMinute(heartRate: 90, body: heavy)) < 0)
    #expect(try #require(estimate([minute(0, bpm: 90)], body: heavy)).active == 0)
}

@Test func aDayStillGoingCountsOnlyTheTimeSoFar() throws {
    let morning = try #require(estimate([minute(0, bpm: 60)], hours: 6))
    #expect(morning.resting == 445)                                         // a quarter of 1780
}

@Test func minutesOutsideTheDayAndSimulatedMinutesDoNotCount() throws {
    let day = try #require(estimate([minute(0, bpm: 60), minute(2000, bpm: 150), minute(-5, bpm: 150), minute(1, bpm: 150, source: .simulated)]))
    #expect(day.active == 0)
}

@Test func noBandDataOrUnknownSexMeansNoEstimate() {
    #expect(estimate([]) == nil)
    #expect(estimate([minute(0, bpm: 0)]) == nil)                           // off the wrist
    #expect(estimate([minute(0, bpm: 60, source: .simulated)]) == nil)
    #expect(estimate([minute(0, bpm: 60)], body: unknown) == nil)
}

// MARK: - Last night

private func summary(_ daysAgo: Int, sleep: Int?) -> DailySummary {
    DailySummary(date: dayStart.addingTimeInterval(Double(-daysAgo) * 86_400), recoveryScore: nil, strain: 0, sleepMinutes: sleep,
                 sleepNeedMinutes: 480, restingHeartRate: nil, hrvRMSSD: nil, baselineRestingHeartRate: nil,
                 baselineHRV: nil, explanation: "", source: .history)
}

@Test func lastNightIsTheNewestDayThatHasASleep() {
    // Today exists already, but the night has not synced yet.
    #expect(LastNight.day(in: [summary(2, sleep: 400), summary(0, sleep: nil), summary(1, sleep: 450)])?.sleepMinutes == 450)
    #expect(LastNight.day(in: [summary(0, sleep: nil)]) == nil)
    #expect(LastNight.day(in: []) == nil)
}
