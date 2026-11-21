import Foundation
import Testing
@testable import PulseCore

// Steps on the 100 Hz stream during a step test (docs/METRICS.md §15).

private let start: UInt32 = 1_795_000_000

private func packets(seconds: Int, stepHz: Double, ampG: Double = 0.25, from first: UInt32 = start) -> [Whoop.RawMotion] {
    walkPackets(seconds: seconds, stepHz: stepHz, ampG: ampG, from: first)
}

private func date(_ second: UInt32) -> Date { Date(timeIntervalSince1970: Double(second)) }

@Test func aSteadyWalkOnTheStreamIsCountedExactly() {
    var live = LiveSteps()
    for packet in packets(seconds: 300, stepHz: 1.8) { live.add(packet) }
    // 540 steps in 5 minutes; OpenStrap's count is exact on clean walking, give or take the first and last step.
    let counted = live.steps(from: date(start), to: date(start + 300))
    #expect(abs(counted - 540) <= 2, "\(counted)")
    #expect(live.coverage(from: date(start), to: date(start + 300)) == 1)
    #expect(abs((live.medianG ?? 0) - 1) < 0.05)
}

@Test func aStillWristOnTheStreamHasNoSteps() {
    var live = LiveSteps()
    for packet in packets(seconds: 60, stepHz: 1.8, ampG: 0) { live.add(packet) }
    #expect(live.steps(from: date(start), to: date(start + 60)) == 0)
}

@Test func aMissingSecondSplitsTheWalkAndOnlyTheWindowCounts() {
    var live = LiveSteps()
    let walk = packets(seconds: 120, stepHz: 2)
    for packet in walk where packet.timestamp != start + 60 { live.add(packet) }
    #expect(live.runs(from: date(start), to: date(start + 120)).map(\.count) == [60, 59])
    // Each half re-earns OpenStrap's 8 confirming steps, so a gap costs nothing it can count.
    let counted = live.steps(from: date(start), to: date(start + 120))
    #expect(abs(counted - 238) <= 4, "\(counted)")
    #expect(abs(live.coverage(from: date(start), to: date(start + 120)) - 119.0 / 120) < 1e-9)
    // Only the window's seconds count.
    #expect(live.steps(from: date(start), to: date(start + 30)) < counted / 3)
}

@Test func aSecondSentTwiceCountsOnce() {
    var live = LiveSteps()
    let walk = packets(seconds: 60, stepHz: 1.8)
    for packet in walk + walk { live.add(packet) }
    #expect(live.seconds.count == 60)
    let once = LiveSteps(walk)
    #expect(live.steps(from: date(start), to: date(start + 60)) == once.steps(from: date(start), to: date(start + 60)))
}

private extension LiveSteps {
    init(_ packets: [Whoop.RawMotion]) {
        self.init()
        for packet in packets { add(packet) }
    }
}
