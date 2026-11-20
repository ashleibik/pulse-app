import Foundation
import Testing
@testable import PulseCore

// Steps (docs/METRICS.md §15). Simulated wrists (`WristSimulator`) for each kind of movement, then the owner's real backup.

private var stepCalendar: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(secondsFromGMT: 0)!
    return c
}

/// 06:00 UTC.
private let morning = Date(timeIntervalSince1970: 1_750_032_000 + 6 * 3600)

private typealias Segment = WristSimulator.Segment

private func run(_ segments: [Segment], seed: UInt64 = 1, sleeps: [SleepSession] = []) -> (pulse: Int, truth: Int) {
    let minutes = WristSimulator.minutes(segments, start: morning, seed: seed)
    let end = morning.addingTimeInterval(Double(segments.reduce(0) { $0 + $1.seconds }))
    let pulse = Steps.window(minutes: minutes, sleeps: sleeps, from: morning, to: end, restingHeartRate: 55, maxHeartRate: 190).steps
    return (pulse, WristSimulator.trueSteps(segments, seed: seed))
}

private func error(_ result: (pulse: Int, truth: Int)) -> Double {
    Double(result.pulse - result.truth) / Double(max(1, result.truth))
}

private func walk(_ cadence: Double, minutes: Double, heartRate: Int = 95) -> [Segment] {
    [Segment(.standing, minutes: 1, heartRate: 75), Segment(.walk(cadence), minutes: minutes, heartRate: heartRate),
     Segment(.standing, minutes: 1, heartRate: 80)]
}

// MARK: - Walking, running, stairs

@Test func walkingAtAnEverydayPaceIsCounted() throws {
    for cadence in [1.6, 1.8] {
        // Before any calibration a walk is counted at 1.8 steps a second, so a slower pace reads high by the same ratio.
        let result = run(walk(cadence, minutes: 10))
        #expect(abs(error(result) - (1.8 / cadence - 1)) <= 0.05, "cadence \(cadence): Pulse \(result.pulse), true \(result.truth)")
        // What the detector controls: it finds the 10 minutes of walking, and nothing in the standing minutes either side.
        let minutes = WristSimulator.minutes(walk(cadence, minutes: 10), start: morning)
        let day = try #require(Steps.day(minutes: minutes, sleeps: [], dayStart: stepCalendar.startOfDay(for: morning),
                                         end: morning.addingTimeInterval(12 * 60), calendar: stepCalendar,
                                         restingHeartRate: 55, maxHeartRate: 190))
        #expect(abs(day.walkingSeconds - 600) <= 20, "cadence \(cadence): \(day.walkingSeconds) s found walking of 600")
        #expect(day.runningSeconds == 0)
    }
}

@Test func aBriskWalkNearTwoStepsASecondIsStillFound() {
    // Two steps a second swings the arm once a second, the band's own reading rate: the hardest pace to see.
    for cadence in [1.95, 2.0, 2.1] {
        let result = run(walk(cadence, minutes: 10, heartRate: 105))
        // Found as walking (counted at 1.8 a second before calibration), so about 10% under.
        #expect(error(result) > -0.2 && error(result) < 0.05, "cadence \(cadence): Pulse \(result.pulse), true \(result.truth)")
    }
}

@Test func aStepTestCalibratesTheNextWalkToWithinFivePercent() {
    // The owner's step test: 500 steps counted by hand, then another walk at their pace on another day.
    for cadence in [1.75, 1.95, 2.05] {
        let testWalk = walk(cadence, minutes: 500 / cadence / 60)
        let test = run(testWalk, seed: 7)
        let checked = Steps.Checked(reference: Steps.Reference(kind: .stepTest, start: morning, end: morning, steps: test.truth,
                                                               createdAt: morning),
                                    uncalibrated: test.pulse, coverage: 1)
        let factor = Steps.factor([checked])
        let later = run(walk(cadence, minutes: 8), seed: 8)
        let calibrated = Int((Double(later.pulse) * factor.value).rounded())
        let off = Double(calibrated - later.truth) / Double(later.truth)
        #expect(abs(off) <= 0.05, "cadence \(cadence): factor \(factor.value), Pulse \(calibrated), true \(later.truth)")
    }
}

@Test func runningIsCountedAtARunningCadence() {
    let result = run([Segment(.standing, minutes: 1, heartRate: 90), Segment(.run(2.7), minutes: 10, heartRate: 155),
                      Segment(.standing, minutes: 1, heartRate: 120)])
    #expect(abs(error(result)) <= 0.15, "Pulse \(result.pulse), true \(result.truth)")
}

@Test func stairsAreCounted() {
    let result = run([Segment(.standing, minutes: 1, heartRate: 80), Segment(.stairs(1.6), minutes: 3, heartRate: 118),
                      Segment(.standing, minutes: 1, heartRate: 100)])
    #expect(abs(error(result)) <= 0.2, "Pulse \(result.pulse), true \(result.truth)")
}

// MARK: - What isn't walking

@Test func typingIsNotWalking() {
    for seed in 1...5 as ClosedRange<UInt64> {
        let result = run([Segment(.typing, minutes: 60, heartRate: 66)], seed: seed)
        #expect(result.pulse <= 20, "seed \(seed): \(result.pulse) steps in an hour of typing")
    }
}

@Test func drivingIsNotWalking() {
    // A rough road shakes the wrist about as hard as a slow walk. A few short stretches still pass (up to 64 an hour here).
    for seed in 1...5 as ClosedRange<UInt64> {
        let result = run([Segment(.driving, minutes: 60, heartRate: 72)], seed: seed)
        #expect(result.pulse <= 100, "seed \(seed): \(result.pulse) steps in an hour of driving")
    }
}

@Test func talkingWithYourHandsIsNotWalking() {
    for seed in 1...5 as ClosedRange<UInt64> {
        let result = run([Segment(.gesturing, minutes: 60, heartRate: 75)], seed: seed)
        #expect(result.pulse <= 100, "seed \(seed): \(result.pulse) steps in an hour of gesturing")
    }
}

@Test func sleepIsNotWalking() {
    let segments = [Segment(.sleeping, minutes: 480, heartRate: 52)]
    let night = SleepSession(start: morning, end: morning.addingTimeInterval(480 * 60), asleepMinutes: 470, awakeMinutes: 10,
                             disturbances: 1, source: .history)
    #expect(run(segments, sleeps: [night]).pulse == 0)
    // Even without knowing it was a sleep, turning over doesn't look like a walk.
    #expect(run(segments).pulse <= 10)
}

@Test func aWalkInTheNightStillCounts() {
    // Up for a minute in the middle of the night (to the bathroom and back).
    let segments = [Segment(.sleeping, minutes: 120, heartRate: 52), Segment(.walk(1.6), minutes: 1, heartRate: 75),
                    Segment(.sleeping, minutes: 120, heartRate: 54)]
    let night = SleepSession(start: morning, end: morning.addingTimeInterval(241 * 60), asleepMinutes: 235, awakeMinutes: 6,
                             disturbances: 1, source: .history)
    let result = run(segments, sleeps: [night])
    #expect(abs(error(result)) <= 0.3, "Pulse \(result.pulse), true \(result.truth)")
}

// MARK: - A day

@Test func aDayAddsUpHourByHour() throws {
    // 06:00 to 10:00: an hour at the desk, a 20-minute walk from 07:10, the rest typing.
    let segments = [Segment(.typing, minutes: 70, heartRate: 66), Segment(.walk(1.8), minutes: 20, heartRate: 98),
                    Segment(.typing, minutes: 150, heartRate: 68)]
    let minutes = WristSimulator.minutes(segments, start: morning, seed: 3)
    let dayStart = stepCalendar.startOfDay(for: morning)
    let end = morning.addingTimeInterval(240 * 60)
    let day = try #require(Steps.day(minutes: minutes, sleeps: [], dayStart: dayStart, end: end, calendar: stepCalendar,
                                     restingHeartRate: 55, maxHeartRate: 190))
    #expect(day.hourly.count == 24)
    #expect(day.total == day.hourly.reduce(0, +))
    #expect(day.hourly[7] > 1500, "\(day.hourly)")
    #expect(day.hourly[6] + day.hourly[8] + day.hourly[9] <= 40, "\(day.hourly)")
    #expect(day.measuredMinutes == 240)
    #expect(day.isPartial)   // midnight to 06:00 has no data
    // The personal factor scales the count.
    let doubled = try #require(Steps.day(minutes: minutes, sleeps: [], dayStart: dayStart, end: end, calendar: stepCalendar,
                                         restingHeartRate: 55, maxHeartRate: 190, factor: 1.1))
    #expect(abs(Double(doubled.total) - Double(day.total) * 1.1) <= 24)
}

@Test func aDayWithoutBandDataHasNoSteps() {
    let dayStart = stepCalendar.startOfDay(for: morning)
    #expect(Steps.day(minutes: [], sleeps: [], dayStart: dayStart, end: dayStart.addingTimeInterval(86_400), calendar: stepCalendar,
                      restingHeartRate: nil, maxHeartRate: 190) == nil)
}

// MARK: - The owner's references

private func checked(_ kind: Steps.Reference.Kind, steps: Int, pulse: Int?, coverage: Double = 1) -> Steps.Checked {
    Steps.Checked(reference: Steps.Reference(kind: kind, start: morning, end: morning, steps: steps, createdAt: morning),
                  uncalibrated: pulse, coverage: coverage)
}

@Test func withoutReferencesTheFactorIsOne() {
    #expect(Steps.factor([]) == .none)
    // Too little to learn from: no data, a partial day, or fewer than 100 steps.
    #expect(Steps.factor([checked(.appleWatchDay, steps: 8000, pulse: nil),
                          checked(.appleWatchDay, steps: 8000, pulse: 7000, coverage: 0.6),
                          checked(.stepTest, steps: 80, pulse: 70)]) == .none)
}

@Test func oneOrTwoReferencesUseTheirMedian() {
    let one = Steps.factor([checked(.stepTest, steps: 500, pulse: 450)])
    #expect(abs(one.value - 500.0 / 450) < 1e-9)
    #expect(one.stepTests == 1 && one.appleWatchDays == 0 && one.confidence == nil)
    let two = Steps.factor([checked(.stepTest, steps: 500, pulse: 450), checked(.appleWatchDay, steps: 9000, pulse: 9000)])
    #expect(abs(two.value - (500.0 / 450 + 1) / 2) < 1e-9)
}

@Test func threeReferencesUseNoopsFit() {
    // NOOP weights each reference by Pulse's count, so the busy days outvote a short test.
    let factor = Steps.factor([checked(.stepTest, steps: 500, pulse: 250), checked(.appleWatchDay, steps: 10_000, pulse: 8_000),
                               checked(.appleWatchDay, steps: 12_000, pulse: 9_600)])
    #expect(abs(factor.value - 1.25) < 1e-9)
    #expect(factor.confidence != nil)
}

@Test func oneWrongEntryCantMakeTheCountAbsurd() {
    #expect(Steps.factor([checked(.appleWatchDay, steps: 90_000, pulse: 9_000)]).value == Steps.factorRange.upperBound)
    #expect(Steps.factor([checked(.appleWatchDay, steps: 1_000, pulse: 9_000)]).value == Steps.factorRange.lowerBound)
}

@Test func eachReferenceIsCheckedWithoutItself() throws {
    let items = [checked(.stepTest, steps: 500, pulse: 400), checked(.stepTest, steps: 520, pulse: 480),
                 checked(.appleWatchDay, steps: 9_000, pulse: nil), checked(.appleWatchDay, steps: 6_000, pulse: 5_000, coverage: 0.5)]
    let compared = Steps.compare(items)
    // The first test uses only the second's factor (520 / 480), not its own.
    let first = try #require(compared.first)
    #expect(first.pulse == Int((400.0 * 520 / 480).rounded()))
    #expect(abs((first.difference ?? 0) - Double(first.pulse! - 500) / 500) < 1e-12)
    #expect(compared[2].pulse == nil && compared[2].difference == nil)
    #expect(compared[3].isPartial)
    // The average leaves out the partial day and the one without data.
    let average = try #require(Steps.averageError(compared))
    let expected = (abs(compared[0].difference!) + abs(compared[1].difference!)) / 2
    #expect(abs(average - expected) < 1e-12)
}

// MARK: - The owner's real backup

@Test func theRealBackupCountsNoStepsInSleepOrAtTheDesk() throws {
    // logs/ is never committed: the test only runs where the owner's backup is.
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("logs/pulse-backup-2026-11-18.json")
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    var data: Data? = try Data(contentsOf: url)
    let reader = try PulseBackup.Reader(chunks: { defer { data = nil }; return data })
    var minutes: [MinuteSample] = []
    while let minute = try reader.nextMinute() { minutes.append(minute) }
    var local = Calendar(identifier: .gregorian)
    local.timeZone = TimeZone(secondsFromGMT: -6 * 3600)!
    let sleeps = MetricsEngine.run(minutes: minutes, calendar: local, now: reader.contents.header.exportedAt).sleeps
    let night = try #require(sleeps.first { !$0.isNap })
    func steps(_ from: Date, _ to: Date) -> Int {
        Steps.window(minutes: minutes, sleeps: sleeps, from: from, to: to, restingHeartRate: 53, maxHeartRate: 192).steps
    }
    func clock(_ day: Int, _ hour: Double) -> Date {
        local.date(from: DateComponents(year: 2026, month: 11, day: day))!.addingTimeInterval(hour * 3600)
    }
    let asleep = steps(night.start, night.end)
    let desk = steps(clock(17, 21.5), clock(18, 0.5))
    let burst = steps(clock(18, 11 + 27.0 / 60), clock(18, 11 + 39.0 / 60))
    #expect(asleep == 0, "\(asleep) steps in the night \(night.start)-\(night.end)")
    #expect(desk <= 30, "\(desk) steps at the computer, 21:30-00:30")
    // 11:27 to 11:39: a burst of strong movement with the heart rate rising from 64 to 90.
    #expect(burst > 100, "\(burst) steps from 11:27 to 11:39")
}
