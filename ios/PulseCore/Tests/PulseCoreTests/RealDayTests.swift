import Foundation
import Testing
@testable import PulseCore

// The owner's 2026-11-21 and the morning of 2026-11-22, from build 31 (logs/, never committed; the test passes without it).
// Asleep 2:35 to 11:19. The owner saw "Counted for 5h 20m", a stress card stuck on "--" and "Moving", "Out of range" on the
// health card, and an axis reading "2:35 AM · 6 AM · 8 AM · 11:19 AM".

private struct RealDay {
    let minutes: [MinuteSample]
    let contents: PulseBackup.Contents
    let local: Calendar

    init?() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("logs/pulse-backup-2026-11-22.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var data: Data? = try Data(contentsOf: url)
        let reader = try PulseBackup.Reader(chunks: { defer { data = nil }; return data })
        var minutes: [MinuteSample] = []
        while let minute = try reader.nextMinute() { minutes.append(minute) }
        self.minutes = minutes
        contents = reader.contents
        var local = Calendar(identifier: .gregorian)
        local.timeZone = TimeZone(secondsFromGMT: -6 * 3600)!
        self.local = local
    }

    func clock(_ day: Int, _ hour: Double) -> Date {
        local.date(from: DateComponents(year: 2026, month: 11, day: day))!.addingTimeInterval(hour * 3600)
    }

    var night: SleepSession? {
        contents.sleeps.first { !$0.isNap && $0.end > clock(22, 11) && $0.end < clock(22, 11.5) }
    }
}

@Test func theRealMorningCountsStepsFromWaking() throws {
    guard let real = try RealDay() else { return }
    let dayStart = real.clock(22, 0), now = real.contents.header.exportedAt
    let asleep = real.contents.sleeps.map { DateInterval(start: $0.start, end: $0.end) }
    let before = try #require(Steps.day(real.contents.stepMinutes, dayStart: dayStart, end: now, calendar: real.local))
    let after = try #require(Steps.day(real.contents.stepMinutes, dayStart: dayStart, end: now, calendar: real.local, asleep: asleep))
    // The stream ran 3h of the night in bed (2:35 to 3:24 before Pulse found the night, short bursts, 9:17 to 10:57).
    #expect(before.countedMinutes >= 340, "\(before.countedMinutes) min")
    // Awake: up to 2:35 and from 11:19.
    #expect(after.countedMinutes >= 160 && after.countedMinutes <= 175, "\(after.countedMinutes) min")
    #expect(after.hourly[9] == 0 && after.hourly[10] == 0)
}

@Test func theRealDaysStressIsScored() throws {
    guard let real = try RealDay() else { return }
    let sleeps = real.contents.sleeps, workouts = real.contents.workouts.map(\.workout)
    func day(_ number: Int, now: Date) -> StressMonitor.Day {
        let start = real.clock(number, 0)
        return StressMonitor.day(minutes: real.minutes.filter { $0.start >= start && $0.start < start.addingTimeInterval(86_400) },
                                 sleeps: sleeps, workouts: workouts, now: now, calendar: real.local)
    }
    // 2026-11-21: the old minute rule left out 13 of 14 waking hours. NOOP's leaves out the gym (13:35 to 14:15) and a few
    // more, and scores the rest.
    let yesterday = day(21, now: real.clock(22, 0))
    let hours = yesterday.hours.filter { $0.minutes >= 5 }
    let moving = hours.filter(\.isMoving).count
    #expect(hours.count >= 12 && moving <= 6, "\(moving) of \(hours.count) hours moving")
    #expect(!yesterday.isEarlyRead)
    let last = try #require(yesterday.lastScored)
    #expect(last.start >= real.clock(21, 19), "last scored \(last.start)")
    // 2026-11-22 at 12:50: 11 AM and noon are desk hours, not moving. With 2 scored hours the levels are still withheld,
    // so the card shows yesterday's last reading instead of "--".
    let today = day(22, now: real.contents.header.exportedAt)
    for hour in today.hours where hour.minutes >= 20 { #expect(!hour.isMoving, "\(hour.start) moving") }
    #expect(today.lastScored == nil)
}

@Test func theRealNightsAxisIsEven() throws {
    guard let real = try RealDay() else { return }
    let night = try #require(real.night)
    #expect(SleepTimeline.axisTimes(from: night.start, to: night.end, calendar: real.local)
            == [real.clock(22, 4), real.clock(22, 6), real.clock(22, 8), real.clock(22, 10)])
}

@Test func theRealNightPausesTheStepStream() throws {
    guard let real = try RealDay() else { return }
    func seen(at now: Date) -> MetricsResult {
        MetricsEngine.run(minutes: real.minutes.filter { $0.start.addingTimeInterval(60) <= now }, calendar: real.local, now: now)
    }
    // Asleep from 2:35. The sleep is only found at 3:20 (45 minutes), and the stream ran until 3:24. The newest minutes say
    // asleep by 2:55.
    let falling = seen(at: real.clock(22, 2 + 55.0 / 60))
    #expect(falling.unfinishedSleep == nil)
    #expect(MotionStreamPolicy.looksAsleep(falling.newestMinutesAsleep))
    // 9:20, a short wake in bed: the sleep has band minutes after it, but it isn't finished, so the stream stays off.
    let wake = try #require(seen(at: real.clock(22, 9 + 20.0 / 60)).unfinishedSleep)
    #expect(wake.hasEnded)
    // 12:10, up and about since 11:19: a few still minutes don't look like sleep.
    let noon = seen(at: real.clock(22, 12 + 10.0 / 60))
    #expect(noon.unfinishedSleep == nil)
    #expect(!MotionStreamPolicy.looksAsleep(noon.newestMinutesAsleep))
}

@Test func theRealHealthMonitorIsStillLearning() throws {
    guard let real = try RealDay() else { return }
    let days = real.contents.days.sorted { $0.date < $1.date }
    let today = try #require(days.last)
    let earlier = days.dropLast().compactMap(\.hrvRMSSD)
    // 4 earlier nights: no range yet. The 3-night rule flagged this night (80.2 ms against 69.7 to 75.9) as out of range.
    #expect(earlier.count == 4)
    #expect(HealthMonitor.reading(try #require(today.hrvRMSSD), history: earlier, minSpread: 5) == nil)
}
