import Foundation
import Testing
@testable import PulseCore

/// A fixed "now" so results never depend on when the tests run: 2026-06-15 20:00 UTC.
let fixedEnd: Date = {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    return cal.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 20))!
}()

let utc = TimeZone(identifier: "UTC")!
let config30 = FakeDataConfig(days: 30, seed: 42, endDate: fixedEnd, timeZone: utc)
/// Generated once and shared by all tests (it's the slow part).
let dataset = FakeDataGenerator.generate(config30)

// MARK: - Helpers

func inside(_ m: MinuteSample, _ ranges: [(Date, Date)]) -> Bool {
    ranges.contains { m.start >= $0.0 && m.start < $0.1 }
}

func rmssd(_ rr: [UInt16]) -> Double {
    guard rr.count > 2 else { return 0 }
    var sum = 0.0
    for i in 1..<rr.count {
        let d = Double(rr[i]) - Double(rr[i - 1])
        sum += d * d
    }
    return (sum / Double(rr.count - 1)).squareRoot()
}

func mean(_ xs: [Double]) -> Double { xs.reduce(0, +) / Double(max(xs.count, 1)) }

// MARK: - Shape of the data

@Test func producesOneSummaryAndOneNightPerDay() {
    #expect(dataset.days.count == 30)
    #expect(dataset.sleeps.count == 30)        // 20:00 "now": last night is complete
    #expect(dataset.workouts.count > 10)       // ~4-5 per week + walks
}

@Test func minutesAreContiguousAndNeverInTheFuture() throws {
    let minutes = dataset.minutes
    #expect(minutes.count > 29 * 1440)
    for (a, b) in zip(minutes, minutes.dropFirst()) {
        #expect(b.start.timeIntervalSince(a.start) == 60)
    }
    let last = try #require(minutes.last)
    #expect(last.start.addingTimeInterval(60) <= fixedEnd)
    #expect(dataset.workouts.allSatisfy { $0.end <= fixedEnd })
}

@Test func everyMinuteHas60Seconds() {
    #expect(dataset.minutes.allSatisfy { $0.heartRate.count == 60 && $0.activity.count == 60 })
    #expect(dataset.minutes.allSatisfy { $0.source == .simulated })
}

@Test func sameSeedSameData() {
    let small = FakeDataConfig(days: 3, seed: 7, endDate: fixedEnd, timeZone: utc)
    let a = FakeDataGenerator.generate(small)
    let b = FakeDataGenerator.generate(small)
    #expect(a.minutes == b.minutes)
    #expect(a.days == b.days)
    #expect(a.sleeps == b.sleeps)          // including the UUIDs
    #expect(a.workouts == b.workouts)
    let c = FakeDataGenerator.generate(FakeDataConfig(days: 3, seed: 8, endDate: fixedEnd, timeZone: utc))
    #expect(a.days != c.days)
}

@Test func summariesDoNotDependOnRawSamplesFlag() {
    var noRaw = config30
    noRaw.includeMinuteSamples = false
    let d = FakeDataGenerator.generate(noRaw)
    #expect(d.minutes.isEmpty)
    #expect(d.days == dataset.days)
    #expect(d.workouts == dataset.workouts)
}

// MARK: - Physiology looks right

@Test func sleepingHeartRateIsLowerThanDaytime() {
    let sleepRanges = dataset.sleeps.map { ($0.start, $0.end) }
    let workoutRanges = dataset.workouts.map { ($0.start, $0.end) }
    let sleepHR = dataset.minutes.filter { inside($0, sleepRanges) }.compactMap(\.averageHeartRate)
    let dayHR = dataset.minutes
        .filter { !inside($0, sleepRanges) && !inside($0, workoutRanges) }
        .compactMap(\.averageHeartRate)
    #expect(mean(sleepHR) + 8 < mean(dayHR))
    #expect((45...70).contains(mean(sleepHR)))
}

@Test func workoutsRaiseHeartRate() {
    let restingAverage = mean(dataset.days.compactMap(\.restingHeartRate))
    for w in dataset.workouts {
        #expect(Double(w.averageHeartRate) > restingAverage + 20)
        #expect(w.maxHeartRate >= w.averageHeartRate)
        #expect((0...21).contains(w.strain))
        #expect(w.zoneSeconds.count == 5)
        #expect(w.zoneSeconds.reduce(0, +) <= w.durationMinutes * 60)
    }
}

@Test func heartRateAndRRAgree() {
    // 60000 / mean RR should match the per-second HR (both come from the same heartbeats).
    let worn = dataset.minutes.filter { $0.isWorn && $0.rrIntervalsMs.count > 20 }
    for m in worn.prefix(2000) {
        let meanRR = mean(m.rrIntervalsMs.map { Double($0) })
        let hrFromRR = 60_000 / meanRR
        let hr = m.averageHeartRate ?? 0
        #expect(abs(hrFromRR - hr) / hr < 0.08, "minute \(m.start): HR \(hr) vs RR-derived \(hrFromRR)")
    }
}

@Test func overnightRMSSDMatchesTheTruth() {
    // This is a preview of Phase 3: compute RMSSD from raw RR and compare with the simulation's truth.
    for (sleep, day) in zip(dataset.sleeps, dataset.days) {
        let rr = dataset.minutes.filter { $0.start >= sleep.start && $0.start < sleep.end }.flatMap(\.rrIntervalsMs)
        let measured = rmssd(rr)
        let truth = day.hrvRMSSD ?? 0
        #expect(abs(measured - truth) / truth < 0.20, "night of \(sleep.start): measured \(measured), truth \(truth)")
    }
}

@Test func bandIsSometimesOffCharging() {
    let gaps = dataset.minutes.filter { !$0.isWorn }
    #expect(gaps.count >= 9 * 40)       // ~every third day, 40 minutes
    #expect(gaps.allSatisfy { $0.rrIntervalsMs.isEmpty })
}

@Test func recoveryScoresAreValid() {
    for d in dataset.days {
        let score = d.recoveryScore ?? -1
        #expect((0...100).contains(score))
        #expect(d.recoveryZone == RecoveryZone(score: score))
        #expect((0...21).contains(d.strain))
        #expect(!d.explanation.isEmpty)
    }
    // A month of data should show some variety in the traffic light.
    #expect(Set(dataset.days.compactMap(\.recoveryZone)).count >= 2)
}
