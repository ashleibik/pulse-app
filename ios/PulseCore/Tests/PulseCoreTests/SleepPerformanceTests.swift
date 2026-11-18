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

    @Test func healthMonitorNeedsAHistoryAndAllowsTheUsualSpread() {
        #expect(HealthMonitor.withinRange(60, history: [58, 61], minSpread: 2) == nil)
        #expect(HealthMonitor.withinRange(60, history: [58, 60, 62, 59], minSpread: 2) == true)
        #expect(HealthMonitor.withinRange(70, history: [58, 60, 62, 59], minSpread: 2) == false)
    }
}
