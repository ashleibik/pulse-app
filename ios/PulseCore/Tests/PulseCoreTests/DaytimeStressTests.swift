import Foundation
import Testing
@testable import PulseCore

// Daytime stress, NOOP's day-relative score (docs/METRICS.md §14). `utcCalendar` puts these hours on the clock.

private let midnight = Date(timeIntervalSince1970: 1_750_032_000)      // 2025-06-16 00:00 UTC

private func clock(_ hour: Double) -> Date { midnight.addingTimeInterval(hour * 3600) }

/// Every second of the minute at one heart rate and one motion value.
private func minute(at start: Date, hr: UInt8, activity: UInt8 = 2, rr: [UInt16] = [], source: DataSource = .history) -> MinuteSample {
    MinuteSample(start: start, heartRate: [UInt8](repeating: hr, count: 60), rrIntervalsMs: rr,
                 activity: [UInt8](repeating: activity, count: 60), source: source)
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

@Test func deskWorkIsNotMoving() throws {
    // Typing and handling the phone: the wrist's reading changes by 0.05 to 0.10 g a second (25 to 50 here), NOOP's desk range.
    // The old rule called a minute averaging 30 or more moving, so desk hours read "Moving" all day.
    func deskMotion(_ index: Int) -> [UInt8] {
        var values: [UInt8] = []
        for second in 0..<60 {
            let value: Int = 25 + (second * 7 + index) % 70                   // 25 to 94
            values.append(UInt8(value))
        }
        return values
    }
    var desk: [MinuteSample] = []
    for index in 0..<60 {
        let start: Date = clock(14).addingTimeInterval(Double(index) * 60)
        desk.append(MinuteSample(start: start, heartRate: [UInt8](repeating: 74, count: 60), rrIntervalsMs: [],
                                 activity: deskMotion(index), source: .history))
    }
    let day = analyze(ordinaryHours() + desk, now: clock(14.99))
    #expect(try #require(day.current).start == clock(14))
    #expect(!day.isMovingNow)
}

@Test func movingIsCountedInSecondsLikeNoop() throws {
    // 22 minutes in which a third of the seconds are walking-sized (0.24 g) is 12% of the hour's seconds: not moving. The old
    // minute rule called each of those minutes moving (37% of the hour) and left the hour out.
    var mixed: [MinuteSample] = []
    for index in 0..<60 {
        var motion: [UInt8] = []
        for second in 0..<60 {
            let walking: Bool = index < 22 && second % 3 == 0
            motion.append(walking ? 120 : 20)
        }
        let start: Date = clock(14).addingTimeInterval(Double(index) * 60)
        mixed.append(MinuteSample(start: start, heartRate: [UInt8](repeating: 80, count: 60), rrIntervalsMs: [], activity: motion,
                                  source: .history))
    }
    #expect(try #require(analyze(ordinaryHours() + mixed).hours.first { $0.start == clock(14) }).isMoving == false)
    // Exactly at NOOP's 0.20 g (100) a second isn't moving; above it, it is.
    #expect(try #require(analyze(ordinaryHours() + hour(14, hr: 80, activity: 100)).hours.first { $0.start == clock(14) }).isMoving == false)
    #expect(try #require(analyze(ordinaryHours() + hour(14, hr: 80, activity: 101)).hours.first { $0.start == clock(14) }).isMoving)
}

@Test func theCardKeepsTheLastScoredHour() throws {
    // Scored hours from 8 to 13, then a walk at 14: nothing new, but 13:00 is still the last valid reading.
    let day = analyze(ordinaryHours() + hour(14, hr: 120, activity: 120), now: clock(14.9))
    #expect(day.current == nil && day.isMovingNow)
    #expect(try #require(day.lastScored).start == clock(13))
    // Before 4 hours are scored, nothing is shown, so there is nothing to keep.
    #expect(analyze(hour(8, hr: 70) + hour(9, hr: 71), now: clock(9.9)).lastScored == nil)
}

@Test func theOwnersDeskDaysAreScored() throws {
    // The owner's 2026-11-17 to 20 (logs/, never committed): mostly at a desk, 38 of 42 waking hours used to be left out as
    // "moving". With NOOP's motion gate about a third are, mostly hours with walks.
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("logs/pulse-backup-2026-11-21b.json")
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    var data: Data? = try Data(contentsOf: url)
    let reader = try PulseBackup.Reader(chunks: { defer { data = nil }; return data })
    var minutes: [MinuteSample] = []
    while let minute = try reader.nextMinute() { minutes.append(minute) }
    var local = Calendar(identifier: .gregorian)
    local.timeZone = TimeZone(secondsFromGMT: -6 * 3600)!
    let sleeps = MetricsEngine.run(minutes: minutes, calendar: local, now: reader.contents.header.exportedAt).sleeps
    var moving = 0, total = 0
    for day in 17...20 {
        let start = local.date(from: DateComponents(year: 2026, month: 11, day: day))!
        let end = start.addingTimeInterval(86_400)
        let result = StressMonitor.day(minutes: minutes.filter { $0.start >= start && $0.start < end }, sleeps: sleeps, workouts: [],
                                       now: end, calendar: local)
        for hour in result.hours where hour.minutes >= 20 {
            total += 1
            if hour.isMoving { moving += 1 }
        }
    }
    #expect(total >= 30, "\(total) hours")
    #expect(Double(moving) / Double(total) < 0.5, "\(moving) of \(total) hours left out as moving")
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
