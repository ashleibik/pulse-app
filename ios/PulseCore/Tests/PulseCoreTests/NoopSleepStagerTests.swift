import Foundation
import Testing
@testable import PulseCore

// NOOP's sleep stager (docs/METRICS.md §12).

private typealias Stager = NoopSleepStager

/// A made-up four-hour night that is the same on every machine.
private func madeUpNight(start: Int) -> Stager.Input {
    var input = Stager.Input()
    var seed: UInt64 = 42
    func noise() -> Double {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(seed >> 40) / Double(1 << 24)
    }
    for t in -400..<(4 * 3600 + 400) {
        let time = Double(t)
        let rate = 58 + 6 * sin(2 * .pi * time / 5400) + 3 * sin(2 * .pi * time / 97) + 2 * noise()
        input.heartRate.append((start + t, rate.rounded()))
        let burst = (t + 4000) % 1800 < 20 ? 0.4 : 0
        input.jerk.append((start + t, 0.004 + 0.004 * noise() + burst))
        let breathing = 0.25 + 0.08 * sin(2 * .pi * time / 7200)
        input.beats.append((start + t, (1000 + 60 * sin(2 * .pi * breathing * time) + 20 * noise()).rounded()))
    }
    return input
}

/// Each stage and how many epochs it lasts, in order.
private func runs(_ stages: [Stager.Stage]) -> String {
    var out: [String] = []
    var index = 0
    while index < stages.count {
        var end = index
        while end < stages.count, stages[end] == stages[index] { end += 1 }
        out.append("\(stages[index])\(end - index)")
        index = end
    }
    return out.joined(separator: " ")
}

/// The expected value comes from running NOOP's original SleepStagerV2.swift on this same night.
@Test func theStagesMatchNoopsOwnCodeOnAKnownNight() {
    let start = 1_790_000_010
    let epochs = Stager.stage(start: start, end: start + 4 * 3600, input: madeUpNight(start: start), breathingRhythm: true)
    #expect(epochs.count == 480)
    #expect(epochs.first?.start == 1_790_000_010 + 0)
    #expect(runs(epochs.map(\.stage)) == noopOriginalRuns)
}

@Test func theBreathingTermIsOffAsInNoopsSleepLabTest() {
    let start = 1_790_000_010
    let input = madeUpNight(start: start)
    var withoutBeats = input
    withoutBeats.beats = []
    let off = Stager.stage(start: start, end: start + 4 * 3600, input: input)
    #expect(off == Stager.stage(start: start, end: start + 4 * 3600, input: withoutBeats))
    #expect(off != Stager.stage(start: start, end: start + 4 * 3600, input: input, breathingRhythm: true))
}

@Test func theRemGuardFadesOverTheFirstHourAfterSleepOnset() {
    #expect(Stager.remLatencyGuard(0) == 3)
    #expect(Stager.remLatencyGuard(30) == 1.5)
    #expect(Stager.remLatencyGuard(60) == 0)
    #expect(Stager.remLatencyGuard(200) == 0)
    #expect(Stager.remLatencyGuard(-500) == 3)                  // before onset, never harder than at onset
    #expect(Stager.remLatencyGuard(.infinity) == 0)
}

@Test func deepComesEarlyAndRemComesLate() {
    let early = Stager.cyclePrior(0, .infinity), late = Stager.cyclePrior(1, .infinity)
    #expect(early[Stager.Stage.deep.rawValue] == 1.2 && late[Stager.Stage.deep.rawValue] == 0)
    #expect(early[Stager.Stage.rem.rawValue] == 0 && late[Stager.Stage.rem.rawValue] == 1)
}

@Test func sleepOnsetNeedsFiveMinutesWithoutWaking() {
    let awake = [Stager.Stage](repeating: .awake, count: 3)
    let short = [Stager.Stage](repeating: .light, count: 9)
    let long = [Stager.Stage](repeating: .light, count: 10)
    #expect(Stager.sustainedSleepOnset(awake + short + awake) == nil)
    #expect(Stager.sustainedSleepOnset(awake + short + awake + long) == 15)
}

@Test func nobodyGoesStraightFromAwakeIntoRem() {
    // One epoch of weak REM evidence right after a long wake isn't enough to jump there.
    var emissions = [[Double]](repeating: [-9, -9, -9, 0], count: 20)
    emissions += [[-9, -1, -2, -9]]
    emissions += [[Double]](repeating: [-9, -9, 0, -9], count: 5)
    let path = Stager.viterbi(emissions)
    #expect(path[20] != .rem)
    #expect(path.count == 26)
}

@Test func tiesGoToTheEarlierStage() {
    #expect(Stager.viterbi([[0, 0, 0, 0]]) == [.deep])
    #expect(Stager.viterbi([]).isEmpty)
}

@Test func steadyBreathingScoresMoreRegularThanNoise() throws {
    var tables: [Int: Stager.RespDFT] = [:]
    let steady = (0..<210).map { (Double($0), 1000 + 50 * sin(2 * .pi * 0.25 * Double($0))) }
    var seed: UInt64 = 7
    let noisy = (0..<210).map { t -> (Double, Double) in
        seed = seed &* 6_364_136_223_846_793_005 &+ 1
        return (Double(t), 1000 + Double(seed >> 58) * 3)
    }
    let regular = try #require(Stager.respRegularity(steady, tables: &tables))
    let irregular = try #require(Stager.respRegularity(noisy, tables: &tables))
    #expect(regular > irregular)
    #expect(Stager.respRegularity(Array(steady.prefix(11)), tables: &tables) == nil)
}

private func minute(_ start: Int, hr: UInt8, rr: [UInt16], activity: UInt8 = 4, angle: [UInt8]? = nil) -> MinuteSample {
    MinuteSample(start: Date(timeIntervalSince1970: Double(start)), heartRate: [UInt8](repeating: hr, count: 60), rrIntervalsMs: rr,
                 activity: [UInt8](repeating: activity, count: 60), source: .history, wristAngle: angle)
}

@Test func beatsAreTimedFromTheStartOfTheMinuteAndFillerIsLeftOut() {
    let input = Stager.input(from: [minute(600, hr: 60, rr: [1000, 500, 1000, 100, 1500])])
    #expect(input.beats.map(\.second) == [601, 602, 603])
    #expect(input.beats.map(\.ms) == [1000, 1000, 1500])
    #expect(input.heartRate.count == 60)
}

@Test func olderMinutesUseTheBandsActivityForMovement() {
    let input = Stager.input(from: [minute(600, hr: 60, rr: [], activity: 5)])
    #expect(input.jerk.count == 60)
    #expect(input.jerk.allSatisfy { abs($0.value - 0.01) < 1e-12 })
}

@Test func newMinutesUseHowFarTheWristTurned() throws {
    var angle = [UInt8](repeating: 10, count: 60)                // one degree a second
    angle[0] = WristAngle.noReading
    let input = Stager.input(from: [minute(600, hr: 60, rr: [], activity: 200, angle: angle)])
    #expect(input.jerk.count == 59)
    #expect(input.jerk.first?.second == 601)
    #expect(abs(try #require(input.jerk.first?.value) - 2 * sin(.pi / 360)) < 1e-12)
}

@Test func aMinuteOffTheWristAddsNothing() {
    let off = MinuteSample(start: Date(timeIntervalSince1970: 600), heartRate: [UInt8](repeating: 0, count: 60), rrIntervalsMs: [],
                           activity: [UInt8](repeating: 0, count: 60), source: .history)
    let input = Stager.input(from: [off])
    #expect(input.heartRate.isEmpty && input.jerk.isEmpty && input.beats.isEmpty)
    #expect(Stager.stage(start: 600, end: 660, input: input).isEmpty)
}

@Test func aStillNightNeverDividesByAZeroMovementFloor() {
    var input = madeUpNight(start: 3_000)
    input.jerk = input.jerk.map { ($0.second, 0) }
    let features = Stager.features(start: 3_000, end: 6_000, input: input)
    #expect(features.allSatisfy { $0.jerkScale == Stager.smallestJerk && $0.moveFrac == 0 })
}

@Test func stagesOnlySplitTheMinutesPulseCallsAsleep() throws {
    // Nine quiet hours with one clear wake-up: the awake minutes stay awake, and the rest add up.
    let start = 1_790_000_040
    var minutes: [MinuteSample] = []
    for index in 0..<540 {
        let waking = (200..<215).contains(index)
        let rate = UInt8(waking ? 90 : 56 + (index / 40) % 6)
        let beats = [UInt16](repeating: UInt16(60_000 / Int(rate)), count: Int(rate))
        minutes.append(minute(start + index * 60, hr: rate, rr: beats, activity: waking ? 120 : 1))
    }
    let from = Date(timeIntervalSince1970: Double(start)), to = from.addingTimeInterval(540 * 60)
    let segments = SleepTimeline.build(minutes: minutes, from: from, to: to)
    let totals = SleepTimeline.totals(segments)
    #expect(totals.values.reduce(0, +) == 540)
    #expect((totals[.awake] ?? 0) >= 15)
    #expect(segments.first { $0.phase == .awake }?.start == from.addingTimeInterval(200 * 60))
}

private let noopOriginalRuns = "light17 deep42 light47 awake2 light5 deep15 light38 awake2 light10 rem48 awake2 light31 rem22 light5 awake2 light22 deep7 light21 rem8 awake2 light1 rem57 awake2 light1 rem53 light4 awake2 light12"
