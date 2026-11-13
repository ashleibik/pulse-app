import Testing
@testable import PulseCore

@Test(arguments: [(0, "0m"), (45, "45m"), (60, "1h"), (460, "7h 40m")])
func formatsDurations(minutes: Int, expected: String) {
    #expect(PulseFormat.duration(minutes: minutes) == expected)
}

@Test func recoveryZoneThresholds() {
    #expect(RecoveryZone(score: 100) == .green)
    #expect(RecoveryZone(score: 67) == .green)
    #expect(RecoveryZone(score: 66.9) == .yellow)
    #expect(RecoveryZone(score: 34) == .yellow)
    #expect(RecoveryZone(score: 33.9) == .red)
    #expect(RecoveryZone(score: 0) == .red)
}

@Test func explanationReadsNaturally() {
    let text = PulseFormat.recoveryExplanation(hrv: 68, baselineHRV: 62, restingHR: 52, baselineRestingHR: 54,
                                               sleepMinutes: 460, sleepNeedMinutes: 480)
    #expect(text == "HRV is 10% above your baseline, and resting HR is down 2 bpm. You got 7h 40m of sleep.")
}

@Test func explanationFlagsShortSleep() {
    let text = PulseFormat.recoveryExplanation(hrv: 50, baselineHRV: 62, restingHR: 54, baselineRestingHR: 54,
                                               sleepMinutes: 330, sleepNeedMinutes: 480)
    #expect(text == "HRV is 19% below your baseline. You slept 5h 30m, short of the 8h you needed.")
}

@Test func explanationWithoutSleep() {
    let text = PulseFormat.recoveryExplanation(hrv: nil, baselineHRV: nil, restingHR: nil, baselineRestingHR: nil,
                                               sleepMinutes: nil, sleepNeedMinutes: 480)
    #expect(text == "No sleep was recorded last night.")
}
