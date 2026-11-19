import Foundation
import Testing
@testable import PulseCore

// Replays the owner's real night of 2026-11-17/18 from their own backup. The backup holds raw heart-rate
// data, so it stays in logs/ and is never committed: on any machine without the file these tests are skipped.
// SleepConfirmationTests covers the same rules with made-up minutes on every machine.

private let backupURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("logs/pulse-backup-2026-11-18.json")

private let hasBackup = FileManager.default.fileExists(atPath: backupURL.path)

/// The night happened at UTC-6.
private var localCalendar: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(secondsFromGMT: -6 * 3600)!
    return c
}

private func clock(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
    localCalendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
}

private func text(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.calendar = localCalendar
    formatter.timeZone = localCalendar.timeZone
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: date)
}

private struct Backup {
    let minutes: [MinuteSample]
    let exportedAt: Date
    let corrections: [SleepCorrection]
}

private func loadBackup() throws -> Backup {
    var data: Data? = try Data(contentsOf: backupURL)
    let reader = try PulseBackup.Reader(chunks: { defer { data = nil }; return data })
    var minutes: [MinuteSample] = []
    while let minute = try reader.nextMinute() { minutes.append(minute) }
    return Backup(minutes: minutes, exportedAt: reader.contents.header.exportedAt,
                  corrections: reader.contents.sleepCorrections)
}

private func close(_ date: Date, to expected: Date, minutes: Double = 15) -> Bool {
    abs(date.timeIntervalSince(expected)) <= minutes * 60
}

@Test(.enabled(if: hasBackup)) func theRealNightIsOneSleepFromAbout1250To1015() throws {
    let backup = try loadBackup()
    let result = MetricsEngine.run(minutes: backup.minutes, calendar: localCalendar, now: backup.exportedAt)
    #expect(result.sleeps.count == 1)
    let night = try #require(result.sleeps.first)
    #expect(close(night.start, to: clock(18, 0, 50)), "started \(text(night.start))")
    #expect(close(night.end, to: clock(18, 10, 15)), "ended \(text(night.end))")
    #expect(!night.isNap)
    // The wake-up around 06:40 is inside the night and is counted as awake.
    let segments = SleepTimeline.build(minutes: backup.minutes, from: night.start, to: night.end)
    #expect(segments.contains { $0.phase == .awake && $0.start >= clock(18, 6, 35) && $0.end <= clock(18, 7, 5) })

    let summary = try #require(result.days.first { localCalendar.isDate($0.date, inSameDayAs: night.end) })
    print("RECOMPUTED \(text(night.start))-\(text(night.end)) asleep \(night.asleepMinutes) awake \(night.awakeMinutes) "
        + "wake-ups \(night.disturbances) resting HR \(summary.restingHeartRate ?? -1) HRV \(summary.hrvRMSSD ?? -1) "
        + "review \(night.reviewReason?.rawValue ?? "none")")
}

@Test(.enabled(if: hasBackup)) func theRealEveningAtTheComputerIsNotSleep() throws {
    let backup = try loadBackup()
    let evening = backup.minutes.filter { $0.start < clock(18, 0, 30) }
    // Eight hours later, so nothing can be waiting to finish.
    let found = MetricsEngine.run(minutes: evening, calendar: localCalendar, now: clock(18, 8, 30)).sleeps
    #expect(found.isEmpty, "found \(found.map { "\(text($0.start))-\(text($0.end))" })")
}

@Test(.enabled(if: hasBackup)) func theRealNightIsNotShownWhileItIsStillGoing() throws {
    let backup = try loadBackup()
    var now = clock(18, 1, 0)
    while now <= clock(18, 10, 0) {
        let moment = now
        let soFar = backup.minutes.filter { $0.start < moment }
        let found = MetricsEngine.run(minutes: soFar, calendar: localCalendar, now: moment).sleeps
        #expect(found.isEmpty, "at \(text(moment)): \(found.map { "\(text($0.start))-\(text($0.end))" })")
        now = now.addingTimeInterval(15 * 60)
    }
}

@Test(.enabled(if: hasBackup)) func theRealNightsPhasesAddUpToItsHeadline() throws {
    let backup = try loadBackup()
    let night = try #require(MetricsEngine.run(minutes: backup.minutes, calendar: localCalendar, now: backup.exportedAt).sleeps.first)
    let totals = SleepTimeline.totals(SleepTimeline.build(minutes: backup.minutes, from: night.start, to: night.end))
    #expect((totals[.light] ?? 0) + (totals[.restful] ?? 0) == night.asleepMinutes)
    #expect((totals[.awake] ?? 0) == night.awakeMinutes)
    #expect(night.asleepMinutes + night.awakeMinutes == Int(night.end.timeIntervalSince(night.start) / 60))
}

@Test(.enabled(if: hasBackup)) func aHoleInTheRealNightIsUnknownAndKeepsItOneSleep() throws {
    let backup = try loadBackup()
    let hole = clock(18, 3, 0)..<clock(18, 3, 40)
    let holed = backup.minutes.filter { !hole.contains($0.start) }
    let result = MetricsEngine.run(minutes: holed, calendar: localCalendar, now: backup.exportedAt).sleeps
    #expect(result.count == 1)
    let night = try #require(result.first)
    #expect(night.unknownMinutes == 40)
    #expect(close(night.start, to: clock(18, 0, 50)) && close(night.end, to: clock(18, 10, 15)))
    print("RECOMPUTED with a 40 minute hole: \(text(night.start))-\(text(night.end)) asleep \(night.asleepMinutes) awake \(night.awakeMinutes) unknown \(night.unknownMinutes)")
}

@Test(.enabled(if: hasBackup)) func learningStartsOnTheThirdCopyOfTheRealNight() throws {
    let backup = try loadBackup()
    func copies(_ count: Int) -> [MinuteSample] {
        (0..<count).flatMap { day in
            backup.minutes.map {
                MinuteSample(start: $0.start.addingTimeInterval(Double(day) * 86_400), heartRate: $0.heartRate,
                             rrIntervalsMs: $0.rrIntervalsMs, activity: $0.activity, source: $0.source)
            }
        }
    }
    let now = backup.exportedAt.addingTimeInterval(5 * 86_400)
    let nights = MetricsEngine.run(minutes: copies(5), calendar: localCalendar, now: now).sleeps
    #expect(nights.count == 5)
    for (day, night) in nights.enumerated() {
        let shift = Double(day) * 86_400
        #expect(close(night.start, to: clock(18, 0, 50).addingTimeInterval(shift)), "night \(day) started \(text(night.start))")
        #expect(close(night.end, to: clock(18, 10, 15).addingTimeInterval(shift)), "night \(day) ended \(text(night.end))")
    }
    print("RECOMPUTED five copies: " + nights.map { "\(text($0.start))-\(text($0.end))" }.joined(separator: ", "))
}

@Test(.enabled(if: hasBackup)) func aRealDayAtADeskHasNoWorkouts() throws {
    let backup = try loadBackup()
    let found = WorkoutDetector.detect(minutes: backup.minutes, profile: MetricsProfile(maxHeartRate: 190)) { _ in 52.75 }
    print("RECOMPUTED workouts: " + found.map { "\($0.kind.rawValue) \(text($0.start))-\(text($0.end)) suggestion \($0.isSuggestion == true)" }.joined(separator: ", "))
    #expect(found.allSatisfy { $0.isSuggestion == true }, "the desk evening must not become a workout")
}

@Test(.enabled(if: hasBackup)) func theRealNightHasABelievableAmountOfRestfulSleep() throws {
    let backup = try loadBackup()
    let night = try #require(MetricsEngine.run(minutes: backup.minutes, calendar: localCalendar, now: backup.exportedAt).sleeps.first)
    let clock = ContinuousClock()
    var segments: [SleepSegment] = []
    let spent = clock.measure { segments = SleepTimeline.build(minutes: backup.minutes, from: night.start, to: night.end) }
    let totals = SleepTimeline.totals(segments)
    let restful = totals[.restful] ?? 0
    print("RECOMPUTED phases awake \(totals[.awake] ?? 0) light \(totals[.light] ?? 0) restful \(restful) in \(spent)")
    #expect((60...120).contains(restful), "restful \(restful) minutes")
    #expect((totals[.light] ?? 0) + restful == night.asleepMinutes)
}

@Test(.enabled(if: hasBackup)) func theRealNightsBreathingRateIsInTheNormalRange() throws {
    let backup = try loadBackup()
    let night = try #require(MetricsEngine.run(minutes: backup.minutes, calendar: localCalendar, now: backup.exportedAt).sleeps.first)
    let minutes = backup.minutes.filter { $0.start >= night.start && $0.start < night.end }
    let rate = RespiratoryRate.night(minutes: minutes)
    print("RECOMPUTED breathing \(rate.map { String(format: "%.1f", $0) } ?? "withheld") per minute")
    if let rate { #expect((9...24).contains(rate)) }
}

@Test(.enabled(if: hasBackup)) func theOwnersEditedBedtimeStaysAndTheMorningFollowsTheBetterDetection() throws {
    let backup = try loadBackup()
    #expect(backup.corrections.count == 1)
    let night = try #require(MetricsEngine.run(minutes: backup.minutes, calendar: localCalendar, now: backup.exportedAt,
                                               corrections: backup.corrections).sleeps.first)
    #expect(night.start == clock(18, 1, 0))
    #expect(close(night.end, to: clock(18, 10, 15)), "ended \(text(night.end))")
}

@Test(.enabled(if: hasBackup)) func theRealBeatsComeOutCleanForHRV() throws {
    let backup = try loadBackup()
    let beats = backup.minutes.map { $0.rrIntervalsMs.map { Double($0) } }
    #expect(beats.joined().contains(HRV.fillerRRMs))
    for minute in beats {
        let clean = HRV.cleanBeats(minute)
        #expect(!clean.contains(HRV.fillerRRMs))
        #expect(clean.compactMap { $0 }.allSatisfy { (HRV.rrMinMs...HRV.rrMaxMs).contains($0) })
        for (a, b) in zip(clean, clean.dropFirst()) {
            if let a, let b { #expect(abs(b - a) <= 0.20 * a) }
        }
    }
}

@Test(.enabled(if: hasBackup)) func theModelLearnsWhichSignalsSeparateThisPersonsSleep() throws {
    let backup = try loadBackup()
    let tl = try #require(MetricsEngine.timeline(backup.minutes))
    let measured = SleepModel.measurements(tl, calendar: localCalendar)
    let probability = SleepModel.probabilities(timeline: tl, calendar: localCalendar, corrections: [])
    let labels = SleepModel.labels(probability: probability, corrections: [], timeline: tl)
    let beats = try #require(SleepModel.learnedFromScratch(values: measured.cleanBeats, labels: labels, minimumSD: 3))
    let hrv = try #require(SleepModel.learnedFromScratch(values: measured.hrv, labels: labels, minimumSD: 0.1))
    func separation(_ s: SleepModel.Signal) -> Double { abs(s.asleep.mean - s.awake.mean) / max(s.asleep.sd, s.awake.sd) }
    // On this night clean beats tell sleep from wake far better than HRV does.
    #expect(separation(beats) > 3 * separation(hrv))
}
