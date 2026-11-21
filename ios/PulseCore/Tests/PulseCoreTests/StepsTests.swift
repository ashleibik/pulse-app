import Foundation
import Testing
@testable import PulseCore

// Steps the band counts on its 100 Hz stream, minute by minute (docs/METRICS.md §15), and when it streams.

/// A minute boundary.
private let minuteStart: UInt32 = 1_795_000_020
private func date(_ second: UInt32) -> Date { Date(timeIntervalSince1970: Double(second)) }

private var stepCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}

private func count(_ packets: [Whoop.RawMotion]) -> [StepMinute] {
    var counter = StreamStepCounter()
    var minutes: [StepMinute] = []
    for packet in packets { minutes += counter.add(packet) }
    return minutes + counter.finish()
}

// MARK: - Counting

@Test func aWalkIsCountedOneClockMinuteAtATimeLikeOpenStrapsDailyTotal() {
    let walk = walkPackets(seconds: 300, stepHz: 1.8, from: minuteStart)
    let minutes = count(walk)
    #expect(minutes.map(\.start) == (0..<5).map { date(minuteStart + UInt32($0 * 60)) })
    #expect(minutes.allSatisfy { $0.seconds == 60 })
    // The same as OpenStrap's `calcSteps` over the five minutes' signals.
    let signals = (0..<5).map { LiveSteps.magnitudes(Array(walk[($0 * 60)..<($0 * 60 + 60)])) }
    #expect(minutes.reduce(0) { $0 + $1.steps } == OpenStrapPedometer.calcSteps(signals))
    // 540 steps were taken; counting each minute alone loses at most a step or two a minute.
    let total = minutes.reduce(0) { $0 + $1.steps }
    #expect((528...542).contains(total), "\(total)")
}

@Test func aStillWristCountsNoStepsButItsSecondsArrived() {
    let minutes = count(walkPackets(seconds: 120, stepHz: 1.8, ampG: 0, from: minuteStart))
    #expect(minutes.map(\.steps) == [0, 0])
    #expect(minutes.map(\.seconds) == [60, 60])
}

@Test func aSecondTheBandSendsTwiceCountsOnce() {
    let walk = walkPackets(seconds: 60, stepHz: 1.8, from: minuteStart)
    let twice = walk.flatMap { [$0, $0] }
    #expect(count(twice) == count(walk))
}

@Test func aMissingSecondSplitsTheMinuteIntoTwoRuns() {
    let walk = walkPackets(seconds: 60, stepHz: 1.8, from: minuteStart)
    let gapped = walk.enumerated().filter { $0.offset != 30 }.map(\.element)
    let minutes = count(gapped)
    #expect(minutes.count == 1 && minutes[0].seconds == 59)
    let runs = [LiveSteps.magnitudes(Array(walk[0..<30])), LiveSteps.magnitudes(Array(walk[31..<60]))]
    #expect(minutes[0].steps == runs.reduce(0) { $0 + OpenStrapPedometer.pedometer($1) })
}

@Test func stoppingTheStreamEndsTheMinuteInProgress() {
    var counter = StreamStepCounter()
    var minutes: [StepMinute] = []
    for packet in walkPackets(seconds: 30, stepHz: 1.8, from: minuteStart) { minutes += counter.add(packet) }
    #expect(minutes.isEmpty)
    let finished = counter.finish()
    #expect(finished.count == 1 && finished[0].seconds == 30 && finished[0].start == date(minuteStart))
    #expect(counter.finish().isEmpty)
}

@Test func afterTheStreamStopsAnEarlierSecondCountsAgain() {
    // The band's clock can be set back between connections: its seconds then aren't repeats.
    var counter = StreamStepCounter()
    for packet in walkPackets(seconds: 10, stepHz: 1.8, from: minuteStart + 600) { _ = counter.add(packet) }
    _ = counter.finish()
    for packet in walkPackets(seconds: 10, stepHz: 1.8, from: minuteStart) { _ = counter.add(packet) }
    #expect(counter.finish().first?.seconds == 10)
}

@Test func aMinutesCadenceIsStepsPerMinuteAtItsPace() {
    #expect(StepMinute(start: date(minuteStart), steps: 50, seconds: 30).cadence == 100)
    #expect(StepMinute(start: date(minuteStart), steps: 0, seconds: 0).cadence == 0)
}

@Test func aMinuteIsStoredAsThreeNumbers() throws {
    let minute = StepMinute(start: date(minuteStart), steps: 104, seconds: 60)
    let json = try JSONEncoder().encode([minute])
    #expect(String(decoding: json, as: UTF8.self) == "[[\(minuteStart),104,60]]")
    #expect(try JSONDecoder().decode([StepMinute].self, from: json) == [minute])
}

// MARK: - Days

@Test func aDayAddsUpItsMinutesHourByHour() throws {
    let day = stepCalendar.startOfDay(for: date(minuteStart))
    let minutes = [
        StepMinute(start: day.addingTimeInterval(8 * 3600), steps: 100, seconds: 60),
        StepMinute(start: day.addingTimeInterval(8 * 3600 + 60), steps: 90, seconds: 30),
        StepMinute(start: day.addingTimeInterval(17 * 3600 + 600), steps: 40, seconds: 60),
        StepMinute(start: day.addingTimeInterval(-60), steps: 500, seconds: 60),          // the day before
        StepMinute(start: day.addingTimeInterval(86_400), steps: 500, seconds: 60),       // the day after
    ]
    let counted = try #require(Steps.day(minutes, dayStart: day, end: day.addingTimeInterval(86_400), calendar: stepCalendar))
    #expect(counted.total == 230)
    #expect(counted.hourly.count == 24)
    #expect(counted.hourly[8] == 190 && counted.hourly[17] == 40 && counted.hourly.reduce(0, +) == 230)
    #expect(counted.countedMinutes == 3)        // 150 seconds
}

@Test func aDayTheBandNeverCountedHasNoSteps() {
    let day = stepCalendar.startOfDay(for: date(minuteStart))
    #expect(Steps.day([], dayStart: day, end: day.addingTimeInterval(86_400), calendar: stepCalendar) == nil)
}

@Test func aStepTestComparesTheBandsCountWithYours() {
    let test = Steps.Reference(kind: .stepTest, start: date(minuteStart), end: date(minuteStart + 300), steps: 500,
                               createdAt: date(minuteStart + 300), liveSteps: 489)
    #expect(abs((test.difference ?? 0) - -0.022) < 1e-9)
    let noStream = Steps.Reference(kind: .stepTest, start: date(minuteStart), end: date(minuteStart + 300), steps: 500,
                                   createdAt: date(minuteStart + 300))
    let watchDay = Steps.Reference(kind: .appleWatchDay, start: date(minuteStart), end: date(minuteStart + 86_400),
                                   steps: 1200, createdAt: date(minuteStart), liveSteps: 9000)
    #expect(noStream.difference == nil && watchDay.difference == nil)
    let other = Steps.Reference(kind: .stepTest, start: date(minuteStart), end: date(minuteStart + 300), steps: 500,
                                createdAt: date(minuteStart), liveSteps: 520)
    #expect(abs((Steps.averageDifference([test, noStream, watchDay, other]) ?? 0) - 0.031) < 1e-9)
    #expect(Steps.averageDifference([noStream, watchDay]) == nil)
}

// MARK: - The minute in progress

@Test func theMinuteInProgressCountsTheSameAsWhenItCloses() {
    var counter = StreamStepCounter()
    let walk = walkPackets(seconds: 61, stepHz: 1.8, from: minuteStart)
    var closed: [StepMinute] = []
    for motion in walk.prefix(60) { closed += counter.add(motion) }
    #expect(closed.isEmpty)
    #expect(counter.minuteInProgress == date(minuteStart))
    let soFar = counter.stepsSoFar
    #expect(soFar > 0)
    closed += counter.add(walk[60])                     // the next minute starts: this one closes
    #expect(closed.first?.steps == soFar)
    #expect(counter.minuteInProgress == date(minuteStart + 60))
    #expect(counter.stepsSoFar == 0)                     // one second of the new minute is not a step yet
    _ = counter.finish()
    #expect(counter.minuteInProgress == nil && counter.stepsSoFar == 0)
}

@Test func aDayGrowsWithTheMinuteInProgress() throws {
    let dayStart = stepCalendar.startOfDay(for: date(minuteStart))
    let saved = Steps.day([StepMinute(start: dayStart.addingTimeInterval(3600), steps: 100, seconds: 60)], dayStart: dayStart,
                          end: dayStart.addingTimeInterval(7200), calendar: stepCalendar)
    let now = StepMinute(start: dayStart.addingTimeInterval(5400), steps: 40, seconds: 30)
    let live = try #require(Steps.day(saved, adding: now, dayStart: dayStart, calendar: stepCalendar))
    #expect(live.total == 140)
    #expect(live.hourly[1] == 140)
    #expect(live.countedMinutes == saved?.countedMinutes)
    // Nothing counted yet today: the minute in progress is the day.
    #expect(Steps.day(nil, adding: now, dayStart: dayStart, calendar: stepCalendar)?.total == 40)
    // No steps in it, or another day's minute: nothing changes.
    #expect(Steps.day(saved, adding: StepMinute(start: now.start, steps: 0, seconds: 30), dayStart: dayStart,
                      calendar: stepCalendar) == saved)
    #expect(Steps.day(nil, adding: StepMinute(start: dayStart.addingTimeInterval(-60), steps: 40, seconds: 30), dayStart: dayStart,
                      calendar: stepCalendar) == nil)
}

// MARK: - When the band streams

private func minute(_ index: Int, heartRate: UInt8 = 60, turn: UInt8? = 4, movement: UInt8 = 3) -> MinuteSample {
    var sample = MinuteSample(start: date(minuteStart + UInt32(index * 60)), heartRate: Array(repeating: heartRate, count: 60),
                              rrIntervalsMs: [], activity: Array(repeating: movement, count: 60), source: .history)
    sample.wristAngle = turn.map { Array(repeating: $0, count: 60) }
    return sample
}

@Test func sittingStillKeepsTheStreamOnSoTheNextWalkCountsFromItsFirstStep() {
    // Half an hour at a desk used to pause the stream, and only the next pull, minutes later, started it again.
    let still = (0..<30).map { minute($0) }
    #expect(MotionStreamPolicy.decide(recent: still, batteryPercent: 80, charging: false, streaming: true, asleep: false) == .stream)
    let stillWithoutTurns = (0..<30).map { minute($0, turn: nil, movement: 4) }
    #expect(MotionStreamPolicy.decide(recent: stillWithoutTurns, batteryPercent: 80, charging: nil, streaming: false,
                                      asleep: false) == .stream)
}

@Test func theStreamStopsWhileYouSleep() {
    let still = (0..<30).map { minute($0) }
    #expect(MotionStreamPolicy.decide(recent: still, batteryPercent: 80, charging: false, streaming: true, asleep: true) == .asleep)
    #expect(!MotionStreamPolicy.Decision.asleep.isOn)
}

@Test func theStreamStopsWhenTheBandIsOffTheWrist() {
    let worn = (0..<20).map { minute($0, turn: 60) }
    let off = (20..<30).map { minute($0, heartRate: 0, turn: nil, movement: 0) }
    #expect(MotionStreamPolicy.decide(recent: worn + off, batteryPercent: 80, charging: false, streaming: true,
                                      asleep: false) == .notWorn)
    #expect(MotionStreamPolicy.decide(recent: worn + off.prefix(9), batteryPercent: 80, charging: false,
                                      streaming: true, asleep: false) == .stream)
    // Off the wrist wins over asleep: the band is on the nightstand.
    #expect(MotionStreamPolicy.decide(recent: worn + off, batteryPercent: 80, charging: false, streaming: true,
                                      asleep: true) == .notWorn)
}

@Test func theStreamSparesALowBatteryWithoutFlickering() {
    let moving = (0..<30).map { minute($0, turn: 60) }
    func decide(_ battery: Double, charging: Bool, streaming: Bool) -> MotionStreamPolicy.Decision {
        MotionStreamPolicy.decide(recent: moving, batteryPercent: battery, charging: charging, streaming: streaming, asleep: false)
    }
    #expect(decide(14, charging: false, streaming: true) == .lowBattery)
    #expect(decide(17, charging: false, streaming: true) == .stream)
    #expect(decide(17, charging: false, streaming: false) == .lowBattery)
    #expect(decide(20, charging: false, streaming: false) == .stream)
    #expect(decide(5, charging: true, streaming: false) == .stream)
}

@Test func withNoBandDataYetTheStreamStarts() {
    #expect(MotionStreamPolicy.decide(recent: [], batteryPercent: nil, charging: nil, streaming: false, asleep: false) == .stream)
    #expect(MotionStreamPolicy.Decision.stream.isOn)
}
