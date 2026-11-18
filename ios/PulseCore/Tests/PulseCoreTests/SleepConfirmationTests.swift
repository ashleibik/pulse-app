import Foundation
import Testing
@testable import PulseCore

// Sleep must be confirmed, finished, and correctable (docs/METRICS.md §4, steps 6-9).

private var calendar: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}

/// 09:00 on the first day of every scenario.
private let morning = Date(timeIntervalSince1970: 1_750_000_020 - 1_750_000_020.truncatingRemainder(dividingBy: 86_400) + 9 * 3600)

private func time(_ hour: Double) -> Date { morning.addingTimeInterval((hour - 9) * 3600) }

private func minute(_ start: Date, hr: UInt8, activity: UInt8) -> MinuteSample {
    MinuteSample(start: start, heartRate: [UInt8](repeating: hr, count: 60), rrIntervalsMs: [],
                 activity: [UInt8](repeating: activity, count: 60), source: .history)
}

/// `from` and `to` are hours after 00:00 of the first day (25 = 01:00 the next night).
private func stretch(_ from: Double, _ to: Double, _ value: (Int) -> (hr: UInt8, activity: UInt8)) -> [MinuteSample] {
    (0..<Int((to - from) * 60)).map { index in
        let v = value(index)
        return minute(time(from).addingTimeInterval(Double(index) * 60), hr: v.hr, activity: v.activity)
    }
}

/// An ordinary day: sitting and moving around at about 64 bpm.
private func daytime(_ from: Double, _ to: Double) -> [MinuteSample] {
    stretch(from, to) { (UInt8(62 + $0 % 5), UInt8(8 + $0 % 9)) }
}

/// The evening from the bug report: at the computer from 21:26 to 00:32. Heart rate keeps spiking
/// while typing, with one flat half hour around 23:00, and the wrist barely registers as moving.
private func atTheComputer(motion: @escaping (Int) -> UInt8) -> [MinuteSample] {
    stretch(21.4333, 24.5333) { index in
        if (85..<115).contains(index) { return (52, motion(index)) }
        return (index % 16 < 4 ? 72 : 54, motion(index))
    }
}

private func sleeps(_ minutes: [MinuteSample], now: Date, corrections: [SleepCorrection] = []) -> [SleepSession] {
    MetricsEngine.run(minutes: minutes, calendar: calendar, now: now, corrections: corrections).sleeps
}

/// A real night: still, calm and 12 bpm under the day, with two short wake-ups.
private func night(_ from: Double, _ to: Double) -> [MinuteSample] {
    stretch(from, to) { index in
        if (120..<124).contains(index) || (300..<303).contains(index) { return (66, 60) }
        return (UInt8(50 + index % 3), 1)
    }
}

// MARK: - The bug report

@Test func sittingAtTheComputerInTheEveningIsNotSleep() {
    let quiet = daytime(9, 21.4333) + atTheComputer { UInt8($0 % 3) }
    // The pattern really is what fooled the old detector: one long candidate from the first stage.
    let timeline = MetricsEngine.timeline(quiet)!
    let candidates = SleepDetector.sessions(SleepDetector.classify(hr: timeline.hr, activity: timeline.activity))
    #expect(candidates.contains { $0.span >= 150 })

    #expect(sleeps(quiet, now: time(24.55)).isEmpty)
    // Still not sleep hours later, when nothing can be "in progress" any more.
    #expect(sleeps(quiet, now: time(34)).isEmpty)
}

@Test func theEveningIsNotSleepEvenIfTheBandReportsNoMotionAtAll() {
    let noMotion = daytime(9, 21.4333) + atTheComputer { _ in 0 }
    #expect(sleeps(noMotion, now: time(24.55)).isEmpty)
    #expect(sleeps(noMotion, now: time(34)).isEmpty)
}

@Test func theEveningIsNotSleepWhenTypingShowsUpAsMotion() {
    let typing = daytime(9, 21.4333) + atTheComputer { UInt8(6 + $0 % 7) }
    #expect(sleeps(typing, now: time(34)).isEmpty)
}

@Test func theEveningDoesNotBecomePartOfTheRealNightThatFollows() throws {
    let minutes = daytime(9, 21.4333) + atTheComputer { UInt8($0 % 3) } + night(24.5333, 32) + daytime(32, 34)
    let found = try #require(sleeps(minutes, now: time(34)).first)
    #expect(sleeps(minutes, now: time(34)).count == 1)
    // The last quiet minutes at the desk look like the night itself: the usual ±10 minutes apply.
    #expect(found.start >= time(24.5333).addingTimeInterval(-10 * 60))
}

// MARK: - Stricter rules

@Test func aRealNightIsFoundWithItsShortWakeUpsInside() throws {
    let minutes = daytime(9, 23) + night(23, 30.5) + daytime(30.5, 33)
    let found = sleeps(minutes, now: time(33))
    #expect(found.count == 1)
    let sleep = try #require(found.first)
    #expect(abs(sleep.start.timeIntervalSince(time(23))) <= 10 * 60)
    #expect(abs(sleep.end.timeIntervalSince(time(30.5))) <= 10 * 60)
    #expect(sleep.disturbances >= 2 && !sleep.isNap)
}

@Test func stillnessShorterThanTheOnsetDoesNotStartASleep() {
    let rest = stretch(14, 14.5) { _ in (50, 1) }                  // 30 minutes
    #expect(sleeps(daytime(9, 14) + rest + daytime(14.5, 18), now: time(18)).isEmpty)
}

@Test func beingStillWithAnAwakeHeartRateIsNotSleep() {
    let reading = stretch(14, 18) { _ in (63, 1) }                 // no drop below the day's level
    #expect(sleeps(daytime(9, 14) + reading + daytime(18, 22), now: time(22)).isEmpty)
}

@Test func aLongActivePeriodEndsTheSleep() {
    let first = stretch(23, 26) { _ in (50, 1) }
    let up = stretch(26, 26.75) { _ in (58, 40) }                  // 45 minutes up and about at 02:00
    let second = stretch(26.75, 30.5) { _ in (50, 1) }
    let found = sleeps(daytime(9, 23) + first + up + second + daytime(30.5, 33), now: time(33))
    #expect(found.count == 2)
    #expect(found.allSatisfy { $0.start >= time(26.75) || $0.end <= time(26.1) })
}

// MARK: - In progress

@Test func aSleepStillGoingIsNotShownUntilThePersonIsUp() throws {
    let evening = daytime(9, 23)
    let asleep = night(23, 30.5)
    // 04:00, still asleep.
    #expect(sleeps(evening + night(23, 28), now: time(28)).isEmpty)
    // 06:35, just woke up: not yet clearly awake.
    #expect(sleeps(evening + asleep + daytime(30.5, 30.6), now: time(30.6)).isEmpty)
    // Up and moving for half an hour: now it is a finished night.
    #expect(sleeps(evening + asleep + daytime(30.5, 31), now: time(31)).count == 1)
}

@Test func aNightStillCountsWhenTheBandComesOffInTheMorning() {
    let off = stretch(30.5, 32) { _ in (0, 0) }
    #expect(sleeps(daytime(9, 23) + night(23, 30.5) + off, now: time(32)).count == 1)
}

// MARK: - Corrections

@Test func iWasntAsleepRemovesTheSleepAndItsNumbers() throws {
    let minutes = daytime(9, 23) + night(23, 30.5) + daytime(30.5, 33)
    let detected = try #require(sleeps(minutes, now: time(33)).first)
    let removal = SleepCorrection(detectedStart: detected.start, detectedEnd: detected.end, createdAt: time(33))
    let result = MetricsEngine.run(minutes: minutes, calendar: calendar, now: time(33), corrections: [removal])
    #expect(result.sleeps.isEmpty)
    #expect(result.days.allSatisfy { $0.sleepMinutes == nil })
}

@Test func editedTimesReplaceTheDetectedOnesAndSurviveARecalculation() throws {
    let minutes = daytime(9, 23) + night(23, 30.5) + daytime(30.5, 33)
    let detected = try #require(sleeps(minutes, now: time(33)).first)
    let edit = SleepCorrection(detectedStart: detected.start, detectedEnd: detected.end,
                               start: time(23.5), end: time(30), createdAt: time(33))
    let found = sleeps(minutes, now: time(34), corrections: [edit])
    #expect(found.count == 1)
    #expect(found.first?.start == time(23.5) && found.first?.end == time(30))
}

@Test func theNewestCorrectionWins() throws {
    let minutes = daytime(9, 23) + night(23, 30.5) + daytime(30.5, 33)
    let detected = try #require(sleeps(minutes, now: time(33)).first)
    let edit = SleepCorrection(detectedStart: detected.start, detectedEnd: detected.end,
                               start: time(23.5), end: time(30), createdAt: time(33))
    let removal = SleepCorrection(detectedStart: time(23.5), detectedEnd: time(30), createdAt: time(33.5))
    #expect(sleeps(minutes, now: time(34), corrections: [removal, edit]).isEmpty)
}

@Test func aCorrectionLeavesOtherNightsAlone() throws {
    let minutes = daytime(9, 23) + night(23, 30.5) + daytime(30.5, 47) + night(47, 54.5) + daytime(54.5, 57)
    let all = sleeps(minutes, now: time(57))
    #expect(all.count == 2)
    let first = try #require(all.first)
    let removal = SleepCorrection(detectedStart: first.start, detectedEnd: first.end, createdAt: time(57))
    #expect(sleeps(minutes, now: time(57), corrections: [removal]).map(\.start) == [all[1].start])
}

// MARK: - Motion

@Test func turningTheWristCountsAsMotionEvenAtOneG() {
    let flat: [Double] = [0, 0, 1], tilted: [Double] = [0, 0.1, 0.995]
    #expect(MinuteBuilder.activity(accelG: tilted) < 5)            // magnitude alone sees almost nothing
    #expect(MinuteBuilder.activity(accelG: tilted, previous: flat) >= 45)
    #expect(MinuteBuilder.activity(accelG: flat, previous: flat) == 0)
}

@Test func minutesBuiltFromRecordsSeeTheWristTurning() throws {
    let start: UInt32 = 1_750_000_020
    let records = (0..<60).map { second -> Whoop.HistoryRecord in
        let angle = second % 2 == 0 ? 0.0 : 0.1
        return Whoop.HistoryRecord(version: 1, counter: UInt32(second), timestamp: start + UInt32(second), subsec: 0, heartRate: 60,
                                   accelG: [0, sin(angle), cos(angle)], rrMsUnverified: [], length: 48)
    }
    let built = try #require(MinuteBuilder.minutes(from: records).first)
    #expect(built.averageActivity > 30)
}

@Test func theMotionCheckTellsAliveFromFlatFromMissing() {
    let at = time(10)
    #expect(MotionCheck.verdict([]) == .noData)
    #expect(MotionCheck.verdict([minute(at, hr: 0, activity: 0)]) == .noData)
    #expect(MotionCheck.verdict([minute(at, hr: 60, activity: 0), minute(at.addingTimeInterval(60), hr: 60, activity: 0)]) == .noSignal)
    #expect(MotionCheck.verdict([minute(at, hr: 60, activity: 2), minute(at.addingTimeInterval(60), hr: 60, activity: 3)]) == .flat)
    #expect(MotionCheck.verdict([minute(at, hr: 60, activity: 2), minute(at.addingTimeInterval(60), hr: 60, activity: 40)]) == .changing)
}

@Test func theSyncLogReportsWhetherTheAccelerometerIsAlive() {
    func record(_ accel: [Double]?) -> Whoop.HistoryRecord {
        Whoop.HistoryRecord(version: 1, counter: 0, timestamp: 1_750_000_020, subsec: 0, heartRate: 60, accelG: accel,
                            rrMsUnverified: [], length: 48)
    }
    #expect(MotionCheck.traceLine([record(nil), record(nil)]).contains("no usable accelerometer"))
    let line = MotionCheck.traceLine([record([0, 0, 1]), record([0, 0.1, 0.995])])
    #expect(line.contains("accel ok in 2"))
    #expect(line.contains("max 50"))
}
