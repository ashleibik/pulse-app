// Ported to Swift for Pulse from NOOP, Packages/StrandAnalytics/Sources/StrandAnalytics/:
//   SleepAwareStepCounter.swift (the whole counter), StepsCounter.swift (shouldCountDelta, isPlausibleDelta and their
//   constants) and StepsEstimateEngine.swift (calibrate, estimate, weightedMedian, median, the confidence tiers).
// Source: https://github.com/ryanbr/noop at commit 2a1de7609843b095505274ad6fc811757210be80
// License: PolyForm Noncommercial License 1.0.0 <https://polyformproject.org/licenses/noncommercial/1.0.0>
// Required Notice: Copyright 2026 NoopApp
//
// Noncommercial use only. Changed for Pulse: NOOP's sleep sessions and stages are reduced to what the counter reads
// (start, end, and the stretches marked awake), and the motion-volume feature and UI strings of StepsEstimateEngine
// are left out. The logic is otherwise line for line. What feeds it on a WHOOP 4.0 is Pulse's (`Steps`, docs/METRICS.md §15).

import Foundation

enum NoopSteps {

    // MARK: - StepsCounter

    /// One reading of a cumulative u16 step counter, as NOOP's `StepSample`.
    struct StepSample: Equatable, Sendable {
        var ts: Int
        var counter: Int
        /// 0 still, 1 walk, 2 run. nil = unknown.
        var activityClass: Int?
    }

    private static let locomotionActivityClasses: Set<Int> = [1, 2]

    static func hasActivityClasses(_ samples: [StepSample]) -> Bool {
        samples.contains { $0.activityClass != nil }
    }

    static func shouldCountDelta(activityClass: Int?, hasActivityClasses: Bool) -> Bool {
        !hasActivityClasses || activityClass.map(locomotionActivityClasses.contains) == true
    }

    /// Absolute reboot/wrap guard, independent from the per-second plausibility gate below.
    static let maxStepDelta = 512
    static let maxTicksPerSecond = 4

    static func isPlausibleDelta(previousTs: Int, currentTs: Int, delta: Int) -> Bool {
        guard delta >= 1, delta < maxStepDelta else { return false }
        let elapsed = currentTs - previousTs
        guard elapsed > 0 else { return false }
        let rateAllowance = elapsed >= maxStepDelta / maxTicksPerSecond
            ? maxStepDelta - 1
            : elapsed * maxTicksPerSecond
        return delta <= rateAllowance
    }

    // MARK: - SleepAwareStepCounter

    static let maxSecondsBetweenGaitDeltas = 3
    static let minGaitBoutDurationSeconds = 4
    static let minGaitBoutActiveSamples = 5
    static let minGaitBoutTicks = 6

    /// A sleep as the counter sees it: [start, end) and the stretches inside it that were awake.
    struct SleepSession: Equatable, Sendable {
        var start: Int
        var end: Int
        var wake: [Range<Int>]
    }

    struct Count: Equatable, Sendable {
        var totalTicks: Int
        var acceptedOutsideSleepTicks: Int
        var acceptedAwakeGapTicks: Int
        var acceptedSleepBoutTicks: Int
        var rejectedIsolatedSleepTicks: Int
        var rejectedActivityClassTicks: Int
        var rejectedImplausibleTicks: Int
    }

    /// Stateful, overlap-safe counter for windows read in ascending pages.
    final class Accumulator {
        private let sessions: [SleepSession]
        private let hasClasses: Bool
        private var previous: StepSample?
        private var outside = 0, awake = 0, sleep = 0, rejectedSleep = 0
        private var rejectedClass = 0, rejectedImplausible = 0
        private var pending: [(ts: Int, ticks: Int)] = []
        private var finished = false

        init(sleepSessions: [SleepSession], hasActivityClasses: Bool) {
            sessions = sleepSessions.sorted { $0.start < $1.start }
            hasClasses = hasActivityClasses
        }

        @discardableResult func acceptPage(_ samples: [StepSample]) -> Accumulator {
            precondition(!finished)
            for current in samples.sorted(by: { $0.ts < $1.ts }) {
                guard let prior = previous else { previous = current; continue }
                guard current.ts > prior.ts else { continue }
                previous = current
                let delta = (current.counter - prior.counter) & 0xffff
                guard NoopSteps.shouldCountDelta(activityClass: current.activityClass, hasActivityClasses: hasClasses) else {
                    rejectedClass += delta; continue
                }
                guard NoopSteps.isPlausibleDelta(previousTs: prior.ts, currentTs: current.ts, delta: delta) else {
                    rejectedImplausible += delta; continue
                }
                switch NoopSteps.context(current.ts, sessions: sessions) {
                case 0: flush(); outside += delta
                case 1: flush(); awake += delta
                default:
                    if let last = pending.last, current.ts - last.ts > maxSecondsBetweenGaitDeltas { flush() }
                    pending.append((current.ts, delta))
                }
            }
            return self
        }

        func finish() -> Count {
            if !finished { flush(); finished = true }
            return Count(totalTicks: outside + awake + sleep, acceptedOutsideSleepTicks: outside,
                         acceptedAwakeGapTicks: awake, acceptedSleepBoutTicks: sleep,
                         rejectedIsolatedSleepTicks: rejectedSleep, rejectedActivityClassTicks: rejectedClass,
                         rejectedImplausibleTicks: rejectedImplausible)
        }

        private func flush() {
            guard !pending.isEmpty else { return }
            let ticks = pending.reduce(0) { $0 + $1.ticks }
            let duration = pending.last!.ts - pending.first!.ts
            let coherent = pending.count >= minGaitBoutActiveSamples
                && duration >= minGaitBoutDurationSeconds && ticks >= minGaitBoutTicks
            if coherent { sleep += ticks } else { rejectedSleep += ticks }
            pending.removeAll(keepingCapacity: true)
        }
    }

    static func stepsInWindow(_ samples: [StepSample], sleepSessions: [SleepSession]) -> Int? {
        let count = count(samples, sleepSessions: sleepSessions)
        return count.totalTicks > 0 ? count.totalTicks : nil
    }

    static func count(_ samples: [StepSample], sleepSessions: [SleepSession]) -> Count {
        let sorted = samples.sorted { $0.ts < $1.ts }
        return Accumulator(sleepSessions: sleepSessions, hasActivityClasses: hasActivityClasses(sorted))
            .acceptPage(sorted).finish()
    }

    /// 0 = outside every sleep, 1 = inside a sleep but awake, 2 = asleep.
    private static func context(_ ts: Int, sessions: [SleepSession]) -> Int {
        guard let session = sessions.first(where: { ts >= $0.start && ts < $0.end }) else { return 0 }
        if session.wake.contains(where: { $0.contains(ts) }) { return 1 }
        return 2
    }

    // MARK: - StepsEstimateEngine (calibration)

    /// Fewest calibration days before an auto-fit factor is trusted.
    static let minCalibrationDays = 3
    /// Calibration days at/above which confidence saturates toward 1.
    static let goodCalibrationDays = 14
    /// A day must move at least this much to enter the ratio fit.
    static let minMotionForFit = 1.0
    /// Sanity clamp on a daily estimate.
    static let maxDailySteps = 60_000

    struct CalibrationPoint: Equatable, Sendable {
        var motion: Double
        var steps: Double
    }

    struct Calibration: Equatable, Sendable {
        /// Steps per unit of motion.
        var coefficient: Double
        var sampleDays: Int
        /// 0-1: from sample size and fit spread. 1 for a manual factor.
        var confidence: Double
        var manual: Bool
    }

    enum ConfidenceTier: String, Equatable, Sendable {
        case low, medium, high

        static func from(_ confidence: Double) -> ConfidenceTier {
            if confidence < 0.34 { return .low }
            if confidence < 0.67 { return .medium }
            return .high
        }
    }

    /// Motion-weighted median of each day's steps / motion, with a confidence from the number of days and their spread.
    static func calibrate(_ points: [CalibrationPoint], manualOverride: Double? = nil) -> Calibration? {
        let usable = points.filter(isUsableCalibrationPoint)
        if let k = manualOverride, k > 0 {
            return Calibration(coefficient: k, sampleDays: usable.count, confidence: 1.0, manual: true)
        }
        let weighted = usable.map { (ratio: $0.steps / $0.motion, weight: $0.motion) }
        guard weighted.count >= minCalibrationDays else { return nil }
        let ratios = weighted.map { $0.ratio }
        let weights = weighted.map { $0.weight }
        let k = weightedMedian(ratios, weights: weights)
        guard k > 0 else { return nil }
        let sizeTerm = min(1.0, Double(weighted.count) / Double(goodCalibrationDays))
        let mad = weightedMedian(ratios.map { abs($0 - k) }, weights: weights)
        let spread = k > 0 ? mad / k : 1.0
        let tightness = max(0.0, 1.0 - spread)
        let confidence = max(0.0, min(1.0, 0.5 * sizeTerm + 0.5 * tightness))
        return Calibration(coefficient: k, sampleDays: weighted.count, confidence: confidence, manual: false)
    }

    /// nil below `minMotionForFit`: too little movement to say anything.
    static func estimate(motion: Double, calibration: Calibration) -> Int? {
        guard motion >= minMotionForFit, calibration.coefficient > 0 else { return nil }
        let raw = motion * calibration.coefficient
        return max(0, min(maxDailySteps, Int(raw.rounded())))
    }

    static func isUsableCalibrationPoint(_ point: CalibrationPoint) -> Bool {
        point.motion >= minMotionForFit && point.steps > 0
    }

    static func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted(); let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }

    /// Sort by value and return the value at which the cumulative weight first reaches half the total. On the exact
    /// half-mass boundary, the average of the two values around it. Falls back to the plain median on bad weights.
    static func weightedMedian(_ xs: [Double], weights: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        guard weights.count == xs.count else { return median(xs) }
        let order = xs.indices.sorted { xs[$0] < xs[$1] }
        let total = weights.reduce(0, +)
        guard total > 0 else { return median(xs) }
        let half = total / 2
        var cum = 0.0
        for (pos, idx) in order.enumerated() {
            let w = max(0.0, weights[idx])
            cum += w
            if cum > half { return xs[idx] }
            if cum == half {
                let next = pos + 1 < order.count ? order[pos + 1] : idx
                return (xs[idx] + xs[next]) / 2
            }
        }
        return xs[order[order.count - 1]]
    }
}
