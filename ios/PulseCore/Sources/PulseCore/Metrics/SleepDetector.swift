import Foundation

/// Sleep detection from heart rate + motion. Spec: docs/METRICS.md §4.
public enum SleepDetector {

    /// Cole & Kripke 1992 weights (1-minute epochs) for activity at minutes i-4 ... i+2.
    public static let coleKripkeWeights: [Double] = [106, 54, 58, 76, 230, 74, 67]
    /// Calibrated to OUR activity units (not the 1992 actigraph's). Must be re-checked on real band data.
    public static let coleKripkeDivisor = 6000.0
    /// Asleep requires HR below (10th percentile of worn HR + this margin).
    public static let hrGateMargin = 15.0

    /// Cole-Kripke score per minute. Below 1 = "still enough to be asleep". Missing activity counts as 0.
    public static func coleKripke(_ activity: [Double?]) -> [Double] {
        let a = activity.map { $0 ?? 0 }
        let n = a.count
        var out: [Double] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            var total = 0.0
            for (k, w) in coleKripkeWeights.enumerated() {
                let j = i + k - 4
                if j >= 0 && j < n { total += w * a[j] }
            }
            out.append(total / coleKripkeDivisor)
        }
        return out
    }

    /// One flag per minute: asleep = worn, still (Cole-Kripke < 1), and heart rate low.
    /// - Parameter blocks: one block id per minute (24 h starting at local noon); nil = one block.
    ///   The HR threshold is computed per block so each night is judged against its own day.
    public static func classify(hr: [Double?], activity: [Double?], blocks: [Int]? = nil) -> [Bool] {
        let blockOf = blocks ?? Array(repeating: 0, count: hr.count)
        var wornByBlock: [Int: [Double]] = [:]
        for (value, block) in zip(hr, blockOf) {
            if let value { wornByBlock[block, default: []].append(value) }
        }
        let thresholds = wornByBlock.mapValues { Stats.lowerPercentile($0, 0.10) + hrGateMargin }
        let d = coleKripke(activity)
        return hr.indices.map { i in
            guard let h = hr[i], activity[i] != nil, let threshold = thresholds[blockOf[i]] else { return false }
            return d[i] < 1.0 && h < threshold
        }
    }

    /// A detected sleep session, as minute indices into the input (end is exclusive).
    public struct Session: Equatable, Sendable {
        public var start: Int
        public var end: Int
        public var asleep: Int
        public var awake: Int
        public var disturbances: Int
        public var isNap: Bool
        public var span: Int { end - start }
    }

    /// Group asleep minutes into sessions:
    /// seeds = runs of >= 10 asleep minutes; merge seeds <= 30 minutes apart, or <= 120 minutes apart when
    /// at least 25% of the gap is asleep (restless patch); keep spans >= 20 minutes; spans under 180 minutes are naps.
    public static func sessions(_ asleep: [Bool], minSeed: Int = 10, maxGap: Int = 30,
                                minSession: Int = 20, napLimit: Int = 180, restlessGap: Int = 120) -> [Session] {
        // 1. seeds
        var seeds: [(Int, Int)] = []
        var i = 0
        while i < asleep.count {
            if asleep[i] {
                var j = i
                while j < asleep.count && asleep[j] { j += 1 }
                if j - i >= minSeed { seeds.append((i, j)) }
                i = j
            } else {
                i += 1
            }
        }
        // 2. merge: short gaps, or gaps that are mostly sleep anyway (a restless patch)
        var merged: [(Int, Int)] = []
        for seed in seeds {
            if let last = merged.last {
                let gap = seed.0 - last.1
                let asleepInGap = asleep[last.1..<seed.0].filter { $0 }.count
                if gap <= maxGap || (gap <= restlessGap && asleepInGap * 4 >= gap) {
                    merged[merged.count - 1].1 = seed.1
                    continue
                }
            }
            merged.append(seed)
        }
        // 3. describe
        var out: [Session] = []
        for (start, end) in merged where end - start >= minSession {
            var awake = 0, disturbances = 0
            var previousAsleep = true
            for k in start..<end {
                if !asleep[k] {
                    awake += 1
                    if previousAsleep { disturbances += 1 }
                }
                previousAsleep = asleep[k]
            }
            out.append(Session(start: start, end: end, asleep: end - start - awake, awake: awake,
                               disturbances: disturbances, isNap: end - start < napLimit))
        }
        return out
    }
}
