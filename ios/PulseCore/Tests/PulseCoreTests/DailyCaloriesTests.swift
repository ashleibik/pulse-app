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
    DailyCalories.estimate(minutes: minutes, body: body, dayStart: dayStart, end: dayStart.addingTimeInterval(hours * 3600),
                           maxHeartRate: 190, restingHeartRate: 60)       // active from 125 bpm
}

private let manPerDay = 1853.632                                            // 88.362 + 1071.76 + 863.82 - 170.31
private let manAt140 = 12.4786                                              // kcal a minute, worked by hand below

@Test func harrisBenedictMatchesWorkedExamples() {
    #expect(abs(NoopCalories.restingRate(body: man) * 86_400 - manPerDay) < 0.001)
    #expect(abs(NoopCalories.restingRate(body: woman) * 86_400 - 1383.683) < 0.001)   // 447.593 + 554.82 + 511.17 - 129.9
}

@Test func fitnessComesFromTheTwoHeartRates() {
    #expect(abs(NoopCalories.vo2max(maxHeartRate: 190, restingHeartRate: 60) - 48.45) < 0.001)
}

@Test func keytelWithFitnessMatchesWorkedExamples() {
    // Male: 0.634 x 140 + 0.404 x 48.45 + 0.394 x 80 + 0.271 x 30 - 95.7735 = 52.2103 kJ a minute.
    let male = NoopCalories.activeRate(heartRate: 140, maxHeartRate: 190, vo2max: 48.45, body: man) * 60
    #expect(abs(male - manAt140) < 0.001)
    // Female: 0.450 x 140 + 0.380 x 48.45 + 0.103 x 60 + 0.274 x 30 - 59.3954 = 36.4156 kJ a minute.
    let female = NoopCalories.activeRate(heartRate: 140, maxHeartRate: 190, vo2max: 48.45, body: woman) * 60
    #expect(abs(female - 8.7035) < 0.001)
}

@Test func aHeartRateAboveMaxCountsAsMax() {
    let atMax = NoopCalories.activeRate(heartRate: 190, maxHeartRate: 190, vo2max: 48.45, body: man)
    #expect(NoopCalories.activeRate(heartRate: 230, maxHeartRate: 190, vo2max: 48.45, body: man) == atMax)
}

@Test func aQuietDayIsJustTheRestingRate() throws {
    let day = try #require(estimate((0..<1440).map { minute($0, bpm: 60) }))
    #expect(day.resting == 1854 && day.active == 0 && day.total == 1854)
    #expect(day.measuredMinutes == 1440 && !day.isPartial)
}

@Test func hardMinutesAddWhatTheyCostAboveRest() throws {
    let day = try #require(estimate((0..<60).map { minute($0, bpm: 140) }))
    let extra = 60 * (manAt140 - manPerDay / 1440)
    #expect(abs(Double(day.active) - extra) < 1)
    #expect(day.total == day.resting + day.active)
}

@Test func theActiveGateIsHalfOfHeartRateReserve() throws {
    #expect(try #require(estimate((0..<60).map { minute($0, bpm: 124) })).active == 0)
    #expect(try #require(estimate((0..<60).map { minute($0, bpm: 125) })).active > 0)
}

@Test func lowHeartRatesNeverAddCaloriesAndNeverSubtract() throws {
    // With very low heart-rate anchors the formula gives less than the resting rate: it must not subtract from the day.
    let heavy = DailyCalories.Body(weightKg: 300, heightCm: 170, age: 20, sex: .female)
    let energy = try #require(NoopCalories.dayEnergy(minutes: (0..<60).map { minute($0, bpm: 36) }, body: heavy,
                                                     maxHeartRate: 40, restingHeartRate: 30))
    #expect(energy.activeKcal == 0 && energy.restingKcal > 0)
}

@Test func anOrdinaryDayWithARaisedHeartRateAddsNoActiveCalories() throws {
    // Hours of everyday activity at 110 bpm used to count as exercise.
    #expect(try #require(estimate((0..<600).map { minute($0, bpm: 110) })).active == 0)
}

@Test func noRestingHeartRateMeansNoEstimate() {
    #expect(DailyCalories.estimate(minutes: [minute(0, bpm: 60)], body: man, dayStart: dayStart, end: dayStart.addingTimeInterval(3600),
                                   maxHeartRate: 190, restingHeartRate: nil) == nil)
    #expect(DailyCalories.estimate(minutes: [minute(0, bpm: 60)], body: man, dayStart: dayStart, end: dayStart.addingTimeInterval(3600),
                                   maxHeartRate: 190, restingHeartRate: 200) == nil)
}

@Test func onlyTimeTheBandMeasuredCounts() throws {
    let morning = try #require(estimate((0..<60).map { minute($0, bpm: 60) }, hours: 6))
    #expect(morning.resting == Int((manPerDay / 24).rounded()))
    #expect(morning.measuredMinutes == 60 && morning.isPartial)
}

@Test func hoursOffTheWristAddAtMostAMinute() throws {
    let split = try #require(estimate((0..<60).map { minute($0, bpm: 60) } + (240..<300).map { minute($0, bpm: 60) }))
    // Two hours of readings, plus the 60 seconds carried across the three-hour gap.
    #expect(split.measuredMinutes == 121)
}

@Test func aGapNeverCountsAsExercise() throws {
    let steady = try #require(estimate((0..<30).map { minute($0, bpm: 140) }))
    let gapped = try #require(estimate((0..<15).map { minute($0, bpm: 140) } + (200..<215).map { minute($0, bpm: 140) }))
    #expect(abs(steady.active - gapped.active) <= 1)
}

@Test func aSparseStreamCarriesItsOwnSpacing() throws {
    var dense = MinuteSample(start: dayStart, heartRate: [UInt8](repeating: 140, count: 60), rrIntervalsMs: [],
                             activity: [UInt8](repeating: 0, count: 60), source: .history)
    let full = try #require(NoopCalories.dayEnergy(minutes: [dense], body: man, maxHeartRate: 190, restingHeartRate: 60))
    dense.heartRate = (0..<60).map { $0 % 10 == 0 ? 140 : 0 }
    let sparse = try #require(NoopCalories.dayEnergy(minutes: [dense], body: man, maxHeartRate: 190, restingHeartRate: 60))
    #expect(abs(sparse.activeKcal - full.activeKcal) < 0.001)
    #expect(sparse.observedSeconds == 60)
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

// MARK: - Walking (counted steps)

@Test func aStepLengthComesFromHeight() {
    #expect(abs(DailyCalories.stepLength(man) - 0.747) < 1e-9)          // 0.415 x 180 cm
    #expect(abs(DailyCalories.stepLength(woman) - 0.68145) < 1e-9)      // 0.413 x 165 cm
}

@Test func aMinuteOfWalkingCostsWhatACSMSays() {
    let walking = StepMinute(start: dayStart, steps: 100, seconds: 60)
    // 0.0005 x 100 steps x 0.747 m x 80 kg
    #expect(abs(DailyCalories.walkingKcal(walking, body: man) - 2.988) < 1e-9)
    // Running (140 steps a minute or more) costs twice as much a metre.
    let running = StepMinute(start: dayStart, steps: 160, seconds: 60)
    #expect(abs(DailyCalories.walkingKcal(running, body: man) - 0.001 * 160 * 0.747 * 80) < 1e-9)
    #expect(DailyCalories.walkingKcal(StepMinute(start: dayStart, steps: 0, seconds: 60), body: man) == 0)
}

@Test func walkingUnderTheHeartRateGateAddsItsStepsCost() throws {
    // An hour of walking at 95 bpm: under the gate of 125, so heart rate adds nothing and the steps add their cost.
    let day = (0..<60).map { minute($0, bpm: 95) }
    let walk = (0..<60).map { StepMinute(start: dayStart.addingTimeInterval(Double($0) * 60), steps: 100, seconds: 60) }
    let without = try #require(estimate(day))
    let with = try #require(DailyCalories.estimate(minutes: day, steps: walk, body: man, dayStart: dayStart,
                                                   end: dayStart.addingTimeInterval(86_400), maxHeartRate: 190,
                                                   restingHeartRate: 60))
    #expect(without.active == 0)
    #expect(with.active == Int((60 * 2.988).rounded()))
    #expect(with.resting == without.resting && with.total == with.resting + with.active)
}

@Test func stepsAboveTheHeartRateGateAreNotCountedTwice() throws {
    let day = (0..<60).map { minute($0, bpm: 140) }
    let run = (0..<60).map { StepMinute(start: dayStart.addingTimeInterval(Double($0) * 60), steps: 160, seconds: 60) }
    let without = try #require(estimate(day))
    let with = try #require(DailyCalories.estimate(minutes: day, steps: run, body: man, dayStart: dayStart,
                                                   end: dayStart.addingTimeInterval(86_400), maxHeartRate: 190,
                                                   restingHeartRate: 60))
    #expect(with.active == without.active)
}

@Test func lastNightIsTheNewestDayThatHasASleep() {
    // Today exists already, but the night has not synced yet.
    #expect(LastNight.day(in: [summary(2, sleep: 400), summary(0, sleep: nil), summary(1, sleep: 450)])?.sleepMinutes == 450)
    #expect(LastNight.day(in: [summary(0, sleep: nil)]) == nil)
    #expect(LastNight.day(in: []) == nil)
}
