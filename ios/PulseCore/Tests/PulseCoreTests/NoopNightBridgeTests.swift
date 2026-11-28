// NOOP's own tests of the bridge, Packages/StrandAnalytics/Tests/StrandAnalyticsTests/BridgedNightGroupsTests.swift
// at commit 2a1de7609843b095505274ad6fc811757210be80 (PolyForm Noncommercial License 1.0.0, Copyright 2026 NoopApp),
// with the same inputs and expected groups. The two that test NOOP's main-night pick are left out: Pulse doesn't port it.

import Foundation
import Testing
@testable import PulseCore

private typealias B = NoopNightBridge.NightBlock
private typealias Gap = NoopNightBridge.BridgedNightGroup.GapSpan
/// 2026-01-02 00:00:00 UTC: the fixtures read as local clock times with offsetSec 0.
private let t0 = 1_767_312_000

@Test func noopShortWakeBridgesTwoFragmentsWithOneGap() {
    let a = B(start: t0 - 3_600, end: t0 + 2 * 3_600)
    let b = B(start: t0 + 2 * 3_600 + 16 * 60, end: t0 + 6 * 3_600)
    let groups = NoopNightBridge.bridgedNightGroups([a, b], offsetSec: 0)
    #expect(groups.count == 1)
    #expect(groups[0].indices == [0, 1])
    #expect(groups[0].gaps == [Gap(start: a.end, end: b.start)])
}

@Test func noopDaytimeNapStaysItsOwnGroup() {
    let night = B(start: t0 - 3_600, end: t0 + 6 * 3_600)
    let nap = B(start: t0 + 14 * 3_600, end: t0 + 15 * 3_600)
    let groups = NoopNightBridge.bridgedNightGroups([night, nap], offsetSec: 0)
    #expect(groups.map(\.indices) == [[0], [1]])
    #expect(groups.allSatisfy { $0.gaps.isEmpty })
}

@Test func noopNightTailBridgesOvernightGapOverSixtyMinutes() {
    let a = B(start: t0 - 3_600, end: t0 + 3 * 3_600)
    let b = B(start: t0 + 3 * 3_600 + 75 * 60, end: t0 + 7 * 3_600)
    let groups = NoopNightBridge.bridgedNightGroups([a, b], offsetSec: 0)
    #expect(groups.map(\.indices) == [[0, 1]])
    #expect(groups[0].gaps == [Gap(start: a.end, end: b.start)])
}

@Test func noopDaytimeGapOverSixtyMinutesDoesNotBridge() {
    let a = B(start: t0 + 9 * 3_600, end: t0 + 12 * 3_600)
    let b = B(start: t0 + 12 * 3_600 + 75 * 60, end: t0 + 14 * 3_600)
    #expect(NoopNightBridge.bridgedNightGroups([a, b], offsetSec: 0).map(\.indices) == [[0], [1]])
}

@Test func noopThreeFragmentNightYieldsTwoGaps() {
    let a = B(start: t0, end: t0 + 3_600)
    let b = B(start: t0 + 3_600 + 600, end: t0 + 2 * 3_600)
    let c = B(start: t0 + 2 * 3_600 + 900, end: t0 + 3 * 3_600)
    let groups = NoopNightBridge.bridgedNightGroups([a, b, c], offsetSec: 0)
    #expect(groups.map(\.indices) == [[0, 1, 2]])
    #expect(groups[0].gaps == [Gap(start: a.end, end: b.start), Gap(start: b.end, end: c.start)])
}

@Test func noopOverlappingFragmentStartsItsOwnGroup() {
    let a = B(start: t0, end: t0 + 4 * 3_600)
    let b = B(start: t0 + 3_600, end: t0 + 2 * 3_600)
    let groups = NoopNightBridge.bridgedNightGroups([a, b], offsetSec: 0)
    #expect(groups.map(\.indices) == [[0], [1]])
    #expect(groups.allSatisfy { $0.gaps.isEmpty })
}

@Test func noopZeroGapBridgesWithoutSeam() {
    let a = B(start: t0, end: t0 + 3_600)
    let b = B(start: t0 + 3_600, end: t0 + 2 * 3_600)
    let groups = NoopNightBridge.bridgedNightGroups([a, b], offsetSec: 0)
    #expect(groups.map(\.indices) == [[0, 1]])
    #expect(groups[0].gaps.isEmpty)
}

@Test func noopUnsortedInputIndicesReferToOriginalPositions() {
    let late = B(start: t0 + 2 * 3_600 + 16 * 60, end: t0 + 6 * 3_600)
    let early = B(start: t0 - 3_600, end: t0 + 2 * 3_600)
    let groups = NoopNightBridge.bridgedNightGroups([late, early], offsetSec: 0)
    #expect(groups.map(\.indices) == [[0, 1]])
    #expect(groups[0].gaps == [Gap(start: early.end, end: late.start)])
}

@Test func noopEmptyInputYieldsNoGroups() {
    #expect(NoopNightBridge.bridgedNightGroups([], offsetSec: 0).isEmpty)
}

@Test func noopRealNightFirstSleepFragmentBridgesIntoMainGroup() {
    let off = -25_200
    let fragment = B(start: 1_784_013_364, end: 1_784_017_375)
    let mainEffective = B(start: 1_784_017_740, end: 1_784_039_558)
    let groups = NoopNightBridge.bridgedNightGroups([fragment, mainEffective], offsetSec: off)
    #expect(groups.map(\.indices) == [[0, 1]])
    #expect(groups[0].gaps == [Gap(start: fragment.end, end: mainEffective.start)])
}
