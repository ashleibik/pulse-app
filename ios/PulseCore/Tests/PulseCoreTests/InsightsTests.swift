import Foundation
import Testing
@testable import PulseCore

// `computed`, `dataset`, `utcCalendar` come from MetricsTests.swift / FakeDataGeneratorTests.swift.

// MARK: - Recovery breakdown

@Test func breakdownReproducesTheStoredScore() throws {
    // The "why" screen rebuilds the score from stored summaries. It must agree with the number on Today.
    var checked = 0
    for day in computed.days {
        guard let stored = day.recoveryScore else { continue }
        let b = try #require(RecoveryExplainer.breakdown(for: day, history: computed.days))
        // Only difference: sleep need is stored rounded to whole minutes.
        #expect(abs(b.components.score - stored) < 0.5, "\(day.date): \(b.components.score) vs \(stored)")
        checked += 1
    }
    #expect(checked >= 25)
}

@Test func breakdownFactorsPointTheRightWay() {
    let c = RecoveryComponents(zHRV: 1.5, zRHR: -1.0, zSleep: -2.0)
    #expect(c.hrvPoints > 0)            // HRV above normal helps
    #expect(c.restingHRPoints > 0)      // resting HR below normal helps
    #expect(c.sleepPoints < 0)          // short sleep hurts
    let atNormal = RecoveryComponents(zHRV: 0, zRHR: 0, zSleep: 0)
    #expect(atNormal.score == 50)
    #expect(atNormal.hrvPoints == 0)
}

@Test func breakdownNeedsABaseline() {
    #expect(RecoveryExplainer.breakdown(for: computed.days[2], history: computed.days) == nil)
}

@Test func breakdownSortsByBiggestEffect() throws {
    let day = try #require(computed.days.last)
    let factors = try #require(RecoveryExplainer.breakdown(for: day, history: computed.days)).factors
    #expect(factors.count == 3)
    #expect(zip(factors, factors.dropFirst()).allSatisfy { abs($0.points) >= abs($1.points) })
    #expect(factors.first { $0.kind == .hrv }!.detail.contains("vs your normal"))
}

// MARK: - Strain guidance

@Test func strainTargetsFollowRecovery() {
    #expect(StrainGuidance.targetRange(recovery: 80) == 14...18)
    #expect(StrainGuidance.targetRange(recovery: 50) == 10...14)
    #expect(StrainGuidance.targetRange(recovery: 20) == 0...10)
    #expect(StrainGuidance.targetRange(recovery: nil) == 8...12)
    #expect(StrainGuidance.status(strain: 5, target: 10...14) == .below)
    #expect(StrainGuidance.status(strain: 12, target: 10...14) == .onTarget)
    #expect(StrainGuidance.status(strain: 15, target: 10...14) == .above)
    #expect(StrainGuidance.advice(strain: 4, recovery: 80) == "Aim for a strain of 14–18 today.")
    #expect(StrainGuidance.advice(strain: 4, recovery: 20) == "Rest is the goal today. Keep strain under 10.")
}

// MARK: - Sleep timeline

@Test func sleepTimelineCoversTheNight() throws {
    let night = try #require(computed.sleeps.first { !$0.isNap })
    let segments = SleepTimeline.build(minutes: dataset.minutes, from: night.start, to: night.end)
    #expect(!segments.isEmpty)
    #expect(segments.first?.start == night.start)
    #expect(segments.last?.end == night.end)
    // contiguous, no overlaps, neighbours differ
    for (a, b) in zip(segments, segments.dropFirst()) {
        #expect(a.end == b.start)
        #expect(a.phase != b.phase)
    }
    let totals = SleepTimeline.totals(segments)
    #expect(totals.values.reduce(0, +) == night.inBedMinutes)
    #expect((totals[.restful] ?? 0) > 30)
    #expect((totals[.light] ?? 0) > 30)
    // awake minutes in the timeline should be in the same ballpark as the session's
    #expect(abs((totals[.awake] ?? 0) - night.awakeMinutes) <= night.awakeMinutes + 10)
}

@Test func smoothingAbsorbsBlips() {
    let p: [SleepPhase] = [.restful, .restful, .restful, .light, .restful, .restful, .awake, .light, .light, .light]
    #expect(SleepTimeline.smooth(p) == [.restful, .restful, .restful, .restful, .restful, .restful, .awake, .light, .light, .light])
}

// MARK: - Zones + sleep need

@Test func heartRateZones() {
    #expect(HeartRateZones.zone(for: 90, maxHeartRate: 190) == nil)      // 47%
    #expect(HeartRateZones.zone(for: 100, maxHeartRate: 190) == 0)       // 53%
    #expect(HeartRateZones.zone(for: 160, maxHeartRate: 190) == 3)       // 84%
    #expect(HeartRateZones.zone(for: 200, maxHeartRate: 190) == 4)       // above max still Z5
    #expect(HeartRateZones.minutesPerZone([100, 100, nil, 160, 60], maxHeartRate: 190) == [2, 0, 0, 1, 0])
}

@Test func sleepNeedBreakdownAddsUp() {
    let b = SleepNeedBreakdown(goal: 480, previousStrain: 15, previousNeed: 480, previousAsleep: 400)
    #expect(b.strainExtra == 30 && b.debtExtra == 40 && b.total == 550)
    #expect(b.total == Recovery.sleepNeed(goal: 480, previousStrain: 15, previousNeed: 480, previousAsleep: 400))
    #expect(SleepNeedBreakdown(goal: 480, previousStrain: 21, previousNeed: 600, previousAsleep: 0).total == 600)
}

// MARK: - Trends

func day(_ i: Int, recovery: Double?, sleep: Int?, hrv: Double?, rhr: Double?, strain: Double = 10) -> DailySummary {
    DailySummary(date: Date(timeIntervalSince1970: Double(i) * 86_400), recoveryScore: recovery, strain: strain,
                 sleepMinutes: sleep, sleepNeedMinutes: 480, restingHeartRate: rhr, hrvRMSSD: hrv,
                 baselineRestingHeartRate: nil, baselineHRV: nil, explanation: "", source: .simulated)
}

@Test func compareThisWeekWithLastWeek() {
    let days = (0..<14).map { day($0, recovery: 50, sleep: 450, hrv: $0 < 7 ? 50 : 60, rhr: 55) }
    let c = TrendInsights.compare(days.shuffled(), period: 7, \.hrvRMSSD)
    #expect(c.current == 60 && c.previous == 50 && c.delta == 10)
}

@Test func insightsNeedTwoWeeks() {
    let days = (0..<10).map { day($0, recovery: 50, sleep: 450, hrv: 60, rhr: 55) }
    #expect(TrendInsights.insights(days).map(\.id) == ["learning"])
}

@Test func insightsSpotPatterns() {
    // Long nights -> high recovery; HRV up 20% in the last week; resting HR down 3 bpm.
    let days = (0..<21).map { i in
        day(i, recovery: i % 2 == 0 ? 75 : 40, sleep: i % 2 == 0 ? 470 : 360,
            hrv: i < 14 ? 50 : 60, rhr: i < 14 ? 56 : 53)
    }
    let ids = TrendInsights.insights(days).map(\.id)
    #expect(ids.contains("sleep-recovery"))
    #expect(ids.contains("hrv-trend"))
    #expect(ids.contains("rhr-trend"))
    let hrv = TrendInsights.insights(days).first { $0.id == "hrv-trend" }!
    #expect(hrv.tone == .positive && hrv.detail.contains("up 20%"))
}

@Test func insightsOnSimulatedMonth() {
    let found = TrendInsights.insights(computed.days)
    #expect((1...4).contains(found.count))
    #expect(!found.contains { $0.id == "learning" })
}
