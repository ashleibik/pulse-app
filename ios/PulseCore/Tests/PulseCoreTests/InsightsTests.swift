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

@Test func factorDetailNeverShowsEqualNumbersForADifference() {
    #expect(RecoveryExplainer.comparison(68.2, 61.4, unit: "ms") == "68 ms vs your normal 61 ms")
    #expect(RecoveryExplainer.comparison(53.6, 54.4, unit: "bpm") == "53.6 bpm vs your normal 54.4 bpm")
    #expect(RecoveryExplainer.comparison(54.0, 54.02, unit: "bpm") == "54 bpm vs your normal 54 bpm")
}

@Test func oneLineNamesTheBiggestFactor() {
    func breakdown(_ kind: RecoveryFactor.Kind, _ points: Double) -> RecoveryBreakdown {
        RecoveryBreakdown(components: RecoveryComponents(zHRV: 0, zRHR: 0, zSleep: 0), factors: [
            RecoveryFactor(kind: kind, title: "", detail: "", points: points),
            RecoveryFactor(kind: .hrv, title: "", detail: "", points: 1),
        ])
    }
    #expect(RecoveryExplainer.oneLine(nil) == "Still learning your normal.")
    #expect(RecoveryExplainer.oneLine(breakdown(.sleep, -14)) == "You slept less than you needed.")
    #expect(RecoveryExplainer.oneLine(breakdown(.sleep, 6)) == "You slept as much as you needed.")
    #expect(RecoveryExplainer.oneLine(breakdown(.hrv, 12)) == "HRV is above your normal.")
    #expect(RecoveryExplainer.oneLine(breakdown(.hrv, -12)) == "HRV is below your normal.")
    // Positive points for resting HR mean it was LOWER than normal (the good direction).
    #expect(RecoveryExplainer.oneLine(breakdown(.restingHeartRate, 5)) == "Resting HR is below your normal.")
    #expect(RecoveryExplainer.oneLine(breakdown(.restingHeartRate, -5)) == "Resting HR is above your normal.")
    #expect(RecoveryExplainer.oneLine(breakdown(.sleep, -2)) == "Everything is close to your normal.")
}

@Test func oneLineStaysShortForEveryDemoDay() {
    // The Today screen gives this one line of space.
    for day in computed.days {
        let line = RecoveryExplainer.oneLine(RecoveryExplainer.breakdown(for: day, history: computed.days))
        #expect(line.count <= 36, "\(line)")
    }
}

@Test func recoveryZoneWords() {
    #expect(RecoveryZone(score: 80).word == "Ready")
    #expect(RecoveryZone(score: 50).word == "Steady")
    #expect(RecoveryZone(score: 10).word == "Rest")
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
    #expect((totals[.light] ?? 0) > 30)
    // awake minutes in the timeline should be in the same ballpark as the session's
    #expect(abs((totals[.awake] ?? 0) - night.awakeMinutes) <= night.awakeMinutes + 10)
}

@Test func smoothingAbsorbsBlips() {
    let p: [SleepPhase] = [.deep, .deep, .deep, .light, .deep, .deep, .awake, .awake, .awake, .light, .light, .light]
    #expect(SleepTimeline.smooth(p) == [.deep, .deep, .deep, .deep, .deep, .deep, .awake, .awake, .awake, .light, .light, .light])
}

@Test func aWakeUnderThreeMinutesIsNotAWakeUp() {
    let blip: [SleepPhase] = [.light, .light, .light, .awake, .awake, .rem, .rem, .rem]
    #expect(SleepTimeline.smooth(blip) == [.light, .light, .light, .light, .light, .rem, .rem, .rem])
    let real: [SleepPhase] = [.light, .light, .light, .awake, .awake, .awake, .rem, .rem, .rem]
    #expect(SleepTimeline.smooth(real) == real)
    // At either end of the measured minutes there is nothing to merge with.
    let edges: [SleepPhase] = [.awake, .light, .light, .light, .awake]
    #expect(SleepTimeline.smooth(edges) == edges)
}

@Test func aNightsTimeAxisIsEvenlySpacedWholeHours() {
    func at(_ hour: Int, _ minute: Int) -> Date { Date(timeIntervalSince1970: 1_750_032_000 + Double(hour * 3600 + minute * 60)) }
    // The owner's night of 2026-11-21 used to read "1:48 AM · 5 AM · 7 AM · 10:22 AM": gaps of 3h12, 2h and 3h22.
    #expect(SleepTimeline.axisTimes(from: at(1, 48), to: at(10, 22), calendar: utcCalendar) == [at(4, 0), at(6, 0), at(8, 0)])
    // Woken at 11:19: 10 AM is still 40 minutes in from the end.
    #expect(SleepTimeline.axisTimes(from: at(1, 47), to: at(11, 19), calendar: utcCalendar) == [at(4, 0), at(6, 0), at(8, 0), at(10, 0)])
    // 1:12 to 7:55: every 2 hours, on the even hours.
    #expect(SleepTimeline.axisTimes(from: at(1, 12), to: at(7, 55), calendar: utcCalendar) == [at(2, 0), at(4, 0), at(6, 0)])
    // A three-hour nap: every hour. 4 PM is 10 minutes from the end, inside the 11-minute margin.
    #expect(SleepTimeline.axisTimes(from: at(13, 5), to: at(16, 10), calendar: utcCalendar) == [at(14, 0), at(15, 0)])
    // Too short for a whole hour: its start and end.
    #expect(SleepTimeline.axisTimes(from: at(13, 5), to: at(13, 30), calendar: utcCalendar) == [at(13, 5), at(13, 30)])
}

@Test func nightAxisTicksAreEvenAndNeverCrowd() {
    // Every length from 20 minutes to 14 hours, starting on and off the hour.
    for offset in [0, 1800, 2820] {
        let start = Date(timeIntervalSince1970: 1_750_032_000 + Double(offset))
        for minutes in stride(from: 20, through: 14 * 60, by: 7) {
            let end = start.addingTimeInterval(Double(minutes) * 60)
            let length = end.timeIntervalSince(start)
            let times = SleepTimeline.axisTimes(from: start, to: end, calendar: utcCalendar)
            #expect(!times.isEmpty)
            if times == [start, end] { continue }                   // too short for a whole hour
            let gaps = zip(times, times.dropFirst()).map { $1.timeIntervalSince($0) }
            // Even: every gap the same whole number of hours, at least a fifth of the night.
            #expect(Set(gaps).count <= 1, "\(minutes) min: \(gaps)")
            for gap in gaps {
                #expect(gap >= SleepTimeline.axisHourSpacing * length - 1)
                #expect(SleepTimeline.axisStepHours.contains(Int(gap / 3600)) && gap.truncatingRemainder(dividingBy: 3600) == 0)
            }
            for time in times {
                #expect(utcCalendar.component(.minute, from: time) == 0)
                #expect(time.timeIntervalSince(start) >= SleepTimeline.axisEdgeMargin * length - 1)
                #expect(end.timeIntervalSince(time) >= SleepTimeline.axisEdgeMargin * length - 1)
            }
        }
    }
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

@Test func changeCaptionSaysDirectionAndWhetherItIsGood() {
    #expect(TrendInsights.changeCaption(3.2, higherIsBetter: true) == "▲ 3 better")
    #expect(TrendInsights.changeCaption(-4.0, higherIsBetter: true) == "▼ 4 worse")
    // Resting heart rate: going down is the good direction.
    #expect(TrendInsights.changeCaption(-2.0, higherIsBetter: false) == "▼ 2 better")
    #expect(TrendInsights.changeCaption(2.0, higherIsBetter: false) == "▲ 2 worse")
    #expect(TrendInsights.changeCaption(nil, higherIsBetter: true) == "no change")
    // A change that would print as "0" is "no change", not "▲ 0 better".
    #expect(TrendInsights.changeCaption(0.3, higherIsBetter: true) == "no change")
    #expect(TrendInsights.changeCaption(12.4, higherIsBetter: true,
                                        format: { PulseFormat.duration(minutes: Int($0.rounded())) }) == "▲ 12m better")
    #expect(TrendInsights.changeCaption(0.2, higherIsBetter: true,
                                        format: { PulseFormat.duration(minutes: Int($0.rounded())) }) == "no change")
}
