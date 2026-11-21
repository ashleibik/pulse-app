// Ported to Swift from NOOP, Packages/StrandAnalytics/Sources/StrandAnalytics/WorkoutDetector.swift (`WorkoutDetector.detect`,
// `activitySeries`, `smoothedIntensity`, `nearest`, `deriveRestingHR`, `boutIntensity`, `bridgeRuns`, `backdatedStart`) and
// StrainScorer.swift (`edwardsZones`, `zoneWeight`).
// Source: https://github.com/ryanbr/noop at commit 2a1de7609843b095505274ad6fc811757210be80
// License: PolyForm Noncommercial License 1.0.0. Required Notice: Copyright 2026 NoopApp. See docs/THIRD_PARTY.md.
//
// Changed for Pulse: a bout returns its times only (Pulse computes the numbers), the maximum heart rate is passed in, the resting
// heart rate is looked up per second (each day has its own), and heart rates are read through a lookup by second instead of a
// full series. The motion series comes from Pulse's per-second activity (docs/METRICS.md §10).

import Foundation

/// NOOP's exercise detector: sustained movement with a raised heart rate, mostly in zone 2 or higher.
enum NoopWorkoutDetector {
    static let minExerciseMin = 5.0
    static let hrMarginBPM = 15.0
    static let motionThreshold = 0.20
    static let motionSmoothS = 10.0
    static let mergeGapS = 150.0
    static let minIntensityZ2Plus = 0.50
    static let alignToleranceS = 5.0
    static let restingPercentile = 10.0
    static let bridgeGapS = 300.0
    /// Edwards zones on % of heart-rate reserve (StrainScorer.swift).
    static let edwardsZones: [(threshold: Double, weight: Int)] = [(90, 5), (80, 4), (70, 3), (60, 2), (50, 1)]

    /// A detected workout, in unix seconds. `end` is its last active second.
    struct Bout: Equatable, Sendable {
        var start: Int
        var end: Int
    }

    struct MotionPoint: Equatable, Sendable {
        var ts: Int
        var intensity: Double
    }

    /// NOOP's motion series from gravity readings: the size of the change from the reading before (the first is 0).
    static func activitySeries(_ gravity: [(ts: Int, x: Double, y: Double, z: Double)]) -> [MotionPoint] {
        let rows = gravity.sorted { $0.ts < $1.ts }
        var series: [MotionPoint] = []
        series.reserveCapacity(rows.count)
        for (i, row) in rows.enumerated() {
            guard i > 0 else {
                series.append(MotionPoint(ts: row.ts, intensity: 0))
                continue
            }
            let p = rows[i - 1]
            let dx = row.x - p.x, dy = row.y - p.y, dz = row.z - p.z
            series.append(MotionPoint(ts: row.ts, intensity: (dx * dx + dy * dy + dz * dz).squareRoot()))
        }
        return series
    }

    /// - Parameters:
    ///   - motion: the motion series, sorted.
    ///   - heartRateAt: the heart rate measured at a second (nil = none). NOOP's series is one reading per measured second.
    ///   - restingHR: the resting heart rate for a second: its day's, or NOOP's 10th percentile (`deriveRestingHR`).
    ///   - maxHR: the maximum heart rate.
    static func detect(motion: [MotionPoint], heartRateAt: (Int) -> Double?, restingHR rest: (Int) -> Double,
                       maxHR: Double) -> [Bout] {
        guard !motion.isEmpty else { return [] }
        let smooth = smoothedIntensity(motion, windowS: motionSmoothS)
        let motionTs = motion.map(\.ts)

        // Seconds where both gates hold.
        var activeTs: [Int] = []
        for (point, intensity) in zip(motion, smooth) {
            guard intensity > motionThreshold else { continue }
            guard let bpm = nearest(point.ts, tolerance: Int(alignToleranceS), heartRateAt: heartRateAt),
                  bpm > rest(point.ts) + hrMarginBPM else { continue }
            activeTs.append(point.ts)
        }
        guard var previous = activeTs.first else { return [] }

        // Runs of active seconds less than `mergeGapS` apart.
        var runs: [(Int, Int)] = []
        var runStart = previous
        for ts in activeTs.dropFirst() {
            if Double(ts - previous) > mergeGapS {
                runs.append((runStart, previous))
                runStart = ts
            }
            previous = ts
        }
        runs.append((runStart, previous))
        runs = bridgeRuns(runs, heartRateAt: heartRateAt, floor: { rest($0) + hrMarginBPM })

        let minDurS = minExerciseMin * 60
        var bouts: [Bout] = []
        for (index, run) in runs.enumerated() {
            let (start, end) = run
            if Double(end - start) < minDurS - motionSmoothS { continue }
            let core = (start...end).compactMap(heartRateAt)
            if core.isEmpty { continue }
            let resting = rest(start)
            if maxHR > resting {
                let z2plus = zoneTwoPlusShare(core, restingHR: resting, maxHR: maxHR)
                if z2plus < minIntensityZ2Plus { continue }
            }
            // Never back-date past the previous run's end.
            let floor = index > 0 ? runs[index - 1].1 + 1 : Int.min
            let effectiveStart = max(backdatedStart(start, motionTs, smooth), floor)
            bouts.append(Bout(start: effectiveStart, end: end))
        }
        return bouts
    }

    /// Trailing rolling mean over `windowS` seconds.
    static func smoothedIntensity(_ motion: [MotionPoint], windowS: Double) -> [Double] {
        var out: [Double] = []
        out.reserveCapacity(motion.count)
        var lo = 0
        var running = 0.0
        for i in motion.indices {
            running += motion[i].intensity.isFinite ? motion[i].intensity : 0
            while Double(motion[i].ts - motion[lo].ts) > windowS {
                running -= motion[lo].intensity.isFinite ? motion[lo].intensity : 0
                lo += 1
            }
            out.append(running / Double(i - lo + 1))
        }
        return out
    }

    /// The heart rate nearest to `ts` within `tolerance` seconds; a tie goes to the later reading. NOOP compares the reading
    /// just before `ts` with the first one at or after it, which is the same thing.
    static func nearest(_ ts: Int, tolerance: Int, heartRateAt: (Int) -> Double?) -> Double? {
        guard tolerance >= 0 else { return nil }
        if let exact = heartRateAt(ts) { return exact }
        for distance in stride(from: 1, through: tolerance, by: 1) {
            if let after = heartRateAt(ts + distance) { return after }
            if let before = heartRateAt(ts - distance) { return before }
        }
        return nil
    }

    /// The day's resting baseline: the nearest-rank 10th percentile of its heart rates.
    static func deriveRestingHR(_ bpms: [Double]) -> Double {
        let sorted = bpms.sorted()
        guard !sorted.isEmpty else { return 0 }
        let rank = max(1, Int((restingPercentile / 100 * Double(sorted.count)).rounded(.up)))
        return sorted[rank - 1]
    }

    /// The share of the readings in Edwards zone 2 or higher (60% of reserve or more).
    static func zoneTwoPlusShare(_ bpms: [Double], restingHR: Double, maxHR: Double) -> Double {
        guard !bpms.isEmpty, maxHR > restingHR else { return 0 }
        let reserve = maxHR - restingHR
        var counts = [Int](repeating: 0, count: 6)
        for bpm in bpms { counts[zoneWeight(bpm, restingHR: restingHR, hrReserve: reserve)] += 1 }
        // NOOP rounds each zone's share to a tenth of a percent, then adds zones 2 to 5.
        let percents = counts.map { ((Double($0) / Double(bpms.count) * 100) * 10).rounded() / 10 }
        return percents[2...5].reduce(0, +) / 100
    }

    static func zoneWeight(_ bpm: Double, restingHR: Double, hrReserve: Double) -> Int {
        let percent = (bpm - restingHR) / hrReserve * 100
        for (threshold, weight) in edwardsZones where percent >= threshold { return weight }
        return 0
    }

    /// Joins runs up to `bridgeGapS` apart while the heart rate in the gap stays above the floor (or there is no reading).
    static func bridgeRuns(_ runs: [(Int, Int)], heartRateAt: (Int) -> Double?, floor: (Int) -> Double) -> [(Int, Int)] {
        guard runs.count > 1 else { return runs }
        var merged: [(Int, Int)] = []
        var currentStart = runs[0].0
        var currentEnd = runs[0].1
        for next in runs.dropFirst() {
            let gap = Double(next.0 - currentEnd)
            var bridge = false
            if gap <= bridgeGapS {
                let inGap = ((currentEnd + 1)..<max(currentEnd + 1, next.0)).compactMap(heartRateAt)
                if inGap.isEmpty {
                    bridge = true
                } else {
                    bridge = inGap.reduce(0, +) / Double(inGap.count) > floor(currentEnd)
                }
            }
            if bridge {
                currentEnd = max(currentEnd, next.1)
            } else {
                merged.append((currentStart, currentEnd))
                currentStart = next.0
                currentEnd = next.1
            }
        }
        merged.append((currentStart, currentEnd))
        return merged
    }

    /// Moves a qualified run's start back over the warm-up's unbroken movement.
    static func backdatedStart(_ coreStart: Int, _ motionTs: [Int], _ smooth: [Double]) -> Int {
        var i = motionTs.firstIndex { $0 >= coreStart } ?? motionTs.count
        guard i < motionTs.count else { return coreStart }
        var start = coreStart
        var previousTs = motionTs[i]
        while i > 0 {
            i -= 1
            if smooth[i] <= motionThreshold { break }
            if Double(previousTs - motionTs[i]) > mergeGapS { break }
            start = motionTs[i]
            previousTs = motionTs[i]
        }
        return start
    }

}
