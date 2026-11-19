import Foundation

/// RR cleaning, RMSSD and overnight HRV. Spec: docs/METRICS.md §1-2.
public enum HRV {
    public static let rrMinMs = 300.0
    public static let rrMaxMs = 2000.0
    /// The band writes exactly this value when it has no beat to report (about 5% of a real night's beats).
    public static let fillerRRMs = 500.0

    /// Everything the band's beats go through before HRV: `cleanRR`, without the filler value, and
    /// without a beat that jumps more than 20% from the clean beat right before it.
    public static func cleanBeats(_ rr: [Double], tolerance: Double = 0.20) -> [Double?] {
        var out = cleanRR(rr.map { $0 == fillerRRMs ? 0 : $0 }, tolerance: tolerance)
        var previous: Double?
        for i in out.indices {
            if let beat = out[i], let before = previous, abs(beat - before) > tolerance * before { out[i] = nil }
            previous = out[i]
        }
        return out
    }

    /// Returns one entry per input beat: the beat, or nil if it was rejected as an artifact.
    /// Positions are kept so RMSSD only ever pairs beats that really were next to each other.
    ///
    /// Rules: outside 300-2000 ms -> reject. Otherwise compare with the median of the valid beats
    /// within +/-5 positions; more than 20% away -> reject (a missed or extra beat).
    /// Sources: Task Force ESC/NASPE 1996 (Malik 20% criterion); Lipponen & Tarvainen 2019.
    public static func cleanRR(_ rr: [Double], halfWindow: Int = 5, tolerance: Double = 0.20) -> [Double?] {
        let valid: [Double?] = rr.map { (rrMinMs...rrMaxMs).contains($0) ? $0 : nil }
        var out: [Double?] = []
        out.reserveCapacity(rr.count)
        var neighbours: [Double] = []           // kept in order, and reused for every beat
        neighbours.reserveCapacity(2 * halfWindow + 1)
        for (i, beat) in valid.enumerated() {
            guard let x = beat else {
                out.append(nil)
                continue
            }
            neighbours.removeAll(keepingCapacity: true)
            for j in max(0, i - halfWindow)..<min(valid.count, i + halfWindow + 1) {
                guard let value = valid[j] else { continue }
                var k = neighbours.count
                neighbours.append(value)
                while k > 0, neighbours[k - 1] > value {
                    neighbours[k] = neighbours[k - 1]
                    k -= 1
                }
                neighbours[k] = value
            }
            let mid = neighbours.count / 2
            let m = neighbours.count % 2 == 1 ? neighbours[mid] : (neighbours[mid - 1] + neighbours[mid]) / 2.0
            out.append(abs(x - m) <= tolerance * m ? x : nil)
        }
        return out
    }

    /// Root mean square of successive differences, using only pairs where both beats are present.
    /// nil if there are fewer than `minPairs` pairs (too little data to mean anything).
    public static func rmssd(_ rr: [Double?], minPairs: Int = 20) -> Double? {
        var total = 0.0
        var n = 0
        for i in rr.indices.dropFirst() {
            guard let a = rr[i - 1], let b = rr[i] else { continue }
            let d = b - a
            total += d * d
            n += 1
        }
        guard n >= minPairs else { return nil }
        return (total / Double(n)).squareRoot()
    }

    /// Overnight HRV: median RMSSD of 5-minute fully-asleep segments. nil if fewer than 3 segments.
    /// - Parameters:
    ///   - minuteRR: RR intervals (ms) for each minute of the sleep session, in order.
    ///   - asleep: one flag per minute (asleep AND band worn).
    public static func overnightRMSSD(minuteRR: [[Double]], asleep: [Bool],
                                      segmentMinutes: Int = 5, minSegments: Int = 3) -> Double? {
        overnightMedian(minuteRR: minuteRR, asleep: asleep, segmentMinutes: segmentMinutes,
                        minSegments: minSegments) { rmssd($0) }
    }

    private static func overnightMedian(minuteRR: [[Double]], asleep: [Bool], segmentMinutes: Int,
                                        minSegments: Int, metric: ([Double?]) -> Double?) -> Double? {
        var values: [Double] = []
        var i = 0
        let n = minuteRR.count
        while i + segmentMinutes <= n {
            if asleep[i..<(i + segmentMinutes)].allSatisfy({ $0 }) {
                // Each minute is cleaned alone, and the nil between minutes stops a pair forming across them.
                let beats = minuteRR[i..<(i + segmentMinutes)].flatMap { cleanBeats($0) + [nil] }
                if let v = metric(beats) { values.append(v) }
                i += segmentMinutes
            } else {
                i += 1
            }
        }
        return values.count >= minSegments ? Stats.median(values) : nil
    }
}

/// Resting heart rate. Spec: docs/METRICS.md §3.
public enum RestingHeartRate {
    /// Lowest mean over `window` consecutive minutes that all have a value (nil breaks the window).
    public static func lowestSustained(_ minuteHR: [Double?], window: Int = 10) -> Double? {
        guard minuteHR.count >= window else { return nil }
        var best: Double?
        for i in 0...(minuteHR.count - window) {
            let slice = minuteHR[i..<(i + window)]
            guard slice.allSatisfy({ $0 != nil }) else { continue }
            let m = Stats.mean(slice.map { $0! })
            if best == nil || m < best! { best = m }
        }
        return best
    }
}
