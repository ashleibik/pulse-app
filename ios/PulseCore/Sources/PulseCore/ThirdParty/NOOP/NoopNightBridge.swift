// Ported to Swift for Pulse from NOOP, Packages/StrandAnalytics/Sources/StrandAnalytics/SleepStageTotals.swift
// (`bridgedNightGroups`, `isOvernightOnset`, `NightBlock`, `BridgedNightGroup` and their constants).
// Source: https://github.com/ryanbr/noop at commit 2a1de7609843b095505274ad6fc811757210be80
// License: PolyForm Noncommercial License 1.0.0 <https://polyformproject.org/licenses/noncommercial/1.0.0>
// Required Notice: Copyright 2026 NoopApp
//
// One addition for Pulse: an overload that looks up the time-zone offset at each sleep's start, because Pulse joins a
// whole history at once and NOOP passes one offset per day. With one offset it is NOOP's function unchanged. Which
// sleeps may join a night is Pulse's (docs/METRICS.md §4, step 8).

import Foundation

/// NOOP's gap bridge: sleeps separated by a short wake are one night.
enum NoopNightBridge {
    /// The overnight band [20:00, 11:00) local, for the wider night-tail bridge.
    static let overnightStartHour = 20
    static let overnightEndHour = 11
    static let secondsPerDay = 86_400
    /// Sleeps less than this many minutes apart are one night, at any time of day.
    static let gapBridgeMaxMin = 60
    /// Less than this many minutes apart, when the later sleep starts in the overnight band: a real mid-night wake.
    static let nightTailBridgeMaxMin = 90

    /// One sleep, in unix seconds.
    struct NightBlock: Equatable {
        let start: Int, end: Int
        init(start: Int, end: Int) { self.start = start; self.end = end }
    }

    /// One bridged night: the sleeps in it (indices into the input, ascending) and the wakes between them.
    struct BridgedNightGroup: Equatable {
        let indices: [Int]
        let gaps: [GapSpan]
        struct GapSpan: Equatable {
            let start: Int, end: Int
            init(start: Int, end: Int) { self.start = start; self.end = end }
        }
        init(indices: [Int], gaps: [GapSpan]) { self.indices = indices; self.gaps = gaps }
    }

    /// True when a sleep starting at `ts` starts in the overnight band. `offsetSec` is seconds east of UTC.
    static func isOvernightOnset(_ ts: Int, offsetSec: Int) -> Bool {
        let local = ts + offsetSec
        let secOfDay = ((local % secondsPerDay) + secondsPerDay) % secondsPerDay
        let hour = secOfDay / 3_600
        return hour >= overnightStartHour || hour < overnightEndHour
    }

    /// Every bridged night over `blocks`, ordered by start. A negative gap (a sleep starting inside the one before)
    /// does not bridge.
    static func bridgedNightGroups(_ blocks: [NightBlock], offsetSec: Int) -> [BridgedNightGroup] {
        bridgedNightGroups(blocks, offsetSec: { _ in offsetSec })
    }

    /// `bridgedNightGroups` with the offset looked up at each sleep's start (Pulse's addition, see the top of the file).
    static func bridgedNightGroups(_ blocks: [NightBlock], offsetSec: (Int) -> Int) -> [BridgedNightGroup] {
        guard !blocks.isEmpty else { return [] }
        let order = blocks.indices.sorted { blocks[$0].start < blocks[$1].start }
        let bridgeS = gapBridgeMaxMin * 60
        let nightTailBridgeS = nightTailBridgeMaxMin * 60
        var bridged: [NightBlock] = []
        var groups: [[Int]] = []
        var gaps: [[BridgedNightGroup.GapSpan]] = []
        for idx in order {
            let b = blocks[idx]
            if let last = bridged.last {
                let gap = b.start - last.end
                let bridges = gap >= 0
                    && (gap < bridgeS
                        || (gap < nightTailBridgeS && isOvernightOnset(b.start, offsetSec: offsetSec(b.start))))
                if bridges {
                    if gap > 0 {
                        gaps[gaps.count - 1].append(.init(start: last.end, end: b.start))
                    }
                    bridged[bridged.count - 1] = NightBlock(start: last.start, end: max(last.end, b.end))
                    groups[groups.count - 1].append(idx)
                    continue
                }
            }
            bridged.append(b)
            groups.append([idx])
            gaps.append([])
        }
        return zip(groups, gaps).map { BridgedNightGroup(indices: $0.sorted(), gaps: $1) }
    }
}
