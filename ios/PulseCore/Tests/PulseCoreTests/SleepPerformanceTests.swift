import Foundation
import Testing
@testable import PulseCore

struct SleepPerformanceTests {
    @Test func aFullNightIsScoredFromItsParts() {
        // 7h30 asleep, 30 min awake, 8h needed, consistency 80.
        let p = SleepPerformance.make(asleepMinutes: 450, awakeMinutes: 30, needMinutes: 480, consistency: 80)
        #expect(abs(p.hoursVsNeeded - 93.75) < 0.001)
        #expect(abs((p.efficiency ?? 0) - 93.75) < 0.001)
        #expect(abs(p.score - (93.75 * 0.6 + 93.75 * 0.2 + 80 * 0.2)) < 0.001)
        #expect(SleepPerformance.hoursLevel(p.hoursVsNeeded) == .optimal)
    }

    @Test func unknownPartsAreLeftOutNotCountedAsZero() {
        // First night: no consistency yet. Sleeping more than needed is capped at 100.
        let p = SleepPerformance.make(asleepMinutes: 540, awakeMinutes: 60, needMinutes: 480, consistency: nil)
        #expect(p.hoursVsNeeded == 100)
        #expect(abs(p.score - (100 * 0.6 + 90 * 0.2) / 0.8) < 0.001)
    }

    @Test func levelsFollowTheThresholds() {
        #expect(SleepPerformance.hoursLevel(69) == .poor)
        #expect(SleepPerformance.hoursLevel(70) == .sufficient)
        #expect(SleepPerformance.efficiencyLevel(95) == .optimal)
        #expect(SleepPerformance.stressLevel(0) == .optimal)
        #expect(SleepPerformance.stressLevel(30) == .poor)
    }

    @Test func clockDurationsForTiles() {
        #expect(PulseFormat.clock(minutes: 546) == "9:06")
        #expect(PulseFormat.clock(minutes: 45) == "0:45")
    }

    @Test func healthMonitorNeedsAWeekAndAllowsTheUsualSpread() {
        #expect(HealthMonitor.withinRange(60, history: [58, 61], minSpread: 2) == nil)
        #expect(HealthMonitor.withinRange(60, history: [58, 60, 62, 59, 61, 60], minSpread: 2) == nil)     // 6 nights
        let week: [Double] = [58, 60, 62, 59, 61, 60, 59]
        #expect(HealthMonitor.withinRange(60, history: week, minSpread: 2) == true)
        #expect(HealthMonitor.withinRange(70, history: week, minSpread: 2) == false)
        #expect(HealthMonitor.reading(70, history: week, minSpread: 2) == .high)
        #expect(HealthMonitor.reading(50, history: week, minSpread: 2) == .low)
    }

    @Test func theOwnersFirstNightsAreNotFlagged() {
        // HRV 2026-11-18 to 20, then 69.7 on 2026-11-21: with a 3-night range (the 5 ms floor) this read "Out of range".
        #expect(HealthMonitor.reading(69.7, history: [75.6, 73.4, 75.9], minSpread: 5) == nil)
    }

    @Test func theCardNamesWhatIsOutOfRange() {
        let checks = [HealthMonitor.Check(metric: .hrv, reading: .low),
                      HealthMonitor.Check(metric: .restingHeartRate, reading: .within),
                      HealthMonitor.Check(metric: .respiratoryRate, reading: .high)]
        #expect(HealthMonitor.flaggedText(checks) == "HRV low · Breathing high")
        #expect(HealthMonitor.flaggedText([HealthMonitor.Check(metric: .restingHeartRate, reading: .high)]) == "Resting HR high")
        #expect(HealthMonitor.flaggedText([HealthMonitor.Check(metric: .hrv, reading: .within)]) == nil)
        #expect(HealthMonitor.flaggedText([]) == nil)
    }
}
