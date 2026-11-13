import Foundation

/// Statistics helpers with EXACT definitions from docs/METRICS.md §0.
/// They must match re-toolkit/metrics/stats.py bit for bit, so: plain left-to-right sums,
/// one specific median and percentile definition.
public enum Stats {

    public static func mean(_ xs: [Double]) -> Double {
        var total = 0.0
        for x in xs { total += x }
        return total / Double(xs.count)
    }

    /// Odd count: the middle value. Even count: average of the two middle values.
    public static func median(_ xs: [Double]) -> Double {
        let s = xs.sorted()
        let mid = s.count / 2
        return s.count % 2 == 1 ? s[mid] : (s[mid - 1] + s[mid]) / 2.0
    }

    /// Sample standard deviation (divides by n - 1). Needs at least 2 values.
    public static func sampleSD(_ xs: [Double]) -> Double {
        let m = mean(xs)
        var total = 0.0
        for x in xs { total += (x - m) * (x - m) }
        return (total / Double(xs.count - 1)).squareRoot()
    }

    /// `sorted(xs)[floor(p * (n - 1))]`
    public static func lowerPercentile(_ xs: [Double], _ p: Double) -> Double {
        let s = xs.sorted()
        return s[Int((p * Double(s.count - 1)).rounded(.down))]
    }

    /// Standard normal cumulative distribution function.
    public static func phi(_ x: Double) -> Double {
        0.5 * (1.0 + erf(x / 2.0.squareRoot()))
    }

    public static func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
        max(lo, min(hi, x))
    }
}
