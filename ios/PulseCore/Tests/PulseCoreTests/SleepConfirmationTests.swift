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

// MARK: - Calibrated on a real night (RealNightReplayTests replays the night itself)

/// Asleep the way the real band reports it: a steady value of 1 to 9 that only changes with the wrist's position.
private func nightWithRestingOffset(_ from: Double, _ to: Double) -> [MinuteSample] {
    stretch(from, to) { (UInt8(54 + $0 % 5), [1, 9, 4, 7, 2][($0 / 40) % 5]) }
}

@Test func aSteadyRestingOffsetIsNotMovement() {
    let at = time(10)
    #expect(minute(at, hr: 55, activity: 9).movement == 0)
    #expect(minute(at, hr: 55, activity: 40).movement == 40)        // too high to be a wrist lying still
    var fidgeting = minute(at, hr: 70, activity: 9)
    for second in stride(from: 0, to: 60, by: 3) { fidgeting.activity[second] = 30 }
    #expect(fidgeting.movement == 7)
}

@Test func aNightWithARestingOffsetIsFoundFromStartToEnd() throws {
    let minutes = daytime(9, 23) + nightWithRestingOffset(23, 32) + daytime(32, 34)
    let found = sleeps(minutes, now: time(34))
    #expect(found.count == 1)
    let sleep = try #require(found.first)
    #expect(abs(sleep.start.timeIntervalSince(time(23))) <= 10 * 60)
    #expect(abs(sleep.end.timeIntervalSince(time(32))) <= 10 * 60)
}

@Test func aShortWakeUpDoesNotEndTheNight() throws {
    let wake = stretch(27, 27 + 25.0 / 60) { _ in (78, 30) }        // 25 minutes up, like 06:40 on the real night
    let minutes = daytime(9, 23) + nightWithRestingOffset(23, 27) + wake
        + nightWithRestingOffset(27 + 25.0 / 60, 32) + daytime(32, 34)
    let found = sleeps(minutes, now: time(34))
    #expect(found.count == 1)
    let sleep = try #require(found.first)
    #expect(abs(sleep.end.timeIntervalSince(time(32))) <= 10 * 60)
    #expect(sleep.awakeMinutes >= 25)
}

@Test func aSleepsTotalsAddUpToItsPhases() throws {
    // Ten minutes of the night never reached the phone.
    let gap = time(26)..<time(26).addingTimeInterval(10 * 60)
    let minutes = (daytime(9, 23) + night(23, 30.5) + daytime(30.5, 33)).filter { !gap.contains($0.start) }
    let sleep = try #require(sleeps(minutes, now: time(33)).first)
    let segments = SleepTimeline.build(minutes: minutes, from: sleep.start, to: sleep.end)
    let totals = SleepTimeline.totals(segments)
    #expect((totals[.light] ?? 0) + (totals[.restful] ?? 0) == sleep.asleepMinutes)
    #expect((totals[.awake] ?? 0) == sleep.awakeMinutes)
    #expect(totals.values.reduce(0, +) + sleep.unknownMinutes == sleep.inBedMinutes)
    #expect(sleep.unknownMinutes == 10)
    #expect(!segments.contains { $0.start < gap.upperBound && gap.lowerBound < $0.end })
}

// MARK: - Missing data is unknown

@Test func missingMinutesAreNeitherAsleepNorAwake() throws {
    let whole = daytime(9, 23) + night(23, 30.5) + daytime(30.5, 33)
    let gap = time(27)..<time(27).addingTimeInterval(40 * 60)
    let full = try #require(sleeps(whole, now: time(33)).first)
    let holed = try #require(sleeps(whole.filter { !gap.contains($0.start) }, now: time(33)).first)
    #expect(sleeps(whole.filter { !gap.contains($0.start) }, now: time(33)).count == 1)
    #expect(holed.unknownMinutes == 40)
    #expect(holed.awakeMinutes == full.awakeMinutes)
    #expect(holed.disturbances == full.disturbances)
    #expect(holed.asleepMinutes == full.asleepMinutes - 40)
    #expect(holed.start == full.start && holed.end == full.end)
    #expect(holed.efficiency == full.efficiency || holed.efficiency > full.efficiency - 0.01)
}

@Test func aSleepEndsWhereTheBandCameOff() throws {
    let off = stretch(29, 31) { _ in (0, 0) }
    let sleep = try #require(sleeps(daytime(9, 23) + night(23, 29) + off, now: time(36)).first)
    #expect(abs(sleep.end.timeIntervalSince(time(29))) <= 2 * 60)
    #expect(sleep.unknownMinutes == 0)
}

@Test func aVeryLongGapIsNotAssumedToBeSleep() {
    let minutes = daytime(9, 23) + night(23, 25) + night(29.5, 31.5) + daytime(31.5, 34)
    let found = sleeps(minutes, now: time(34))
    #expect(found.count == 2)
    #expect(found.allSatisfy { $0.unknownMinutes == 0 })
}

@Test func noDataNeverBecomesASleep() {
    let off = stretch(23, 31) { _ in (0, 0) }
    #expect(sleeps(daytime(9, 23) + off + daytime(31, 34), now: time(34)).isEmpty)
}

@Test func appleHealthGetsNothingForMinutesWithNoData() throws {
    let whole = daytime(9, 23) + night(23, 30.5) + daytime(30.5, 33)
    let gap = time(27)..<time(27).addingTimeInterval(40 * 60)
    let minutes = whole.filter { !gap.contains($0.start) }
    let sleep = try #require(sleeps(minutes, now: time(33)).first)
    let segments = SleepTimeline.build(minutes: minutes, from: sleep.start, to: sleep.end)
    let intervals = HealthExport.sleepIntervals(for: sleep, segments: segments).filter { $0.kind != .inBed }
    #expect(!intervals.isEmpty)
    #expect(!intervals.contains { $0.start < gap.upperBound && gap.lowerBound < $0.end })
}

@Test func aTimeTheUserLeftAloneFollowsBetterDetection() throws {
    let minutes = daytime(9, 23) + night(23, 30.5) + daytime(30.5, 33)
    // Made on an older version that saw only 01:00 to 04:00. The user moved the start and kept the end.
    let edit = SleepCorrection(detectedStart: time(25), detectedEnd: time(28), start: time(23.5), end: time(28),
                               createdAt: time(33))
    let sleep = try #require(sleeps(minutes, now: time(33), corrections: [edit]).first)
    #expect(sleep.start == time(23.5))
    #expect(abs(sleep.end.timeIntervalSince(time(30.5))) <= 10 * 60)
}

// MARK: - The sleep probability model

private func timeline(_ minutes: [MinuteSample]) throws -> MetricsEngine.Timeline {
    try #require(MetricsEngine.timeline(minutes))
}

@Test func probabilitiesAreProbabilitiesAndTheSameEveryTime() throws {
    let tl = try timeline(daytime(9, 23) + night(23, 30.5) + daytime(30.5, 33))
    let first = SleepModel.probabilities(timeline: tl, calendar: calendar, corrections: [])
    #expect(first.count == tl.count && first.allSatisfy { (0...1).contains($0) })
    #expect(first == SleepModel.probabilities(timeline: tl, calendar: calendar, corrections: []))
    #expect(first[tl.index(time(26))] > 0.9)        // the middle of the night
    #expect(first[tl.index(time(14))] < 0.1)        // the middle of the day
}

@Test func smoothingIgnoresOneOddMinuteButFollowsARealChange() {
    let asleep = [Double](repeating: 2, count: 60), awake = [Double](repeating: -2, count: 60)
    var blip = asleep
    blip[30] = -3
    #expect(SleepModel.smoothed(blip)[30] > 0.9)
    let change = SleepModel.smoothed(asleep + awake)
    #expect(change[30] > 0.9 && change[90] < 0.1)
}

@Test func aSignalThatDoesNotSeparateSleepAddsNothing() throws {
    let labels: [SleepModel.Label?] = (0..<600).map { SleepModel.Label(asleep: $0 < 300, weight: 1) }
    let same: [Double?] = (0..<600).map { (i: Int) -> Double? in 50 + Double(i % 7) }
    let useless = try #require(SleepModel.learnedFromScratch(values: same, labels: labels, minimumSD: 3))
    #expect(abs(useless.evidence(50)) < 0.05 && abs(useless.evidence(56)) < 0.05)
    let useful: [Double?] = (0..<600).map { (i: Int) -> Double? in
        let level: Double = i < 300 ? 60 : 10
        return level + Double(i % 7)
    }
    let signal = try #require(SleepModel.learnedFromScratch(values: useful, labels: labels, minimumSD: 3))
    #expect(signal.evidence(62) > 0.5 && signal.evidence(12) < -0.5)
}

@Test func aSignalWithTooFewLabelledMinutesIsNotUsed() {
    let labels: [SleepModel.Label?] = (0..<100).map { SleepModel.Label(asleep: $0 < 50, weight: 1) }
    let values: [Double?] = (0..<100).map { (i: Int) -> Double? in Double(i) }
    #expect(SleepModel.learnedFromScratch(values: values, labels: labels, minimumSD: 3) == nil)
}

@Test func theClockLearnsTheHoursThisPersonSleeps() throws {
    // Night owl: asleep 03:00 to 11:00 on ten days, far from the usual hours.
    let clock = (0..<(1440 * 10)).map { $0 % 1440 }
    let nights = (0..<10).map { (1440 * $0 + 180)..<(1440 * $0 + 660) }
    let before = SleepModel.clockEvidence(nights: [], clock: clock)
    let after = SleepModel.clockEvidence(nights: nights, clock: clock)
    #expect(after[600] > before[600] + 0.5)         // 10:00 now looks like sleep
    #expect(after[60] < before[60] - 0.3)           // 01:00 no longer does
}

@Test func anEditTeachesTheModelAboutThatKindOfMinute() throws {
    // Sits very still most afternoons with a low heart rate, and says each time it wasn't sleep.
    let quietAfternoon = { (from: Double) in stretch(from, from + 2) { _ in (53, 1) } }
    var minutes = daytime(9, 23) + night(23, 30.5) + daytime(30.5, 47) + night(47, 54.5)
    minutes += daytime(54.5, 71) + night(71, 78.5) + daytime(78.5, 86)      // three nights, so learning has begun
    minutes += quietAfternoon(86) + daytime(88, 95) + night(95, 102.5) + daytime(102.5, 110)
    minutes += quietAfternoon(110) + daytime(112, 119) + night(119, 126.5) + daytime(126.5, 130)
    let tl = try timeline(minutes)
    let unedited = SleepModel.probabilities(timeline: tl, calendar: calendar, corrections: [])
    let edit = SleepCorrection(detectedStart: time(86), detectedEnd: time(88), createdAt: time(130))
    let edited = SleepModel.probabilities(timeline: tl, calendar: calendar, corrections: [edit])
    // Only the first afternoon was edited, and the second one becomes less likely to be sleep too.
    let inside = tl.index(time(110))..<tl.index(time(112))
    let before = Stats.mean(inside.map { unedited[$0] }), after = Stats.mean(inside.map { edited[$0] })
    #expect(after < before, "second afternoon: \(before) before the edit, \(after) after it")
}

// MARK: - Motion from the wrist angle

private func record(_ second: UInt32, _ accel: [Double]?) -> Whoop.HistoryRecord {
    Whoop.HistoryRecord(version: 24, counter: second, timestamp: 1_750_000_020 + second, subsec: 0, heartRate: 60,
                        accelG: accel, rrMsUnverified: [], length: 88)
}

private func turned(_ degrees: Double, size: Double = 1) -> [Double] {
    let radians = degrees * .pi / 180
    return [0, size * sin(radians), size * cos(radians)]
}

private func builtMinute(_ records: [Whoop.HistoryRecord]) throws -> MinuteSample {
    try #require(WristAngle.adding(to: MinuteBuilder.minutes(from: records), from: records).first)
}

@Test func theAngleBetweenTwoReadingsIgnoresTheirSize() throws {
    #expect(abs(try #require(WristAngle.degrees(from: turned(0), to: turned(30))) - 30) < 1e-9)
    #expect(abs(try #require(WristAngle.degrees(from: turned(0, size: 1.05), to: turned(30, size: 0.9))) - 30) < 1e-9)
    #expect(try #require(WristAngle.degrees(from: turned(10), to: turned(10))) == 0)
    #expect(WristAngle.degrees(from: [0, 0, 0], to: turned(10)) == nil)
    #expect(WristAngle.degrees(from: [0, 1], to: turned(10)) == nil)
}

@Test func aStillWristWithAnOffsetHasNoMovement() throws {
    // 1.018 g: the band's value reads 9 all minute, and the wrist doesn't move at all.
    let minute = try builtMinute((0..<60).map { record($0, turned(20, size: 1.018)) })
    #expect(minute.activity[30] == 9)
    #expect(minute.movement == 0)
}

@Test func changingSizeWithoutTurningIsNotMovement() throws {
    let minute = try builtMinute((0..<60).map { record($0, turned(20, size: $0 % 2 == 0 ? 1.0 : 1.04)) })
    #expect(minute.averageActivity > 5)
    #expect(minute.movement == 0)
}

@Test func turningTheWristOneDegreeASecondIsMeasured() throws {
    let minute = try builtMinute((0..<60).map { record($0, turned(Double($0))) })
    #expect(minute.wristAngle?[30] == 10)
    #expect(minute.wristAngle?[0] == WristAngle.noReading)      // nothing to compare the first second with
    #expect(abs(minute.movement - 500 * .pi / 180) < 0.01)      // the same scale as the band's activity value
}

@Test func aGapInTheReadingsIsNotCountedAsTurning() throws {
    let records = [record(0, turned(0)), record(5, turned(90)), record(6, turned(90))]
    let minute = try builtMinute(records)
    #expect(minute.wristAngle?[5] == WristAngle.noReading)
    #expect(minute.wristAngle?[6] == 0)
}

@Test func aMinuteWithFewAngleReadingsUsesTheOlderMeasure() throws {
    var minute = minute(time(10), hr: 60, activity: 9)
    minute.wristAngle = [UInt8](repeating: WristAngle.noReading, count: 60)
    for second in 0..<29 { minute.wristAngle?[second] = 100 }
    #expect(minute.movement == 0)                               // 29 seconds aren't enough
    minute.wristAngle?[29] = 100
    #expect(minute.movement > 80)                               // 30 are
}

@Test func secondsFromTwoBatchesAreCombined() {
    var first = [UInt8](repeating: WristAngle.noReading, count: 60), second = first
    first[10] = 5
    second[10] = 7
    second[20] = 9
    let merged = WristAngle.merged(existing: first, incoming: second)
    #expect(merged?[10] == 7 && merged?[20] == 9)
    #expect(WristAngle.merged(existing: nil, incoming: second) == second)
    #expect(WristAngle.merged(existing: first, incoming: nil) == first)
}

@Test func aNightMeasuredByWristAngleIsFound() throws {
    func withAngle(_ minutes: [MinuteSample], _ tenths: @escaping (Int) -> UInt8) -> [MinuteSample] {
        minutes.enumerated().map { index, minute in
            var out = minute
            out.wristAngle = (0..<60).map { tenths(index * 60 + $0) }
            return out
        }
    }
    let day = withAngle(daytime(9, 23)) { $0 % 4 == 0 ? 20 : 2 }
    let sleep = withAngle(nightWithRestingOffset(23, 30.5)) { _ in 0 }
    let morning = withAngle(daytime(30.5, 33)) { $0 % 4 == 0 ? 20 : 2 }
    let found = try #require(sleeps(day + sleep + morning, now: time(33)).first)
    #expect(abs(found.start.timeIntervalSince(time(23))) <= 10 * 60)
    #expect(abs(found.end.timeIntervalSince(time(30.5))) <= 10 * 60)
}

// MARK: - Three nights before personal learning

private func nightsOfData(_ count: Int) -> [MinuteSample] {
    daytime(9, 23) + (0..<count).flatMap { day -> [MinuteSample] in
        let d = Double(day) * 24
        return night(23 + d, 30.5 + d) + daytime(30.5 + d, 47 + d)
    }
}

private func learnedAfter(nights count: Int) throws -> SleepModel.Learned {
    let tl = try timeline(nightsOfData(count))
    return SleepModel.calculate(tl, calendar: calendar, corrections: [], from: SleepModel.Learned()).learned
}

@Test func twoNightsAreNotEnoughToLearnFrom() throws {
    let learned = try learnedAfter(nights: 2)
    #expect(learned.nights == 2)
    #expect(learned.heartRate == SleepModel.startingHeartRateDrop)
    #expect(learned.movement == SleepModel.startingMovement)
    #expect(learned.unsteadiness == SleepModel.startingUnsteadiness)
    #expect(learned.cleanBeats == nil && learned.hrv == nil)
}

@Test func theThirdNightStartsTheLearning() throws {
    let learned = try learnedAfter(nights: 3)
    #expect(learned.nights == 3)
    #expect(learned.heartRate != SleepModel.startingHeartRateDrop)
    #expect(learned.movement != SleepModel.startingMovement)
}

@Test func anEditInTheFirstNightsFixesThatNightButTeachesNothingYet() throws {
    let tl = try timeline(nightsOfData(2))
    let edit = SleepCorrection(detectedStart: time(23), detectedEnd: time(30.5), createdAt: time(50))
    let learned = SleepModel.calculate(tl, calendar: calendar, corrections: [edit], from: SleepModel.Learned()).learned
    #expect(learned.heartRate == SleepModel.startingHeartRateDrop)
    #expect(sleeps(nightsOfData(2), now: time(58), corrections: [edit]).count == 1)
}

@Test func theFirstNightsUseTheUsualSleepHours() {
    let session = SleepDetector.Session(start: 0, end: 300, asleep: 300, awake: 0, disturbances: 0, isNap: false)
    let observed = [Bool](repeating: true, count: 300), sure = [Double](repeating: 0.95, count: 300)
    var owl = SleepModel.Learned()
    for minute in 600..<900 { owl.asleepCounts[minute] = 2 }      // two nights at 10:00 to 15:00
    owl.nights = 2
    #expect(SleepModel.reviewReason(session, probability: sure, observed: observed, firstMinuteOfDay: 600, learned: owl) == .unusualTime)
    for minute in 600..<900 { owl.asleepCounts[minute] = 10 }
    owl.nights = 10
    #expect(SleepModel.reviewReason(session, probability: sure, observed: observed, firstMinuteOfDay: 600, learned: owl) == nil)
}

// MARK: - "Is this right?"

@Test func aSureNightIsNotQuestioned() throws {
    let sleep = try #require(sleeps(daytime(9, 23) + night(23, 30.5) + daytime(30.5, 33), now: time(33)).first)
    #expect(sleep.reviewReason == nil)
}

@Test func aNightWithMuchMissingDataIsQuestioned() throws {
    let gap = time(25)..<time(26.5)
    let minutes = (daytime(9, 23) + night(23, 30.5) + daytime(30.5, 33)).filter { !gap.contains($0.start) }
    let sleep = try #require(sleeps(minutes, now: time(33)).first)
    #expect(sleep.reviewReason == .missingData)
}

@Test func aLongSleepAtAnUnusualTimeIsQuestioned() throws {
    let minutes = daytime(9, 11) + night(11, 15) + daytime(15, 20)
    let sleep = try #require(sleeps(minutes, now: time(20)).first)
    #expect(sleep.reviewReason == .unusualTime)
}

@Test func unclearMinutesMakeASleepWorthAskingAbout() {
    let session = SleepDetector.Session(start: 0, end: 100, asleep: 100, awake: 0, disturbances: 0, isNap: true)
    let observed = [Bool](repeating: true, count: 100)
    let clear = [Double](repeating: 0.95, count: 100)
    let unclear = (0..<100).map { $0 < 20 ? 0.6 : 0.95 }
    #expect(SleepModel.reviewReason(session, probability: clear, observed: observed, firstMinuteOfDay: 60, learned: .init()) == nil)
    #expect(SleepModel.reviewReason(session, probability: unclear, observed: observed, firstMinuteOfDay: 60, learned: .init()) == .unclear)
}

@Test func answeringYesKeepsTheSleepAndStopsAsking() throws {
    let gap = time(25)..<time(26.5)
    let minutes = (daytime(9, 23) + night(23, 30.5) + daytime(30.5, 33)).filter { !gap.contains($0.start) }
    let asked = try #require(sleeps(minutes, now: time(33)).first)
    let yes = SleepCorrection.confirming(start: asked.start, end: asked.end, createdAt: time(33))
    let answered = try #require(sleeps(minutes, now: time(33), corrections: [yes]).first)
    #expect(answered.reviewReason == nil)
    #expect(answered.start == asked.start && answered.end == asked.end)
}

@Test func answeringNotAsleepRemovesTheSleep() throws {
    let minutes = daytime(9, 11) + night(11, 15) + daytime(15, 20)
    let asked = try #require(sleeps(minutes, now: time(20)).first)
    let no = SleepCorrection(detectedStart: asked.start, detectedEnd: asked.end, createdAt: time(20))
    #expect(sleeps(minutes, now: time(20), corrections: [no]).isEmpty)
}

@Test func answersBecomeLabelsForTheModel() throws {
    let tl = try timeline(daytime(9, 23) + night(23, 30.5) + daytime(30.5, 33))
    let quiet = [Double](repeating: 0.5, count: tl.count)
    let yes = SleepCorrection.confirming(start: time(24), end: time(26), createdAt: time(33))
    let no = SleepCorrection(detectedStart: time(27), detectedEnd: time(28), createdAt: time(33))
    let labels = SleepModel.labels(probability: quiet, corrections: [yes, no], timeline: tl)
    let inYes = try #require(labels[tl.index(time(25))])
    let inNo = try #require(labels[tl.index(time(27.5))])
    #expect(inYes.asleep && inYes.weight == SleepModel.editWeight)
    #expect(!inNo.asleep && inNo.weight == SleepModel.editWeight)
    #expect(labels[tl.index(time(23.5))] == nil)        // yes says nothing about the time before the sleep
}

@Test func aBackupFromBeforeReviewsStillLoads() throws {
    let old = #"{"id":"76AF2250-8A6B-4608-97A5-11F767512A1A","start":100,"end":4000,"asleepMinutes":60,"awakeMinutes":5,"disturbances":1,"isNap":true,"source":"history"}"#
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    let session = try decoder.decode(SleepSession.self, from: Data(old.utf8))
    #expect(session.reviewReason == nil)
}

// MARK: - Only changed weeks are calculated again

/// Four weeks of ordinary days and nights.
private func fourWeeks() -> [MinuteSample] {
    (0..<28).flatMap { day -> [MinuteSample] in
        let d = Double(day) * 24
        return daytime(9 + d, 23 + d) + night(23 + d, 30.5 + d) + daytime(30.5 + d, 33 + d)
    }
}

private func sameSleeps(_ a: [SleepSession], _ b: [SleepSession]) -> Bool {
    a.map(\.start) == b.map(\.start) && a.map(\.end) == b.map(\.end) && a.map(\.asleepMinutes) == b.map(\.asleepMinutes)
}

@Test func aCachedRunGivesExactlyWhatAFullRunGives() {
    let all = fourWeeks()
    let now = all.last!.start.addingTimeInterval(3600)
    var cache = SleepModelCache()
    // Syncing day by day, the way the phone does.
    for days in stride(from: 7, through: 28, by: 7) {
        let soFar = all.filter { $0.start < time(9 + Double(days) * 24) }
        _ = MetricsEngine.run(minutes: soFar, calendar: calendar, now: now, sleepCache: &cache)
    }
    let cached = MetricsEngine.run(minutes: all, calendar: calendar, now: now, sleepCache: &cache)
    let full = MetricsEngine.run(minutes: all, calendar: calendar, now: now)
    #expect(!full.sleeps.isEmpty)
    #expect(sameSleeps(cached.sleeps, full.sleeps))
    #expect(cached.days.map(\.sleepMinutes) == full.days.map(\.sleepMinutes))
}

@Test func nothingNewMeansNothingIsCalculated() {
    let all = fourWeeks()
    let now = all.last!.start.addingTimeInterval(3600)
    var cache = SleepModelCache()
    _ = MetricsEngine.run(minutes: all, calendar: calendar, now: now, sleepCache: &cache)
    #expect(cache.calculatedWeeks >= 4)
    _ = MetricsEngine.run(minutes: all, calendar: calendar, now: now, sleepCache: &cache)
    #expect(cache.calculatedWeeks == 0 && cache.reusedWeeks >= 4)
}

@Test func newMinutesOnlyRecalculateTheLatestWeek() {
    let all = fourWeeks()
    let now = all.last!.start.addingTimeInterval(3600)
    var cache = SleepModelCache()
    _ = MetricsEngine.run(minutes: Array(all.dropLast(30)), calendar: calendar, now: now, sleepCache: &cache)
    _ = MetricsEngine.run(minutes: all, calendar: calendar, now: now, sleepCache: &cache)
    #expect(cache.calculatedWeeks == 1 && cache.reusedWeeks >= 3)
}

@Test func anEditRecalculatesItsWeekAndTheWeeksAfterItOnly() throws {
    let all = fourWeeks()
    let now = all.last!.start.addingTimeInterval(3600)
    var cache = SleepModelCache()
    let before = MetricsEngine.run(minutes: all, calendar: calendar, now: now, sleepCache: &cache)
    let sleep = try #require(before.sleeps.dropFirst(14).first)
    let edit = SleepCorrection(detectedStart: sleep.start, detectedEnd: sleep.end, createdAt: now)
    let cached = MetricsEngine.run(minutes: all, calendar: calendar, now: now, corrections: [edit], sleepCache: &cache)
    #expect(cache.reusedWeeks >= 1 && cache.calculatedWeeks >= 1)
    let full = MetricsEngine.run(minutes: all, calendar: calendar, now: now, corrections: [edit])
    #expect(sameSleeps(cached.sleeps, full.sleeps))
    #expect(cached.sleeps.count == before.sleeps.count - 1)
}

@Test func theCacheSurvivesBeingSavedToAFile() throws {
    let all = fourWeeks()
    let now = all.last!.start.addingTimeInterval(3600)
    var cache = SleepModelCache()
    let first = MetricsEngine.run(minutes: all, calendar: calendar, now: now, sleepCache: &cache)
    var loaded = try #require(SleepModelCache(data: cache.encoded()))
    #expect(loaded.weeks == cache.weeks && loaded.recent == cache.recent)
    let second = MetricsEngine.run(minutes: all, calendar: calendar, now: now, sleepCache: &loaded)
    #expect(loaded.calculatedWeeks == 0)
    #expect(sameSleeps(first.sleeps, second.sleeps))
}

@Test func aDamagedCacheIsIgnored() {
    var cache = SleepModelCache()
    _ = MetricsEngine.run(minutes: daytime(9, 23) + night(23, 30.5) + daytime(30.5, 33), calendar: calendar, now: time(33), sleepCache: &cache)
    let bytes = cache.encoded()
    #expect(SleepModelCache(data: bytes.dropLast(5)) == nil)
    #expect(SleepModelCache(data: Data()) == nil)
    #expect(SleepModelCache(data: Data(repeating: 7, count: 400)) == nil)
}

// MARK: - Beats for HRV

@Test func cleanBeatsDropsFillerImpossibleBeatsAndBigJumps() {
    let steady = [Double](repeating: 900, count: 20)
    var beats = steady
    beats[3] = 500                  // the band's filler value
    beats[8] = 2400                 // impossible
    beats[12] = 1500                // far from its neighbours
    let clean = HRV.cleanBeats(beats)
    #expect(clean[3] == nil && clean[8] == nil && clean[12] == nil)
    #expect(clean.compactMap { $0 }.count == 17)
    // Each beat is near the local median, but the step between the two is more than 20%.
    let step = HRV.cleanBeats([800, 800, 800, 800, 800, 800, 980, 980, 980, 980, 980, 980])
    #expect(step[6] == nil && step[5] == 800 && step[7] == 980)
}

@Test func hrvNeverPairsBeatsAcrossTwoMinutes() throws {
    // Every minute is perfectly steady, but at a different pace from the minute before.
    let minutes = (0..<15).map { [Double](repeating: 900 + Double($0 % 2) * 40, count: 60) }
    let asleep = [Bool](repeating: true, count: 15)
    #expect(try #require(HRV.overnightRMSSD(minuteRR: minutes, asleep: asleep)) == 0)
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
