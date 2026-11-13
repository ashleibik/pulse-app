import Foundation

/// A tiny deterministic random number generator (SplitMix64).
///
/// Why not `SystemRandomNumberGenerator`? Tests and SwiftUI previews need the SAME fake data
/// every run. With a seed, "seed 42" always produces the identical 30 days.
/// (Not for security: never use this for keys or tokens.)
///
/// Algorithm: Steele, Lea & Flood, "Fast splittable pseudorandom number generators", OOPSLA 2014.
public struct SeededRandom: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    public mutating func unit() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)  // 2^53
    }

    /// Normally distributed (bell curve), via the Box-Muller transform.
    public mutating func normal(mean: Double = 0, sd: Double = 1) -> Double {
        let u1 = max(unit(), 1e-12)
        let u2 = unit()
        return mean + sd * (-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2)
    }

    public mutating func chance(_ p: Double) -> Bool { unit() < p }

    /// A version-4-shaped UUID from the generator, so record IDs are reproducible too.
    public mutating func uuid() -> UUID {
        let a = next(), b = next()
        func byte(_ v: UInt64, _ i: Int) -> UInt8 { UInt8(truncatingIfNeeded: v >> (8 * UInt64(i))) }
        return UUID(uuid: (
            byte(a, 0), byte(a, 1), byte(a, 2), byte(a, 3), byte(a, 4), byte(a, 5),
            (byte(a, 6) & 0x0F) | 0x40, byte(a, 7),            // version 4
            (byte(b, 0) & 0x3F) | 0x80, byte(b, 1),            // RFC 4122 variant
            byte(b, 2), byte(b, 3), byte(b, 4), byte(b, 5), byte(b, 6), byte(b, 7)
        ))
    }

    public mutating func uniform(_ range: ClosedRange<Double>) -> Double {
        range.lowerBound + unit() * (range.upperBound - range.lowerBound)
    }
}
