import Foundation
import Testing
@testable import PulseCore

// Daytime stress, NOOP's day-relative score (docs/METRICS.md §14). `utcCalendar` puts these hours on the clock.

private let midnight = Date(timeIntervalSince1970: 1_750_032_000)      // 2025-06-16 00:00 UTC

private func clock(_ hour: Double) -> Date { midnight.addingTimeInterval(hour * 3600) }

private func minute(at start: Date, hr: UInt8, activity: UInt8 = 2, rr: [UInt16] = [], source: DataSource = .history) -> MinuteSample {
    MinuteSample(start: start, heartRate: [UInt8](repeating: hr, count: 60), rrIntervalsMs: rr,
                 activity: (0..<60).map { $0 % 2 == 0 ? activity : 0 }, source: source)
}

/// A full hour at one heart rate.
private func hour(_ index: Int, hr: UInt8, activity: UInt8 = 0, count: Int = 60, rr: [UInt16] = []) -> [MinuteSample] {
    (0..<count).map { minute(at: clock(Double(index)).addingTimeInterval(Double($0) * 60), hr: hr, activity: activity, rr: rr) }
}

private func analyze(_ minutes: [MinuteSample], sleeps: [SleepSession] = [], workouts: [Workout] = [], now: Date = clock(23)) -> StressMonitor.Day {
    StressMonitor.day(minutes: minutes, sleeps: sleeps, workouts: workouts, now: now, calendar: utcCalendar)
}

private func score(_ day: StressMonitor.Day, at index: Int) -> Double? {
    day.hours.first { $0.start == clock(Double(index)) }?.score
}

/// Six ordinary hours, so the day has a calm reference.
private let ordinary: [(Int, UInt8)] = [(8, 70), (9, 72), (10, 74), (11, 76), (12, 78), (13, 80)]
private func ordinaryHours() -> [MinuteSample] { ordinary.flatMap { hour($0.0, hr: $0.1) } }

@Test func theSquashCurveMatchesNoop() {
    #expect(NoopDaytimeStress.squash(0) == 1.5)
    #expect(abs(NoopDaytimeStress.squash(1) - 2.1932) < 0.0001)
    #expect(abs(NoopDaytimeStress.squash(-1) - 0.8068) < 0.0001)
    #expect(NoopDaytimeStress.squash(100) == 3)
}

@Test func levelsUseNoopsBands() {
    #expect(StressLevel(score: 0.99) == .calm)
    #expect(StressLevel(score: 1) == .medium)
    #expect(StressLevel(score: 1.99) == .medium)
    #expect(StressLevel(score: 2) == .high)
    #expect(StressLevel.medium.title == "Moderate")
}

@Test func theCalmReferenceIsTheQuartileTowardCalm() throws {
    #expect(NoopDaytimeStress.calmReference([], calmIsLow: true) == nil)
    #expect(NoopDaytimeStress.calmReference([60, 70, 80], calmIsLow: true) == 70)                     // under 4 values: the mean
    #expect(NoopDaytimeStress.calmReference([60, 70, 80, 90, 100], calmIsLow: true) == 70)
    #expect(NoopDaytimeStress.calmReference([60, 70, 80, 90, 100], calmIsLow: false) == 90)
    #expect(NoopDaytimeStress.quantile([10, 20], 0.25) == 12.5)
}

@Test func aWorkedDayScoresEachHourAgainstItsCalmestHours() throws {
    // Worked by hand: lower quartile 74.075, population SD 3.4721.
    let hours: [(Int, Double, Double)] = [(8, 70.2, 0.7402), (9, 75.8, 1.8651), (10, 78.4, 2.3296),
                                          (11, 81.1, 2.6497), (12, 73.5, 1.3761), (13, 76.8, 2.0602)]
    let inputs = hours.map {
        NoopDaytimeStress.HourInput(start: clock(Double($0.0)), hourOfDay: $0.0, meanHeartRate: $0.1, rmssd: nil, movingShare: 0)
    }
    let scored = NoopDaytimeStress.score(inputs)
    for (result, expected) in zip(scored, hours) {
        #expect(abs(try #require(result.level) - expected.2) < 0.0001)
    }
    #expect(scored.map { StressLevel(score: $0.level ?? 0) } == [.calm, .medium, .high, .high, .medium, .high])
}

@Test func lowHRVRaisesAnHoursScore() throws {
    func input(_ index: Int, rmssd: Double) -> NoopDaytimeStress.HourInput {
        .init(start: clock(Double(index)), hourOfDay: index, meanHeartRate: 72, rmssd: rmssd, movingShare: 0)
    }
    let scored = NoopDaytimeStress.score([input(8, rmssd: 90), input(9, rmssd: 85), input(10, rmssd: 80), input(11, rmssd: 40)])
    #expect(try #require(scored[3].level) > (try #require(scored[0].level)))
}

@Test func aStillMinuteWithTheBandsRestingOffsetIsScored() throws {
    // The band reports about 9 at rest. The old rule read that as moving and showed "Can't tell yet".
    let steady = (0..<60).map { index in
        MinuteSample(start: clock(14).addingTimeInterval(Double(index) * 60), heartRate: [UInt8](repeating: 72, count: 60), rrIntervalsMs: [],
                     activity: [UInt8](repeating: 9, count: 60), source: .history)
    }
    let day = analyze(ordinaryHours() + steady, now: clock(14.99))
    #expect(try #require(day.current).start == clock(14))
    #expect(!day.isMovingNow)
}

@Test func anHourNeedsFiveMinutesOfHeartRate() {
    let day = analyze(ordinaryHours() + hour(14, hr: 72, count: 4) + hour(15, hr: 72, count: 5), now: clock(15.5))
    #expect(score(day, at: 14) == nil)
    #expect(score(day, at: 15) != nil)
}

@Test func onlyWakingHoursAreScored() {
    let day = analyze(hour(5, hr: 60) + hour(6, hr: 70) + hour(21, hr: 72) + hour(22, hr: 74))
    #expect(day.hours.map(\.start) == [clock(6), clock(21)])
}

@Test func sleepIsLeftOutOfTheDay() {
    let asleep = SleepSession(start: clock(6), end: clock(9.5), asleepMinutes: 210, awakeMinutes: 0, disturbances: 0, source: .history)
    let night = (6..<9).flatMap { hour($0, hr: 50) } + hour(9, hr: 50, count: 30)
    let awake = (30..<60).map { minute(at: clock(9).addingTimeInterval(Double($0) * 60), hr: 72) }
    let day = analyze(night + awake + hour(10, hr: 72), sleeps: [asleep], now: clock(10.5))
    #expect(day.hours.map(\.start) == [clock(9), clock(10)])
    #expect(day.hours.first?.minutes == 30)
}

@Test func anHourSpentMovingIsNotScoredOrUsedAsTheReference() throws {
    let walk = (0..<18).map { minute(at: clock(14).addingTimeInterval(Double($0) * 60), hr: 120, activity: 120) }
        + (18..<60).map { minute(at: clock(14).addingTimeInterval(Double($0) * 60), hr: 120) }
    let without = analyze(ordinaryHours())
    let with = analyze(ordinaryHours() + walk)
    let hour = try #require(with.hours.first { $0.start == clock(14) })
    #expect(hour.score == nil && hour.isMoving)
    #expect(score(with, at: 8) == score(without, at: 8))
}

@Test func aBriefWalkDoesNotHideTheHour() throws {
    let walk = (0..<17).map { minute(at: clock(14).addingTimeInterval(Double($0) * 60), hr: 80, activity: 120) }
        + (17..<60).map { minute(at: clock(14).addingTimeInterval(Double($0) * 60), hr: 80) }
    let hour = try #require(analyze(ordinaryHours() + walk).hours.first { $0.start == clock(14) })
    #expect(hour.score != nil && !hour.isMoving)
}

@Test func theHourAfterMovingWaitsForTheHeartRateToSettle() throws {
    let walk = hour(14, hr: 120, activity: 120)
    let recovering = analyze(ordinaryHours() + walk + hour(15, hr: 90))
    #expect(try #require(recovering.hours.first { $0.start == clock(15) }).isMoving)
    let settled = analyze(ordinaryHours() + walk + hour(15, hr: 72))
    #expect(try #require(settled.hours.first { $0.start == clock(15) }).score != nil)
}

@Test func aWorkoutWithLittleArmMovementIsNotReadAsStress() throws {
    let lifting = Workout(id: UUID(), kind: .strength, start: clock(14), end: clock(15), averageHeartRate: 120, maxHeartRate: 163,
                          strain: 10, zoneSeconds: [0, 0, 0, 0, 0], calories: 300, source: .history)
    let day = analyze(ordinaryHours() + hour(14, hr: 120), workouts: [lifting])
    #expect(try #require(day.hours.first { $0.start == clock(14) }).isMoving)
}

@Test func rightNowIsTheNewestRecentHour() throws {
    let day = analyze(ordinaryHours(), now: clock(14.5))
    #expect(try #require(day.current).start == clock(13))
    #expect(analyze(ordinaryHours(), now: clock(16)).current == nil)
}

@Test func rightNowSaysWhenYouAreMoving() {
    let day = analyze(ordinaryHours() + hour(14, hr: 120, activity: 120), now: clock(14.9))
    #expect(day.current == nil && day.isMovingNow)
}

@Test func timePerLevelIsTheTimeMeasured() {
    let day = analyze(hour(8, hr: 70, count: 30) + hour(9, hr: 90, count: 45) + hour(10, hr: 75, count: 20) + hour(11, hr: 80, count: 10),
                      now: clock(11.9))
    #expect(day.calmMinutes + day.mediumMinutes + day.highMinutes == 105)
}

@Test func levelsStayHiddenUntilFourHoursAreScored() {
    // Two hours a beat apart: the formula alone would call one calm and the other high.
    let two = analyze(hour(8, hr: 70) + hour(9, hr: 71), now: clock(9.9))
    #expect(two.isEarlyRead && two.scoredHours == 2)
    #expect(two.current == nil && !two.isMovingNow)
    #expect(two.hours.allSatisfy { $0.score == nil })
    #expect(two.calmMinutes + two.mediumMinutes + two.highMinutes == 0)

    let four = analyze((8..<12).flatMap { hour($0, hr: UInt8(70 + $0)) }, now: clock(11.9))
    #expect(!four.isEarlyRead && four.current != nil)
}

@Test func movingStillShowsDuringAnEarlyRead() {
    let day = analyze(hour(8, hr: 70) + hour(9, hr: 120, activity: 120), now: clock(9.9))
    #expect(day.isEarlyRead && day.isMovingNow)
}

@Test func simulatedAndOffWristMinutesAreLeftOut() {
    let simulated = (0..<60).map { minute(at: clock(8).addingTimeInterval(Double($0) * 60), hr: 70, source: .simulated) }
    #expect(analyze(simulated + hour(9, hr: 0)).hours.isEmpty)
    #expect(analyze([]).current == nil)
}
