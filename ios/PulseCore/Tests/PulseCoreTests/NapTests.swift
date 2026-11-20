import Foundation
import Testing
@testable import PulseCore

// Naps: daytime sleep of 20 minutes or more, kept apart from the night (docs/METRICS.md §4 step 7, §6).

private var calendar: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}

/// 00:00 UTC on the first day.
private let midnight = Date(timeIntervalSince1970: 1_750_032_000)

private func time(_ hour: Double) -> Date { midnight.addingTimeInterval(hour * 3600) }

private func stretch(_ from: Double, _ to: Double, _ value: (Int) -> (hr: UInt8, activity: UInt8)) -> [MinuteSample] {
    (0..<Int(((to - from) * 60).rounded())).map { index in
        let v = value(index)
        return MinuteSample(start: time(from).addingTimeInterval(Double(index) * 60), heartRate: [UInt8](repeating: v.hr, count: 60),
                            rrIntervalsMs: [], activity: [UInt8](repeating: v.activity, count: 60), source: .history)
    }
}

/// Sitting and moving around at about 64 bpm.
private func awake(_ from: Double, _ to: Double) -> [MinuteSample] {
    stretch(from, to) { (UInt8(62 + $0 % 5), UInt8(8 + $0 % 9)) }
}

/// Still and calm: a night, or a nap.
private func asleep(_ from: Double, _ to: Double) -> [MinuteSample] {
    stretch(from, to) { (UInt8(50 + $0 % 3), 1) }
}

/// `days` ordinary days and nights from 07:00 on day 0, with an optional nap on the last afternoon.
private func days(_ count: Int, nap: (from: Double, to: Double)? = nil) -> [MinuteSample] {
    var out: [MinuteSample] = []
    for day in 0..<count {
        let base = Double(day) * 24
        if day == count - 1, let nap {
            out += awake(base + 7, base + nap.from) + asleep(base + nap.from, base + nap.to) + awake(base + nap.to, base + 23)
        } else {
            out += awake(base + 7, base + 23)
        }
        out += asleep(base + 23, base + 31)
    }
    return out + awake(Double(count) * 24 + 7, Double(count) * 24 + 10)
}

private func run(_ minutes: [MinuteSample], corrections: [SleepCorrection] = []) -> MetricsResult {
    MetricsEngine.run(minutes: minutes, calendar: calendar, now: minutes.last!.start.addingTimeInterval(60), corrections: corrections)
}

@Test func aDaytimeNapIsFoundOnItsOwn() throws {
    let result = run(days(2, nap: (14, 14.67)))
    let naps = result.sleeps.filter(\.isNap)
    let nap = try #require(naps.first)
    #expect(naps.count == 1)
    #expect(abs(nap.start.timeIntervalSince(time(38))) <= 5 * 60, "nap started \(nap.start)")
    #expect(nap.asleepMinutes >= 30)
    // The nights stay whole and apart from it.
    #expect(result.sleeps.filter { !$0.isNap }.count == 2)
    #expect(nap.reviewReason != .unusualTime)
}

@Test func aNapOfTwentyMinutesCountsAndAShortDozeDoesNot() {
    #expect(run(days(2, nap: (14, 14.45))).sleeps.contains { $0.isNap })
    #expect(!run(days(2, nap: (14, 14.2))).sleeps.contains { $0.isNap })
}

@Test func aLongAfternoonNapIsStillANap() throws {
    // The owner's nap of 2026-11-19: asleep from about 15:00 to 18:20, longer than 3 hours.
    let result = run(days(2, nap: (15, 18.33)))
    let nap = try #require(result.sleeps.first { $0.isNap })
    #expect(nap.end.timeIntervalSince(nap.start) > 3 * 3600)
    #expect(abs(nap.start.timeIntervalSince(time(39))) <= 5 * 60 && abs(nap.end.timeIntervalSince(time(42.33))) <= 5 * 60,
            "nap \(nap.start)-\(nap.end)")
    #expect(nap.reviewReason == nil)
    // It is not a second night: both nights stay, and the next night's need drops by the nap.
    #expect(result.sleeps.filter { !$0.isNap }.count == 2)
    let plain = run(days(2))
    #expect(result.days.last?.sleepNeedMinutes == (plain.days.last?.sleepNeedMinutes ?? 0) - nap.asleepMinutes)
    #expect(result.days.last?.recoveryScore == plain.days.last?.recoveryScore)
}

@Test func afterANightUpTheMorningSleepIsTheNight() throws {
    // A normal first night, then up all night, then asleep from 07:00 to 12:00.
    let minutes = awake(7, 23) + asleep(23, 31) + awake(31, 55) + asleep(55, 60) + awake(60, 64)
    let result = run(minutes)
    let morning = try #require(result.sleeps.first { $0.start >= time(54) })
    #expect(!morning.isNap)
}

@Test func onlyShortOrDaytimeSleepsAreNaps() {
    func session(_ start: Int, _ end: Int) -> SleepDetector.Session {
        SleepDetector.Session(start: start, end: end, asleep: end - start, awake: 0, disturbances: 0, isNap: false)
    }
    // Usual sleep hours: minutes 0..<480 and 1440..<1920 (two nights).
    let usual = (0..<2400).map { $0 < 480 || ($0 >= 1440 && $0 < 1920) }
    let marked = SleepModel.markingNaps([session(0, 480), session(900, 1100), session(1140, 1300), session(1440, 1920)],
                                        usualSleep: usual)
    #expect(marked.map(\.isNap) == [false, true, true, false])
    // Seven hours in the afternoon is too long for a nap.
    #expect(SleepModel.markingNaps([session(0, 480), session(600, 1020)], usualSleep: usual).map(\.isNap) == [false, false])
    // A short sleep is a nap even in the usual hours.
    #expect(SleepModel.markingNaps([session(0, 120)], usualSleep: usual).map(\.isNap) == [true])
}

@Test func twentyFiveMinutesInTheUsualNightHoursAreNotASleepOfTheirOwn() {
    // Up from 01:00 to 02:30 on the first night, then 25 quiet minutes, then up again until the night goes on.
    var minutes = awake(7, 23) + asleep(23, 25) + awake(25, 26.5) + asleep(26.5, 26.92) + awake(26.92, 28) + asleep(28, 31)
    minutes += awake(31, 34)
    let found = run(minutes).sleeps
    // Inside the night hours a sleep still needs 45 minutes asleep.
    #expect(!found.contains { $0.start >= time(26.25) && $0.end <= time(27.25) })
}

@Test func theRealBackupHasNoFalseNaps() throws {
    // The owner's real evening at the computer and the morning after their night (logs/, never committed).
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("logs/pulse-backup-2026-11-18.json")
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    var data: Data? = try Data(contentsOf: url)
    let reader = try PulseBackup.Reader(chunks: { defer { data = nil }; return data })
    var minutes: [MinuteSample] = []
    while let minute = try reader.nextMinute() { minutes.append(minute) }
    var local = Calendar(identifier: .gregorian)
    local.timeZone = TimeZone(secondsFromGMT: -6 * 3600)!
    let found = MetricsEngine.run(minutes: minutes, calendar: local, now: reader.contents.header.exportedAt).sleeps
    #expect(!found.contains { $0.isNap }, "\(found.filter { $0.isNap }.map { "\($0.start)-\($0.end)" })")
}

@Test func aNapLowersTheNextNightsNeedButNotRecovery() throws {
    let without = run(days(6))
    let with = run(days(6, nap: (14, 15)))
    let nap = try #require(with.sleeps.first { $0.isNap })
    let lastNightWithout = try #require(without.days.last), lastNightWith = try #require(with.days.last)
    #expect(lastNightWith.sleepNeedMinutes == lastNightWithout.sleepNeedMinutes - nap.asleepMinutes)
    // The night's own numbers and the recovery score don't use the nap.
    #expect(lastNightWith.recoveryScore == lastNightWithout.recoveryScore)
    #expect(lastNightWith.hrvRMSSD == lastNightWithout.hrvRMSSD)
    #expect(lastNightWith.restingHeartRate == lastNightWithout.restingHeartRate)
    #expect(lastNightWith.baselineHRV == lastNightWithout.baselineHRV)
    #expect(lastNightWith.sleepMinutes == lastNightWithout.sleepMinutes)
}

@Test func aNapCountsOnlyOnce() throws {
    let with = run(days(6, nap: (14, 15)))
    let without = run(days(6))
    // Every day but the last has the same need with or without the nap.
    for (a, b) in zip(with.days.dropLast(), without.days.dropLast()) { #expect(a.sleepNeedMinutes == b.sleepNeedMinutes) }
}

@Test func aNapLoggedByHandWithoutBandDataCountsAsAsleep() throws {
    // The band was off from 13:00 to 16:00 on the last day.
    let minutes = days(2).filter { !($0.start >= time(37) && $0.start < time(40)) }
    let logged = SleepCorrection(detectedStart: time(38), detectedEnd: time(38.5), start: time(38), end: time(38.5), createdAt: time(41))
    let result = run(minutes, corrections: [logged])
    let nap = try #require(result.sleeps.first { $0.isNap })
    #expect(nap.start == time(38) && nap.end == time(38.5))
    #expect(nap.asleepMinutes == 30 && nap.awakeMinutes == 0)
    #expect(run(minutes).days.last?.sleepNeedMinutes == (result.days.last?.sleepNeedMinutes ?? 0) + 30)
}

@Test func theNeedNeverGoesBelowZero() {
    #expect(Recovery.needAfterNaps(480, napMinutes: 90) == 390)
    #expect(Recovery.needAfterNaps(60, napMinutes: 90) == 0)
    #expect(Recovery.needAfterNaps(480, napMinutes: -5) == 480)
}

@Test func napMinutesCountOnlyNapsInTheWindow() {
    func sleep(_ from: Double, _ to: Double, nap: Bool) -> SleepSession {
        SleepSession(start: time(from), end: time(to), asleepMinutes: Int((to - from) * 60), awakeMinutes: 0, disturbances: 0,
                     isNap: nap, source: .history)
    }
    let sleeps = [sleep(-1, 7, nap: false), sleep(13, 13.5, nap: true), sleep(16, 16.75, nap: true), sleep(23, 31, nap: false)]
    #expect(Recovery.napMinutes(sleeps, after: time(7), upTo: time(23)) == 75)
    #expect(Recovery.napMinutes(sleeps, after: time(14), upTo: time(23)) == 45)
}

@Test func theNeedBreakdownShowsTheNaps() {
    let plain = SleepNeedBreakdown(goal: 480, previousStrain: 12, previousNeed: 500, previousAsleep: 440)
    let napped = SleepNeedBreakdown(goal: 480, previousStrain: 12, previousNeed: 500, previousAsleep: 440, napMinutes: 40)
    #expect(plain.napCredit == 0 && napped.napCredit == 40)
    #expect(napped.total == plain.total - 40)
    #expect(!napped.isCapped)
    #expect(SleepNeedBreakdown(goal: 600, previousStrain: 20, previousNeed: nil, previousAsleep: nil).isCapped)
}
