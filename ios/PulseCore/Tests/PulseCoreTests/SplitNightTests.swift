import Foundation
import Testing
@testable import PulseCore

// A night broken by getting up for a while is one sleep (docs/METRICS.md §4, step 8).

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
private func awake(_ from: Double, _ to: Double) -> [MinuteSample] { stretch(from, to) { (UInt8(62 + $0 % 5), UInt8(8 + $0 % 9)) } }
/// Up and walking around the flat.
private func walking(_ from: Double, _ to: Double) -> [MinuteSample] { stretch(from, to) { (UInt8(95 + $0 % 6), UInt8(40 + $0 % 20)) } }
/// Still and calm.
private func asleep(_ from: Double, _ to: Double) -> [MinuteSample] { stretch(from, to) { (UInt8(50 + $0 % 3), 1) } }

private func run(_ minutes: [MinuteSample]) -> MetricsResult {
    MetricsEngine.run(minutes: minutes, calendar: calendar, now: minutes.last!.start.addingTimeInterval(60))
}

/// A first night, then the second night with `wake` in the middle, then the morning.
private func night(wakeFrom: Double, to: Double, then sleepUntil: Double = 31) -> [MinuteSample] {
    awake(7, 23) + asleep(23, wakeFrom) + walking(wakeFrom, to) + asleep(to, sleepUntil) + awake(sleepUntil, sleepUntil + 3)
}

@Test func aNightBrokenByAWalkIsOneSleep() throws {
    // The owner's night of 2026-11-27: asleep, up at 03:30 for 40 minutes, asleep again until 07:00.
    let result = run(night(wakeFrom: 27.5, to: 28.17))
    let nights = result.sleeps.filter { !$0.isNap }
    let sleep = try #require(nights.count == 1 ? nights.first : nil, "\(nights.map { "\($0.start)-\($0.end)" })")
    #expect(abs(sleep.start.timeIntervalSince(time(23))) <= 10 * 60, "starts \(sleep.start)")
    #expect(abs(sleep.end.timeIntervalSince(time(31))) <= 10 * 60, "ends \(sleep.end)")
    // Both parts count, and the walk is awake.
    #expect(sleep.asleepMinutes >= 7 * 60 + 15, "\(sleep.asleepMinutes) minutes asleep")
    #expect(sleep.awakeMinutes >= 38, "\(sleep.awakeMinutes) minutes awake")
    #expect(result.days.last?.sleepMinutes == sleep.asleepMinutes)
}

@Test func aLongerWakeInTheNightStillJoins() throws {
    // 75 minutes up at 02:00: under NOOP's 90 minutes, because the second part starts in the night.
    let nights = run(night(wakeFrom: 26, to: 27.25)).sleeps.filter { !$0.isNap }
    #expect(nights.count == 1, "\(nights.map { "\($0.start)-\($0.end)" })")
}

@Test func twoHoursUpSplitTheNight() throws {
    let sleeps = run(night(wakeFrom: 26, to: 28)).sleeps.filter { $0.start > time(20) }
    #expect(sleeps.count == 2, "\(sleeps.map { "\($0.start)-\($0.end)" })")
}

@Test func aMorningNapAfterAnHourUpIsItsOwnSleep() throws {
    // The night ends at 10:00. Up for 75 minutes, then asleep from 11:15: the 90 minutes apply only in the night.
    let minutes = awake(7, 23) + asleep(23, 34) + walking(34, 35.25) + asleep(35.25, 37) + awake(37, 40)
    let sleeps = run(minutes).sleeps.filter { $0.start > time(20) }
    #expect(sleeps.count == 2, "\(sleeps.map { "\($0.start)-\($0.end)" })")
}

@Test func theRealNightWithAWalkInTheMiddleIsOneSleep() throws {
    // The owner's night of 2026-11-27 (logs/, never committed): asleep 02:04 to 05:35, up and walking with the heart rate
    // near 100, asleep again 06:14 to 10:24. The day used to count only the second part (3h 49m).
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("logs/pulse-backup-2026-11-27.json")
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    var data: Data? = try Data(contentsOf: url)
    let reader = try PulseBackup.Reader(chunks: { defer { data = nil }; return data })
    var minutes: [MinuteSample] = []
    while let minute = try reader.nextMinute() { minutes.append(minute) }
    var local = Calendar(identifier: .gregorian)
    local.timeZone = TimeZone(secondsFromGMT: -6 * 3600)!
    func clock(_ hour: Double) -> Date {
        local.date(from: DateComponents(year: 2026, month: 11, day: 27))!.addingTimeInterval(hour * 3600)
    }
    let result = MetricsEngine.run(minutes: minutes, calendar: local, now: reader.contents.header.exportedAt)
    let night = try #require(result.sleeps.first { !$0.isNap && $0.end > clock(9) && $0.end < clock(11) })
    #expect(night.start >= clock(2) && night.start <= clock(2.25), "starts \(night.start)")
    #expect(night.asleepMinutes >= 193 + 229, "\(night.asleepMinutes) minutes asleep")
    #expect(!result.sleeps.contains { $0.start > clock(5) && $0.start < clock(7) }, "the second part is still its own sleep")
    // The evening in bed before it, mostly awake, stays apart: the night doesn't start at 00:59.
    #expect(result.sleeps.contains { $0.isNap && $0.start < clock(1.5) && $0.end <= clock(2.05) })
    let day = try #require(result.days.first { $0.date == clock(0) })
    #expect(day.sleepMinutes == night.asleepMinutes)
}
