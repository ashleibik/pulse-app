// Ported to Swift from OpenStrap analytics, lib/src/onehz/util.dart (lombScargle, freqGrid, LombScargle).
// Source: https://github.com/OpenStrap/analytics at commit e59d63ccc39713a6deb2facfd1c8288a5203398a
// License: MIT, Copyright (c) 2026 OpenStrap. See docs/THIRD_PARTY.md for the full notice.

import Foundation

/// Spectrum of unevenly sampled data (Press & Rybicki 1989). Used for breathing and LF/HF.
enum OpenStrapSpectrum {
    struct Result {
        var frequencies: [Double]
        var power: [Double]

        /// Power summed over [lowHz, highHz).
        func bandPower(_ lowHz: Double, _ highHz: Double) -> Double {
            var total = 0.0
            for i in frequencies.indices where frequencies[i] >= lowHz && frequencies[i] < highHz {
                let width = i > 0 ? frequencies[i] - frequencies[i - 1] : (frequencies.count > 1 ? frequencies[1] - frequencies[0] : 0)
                total += power[i] * width
            }
            return total
        }

        /// The frequency with the most power in [lowHz, highHz].
        func peak(_ lowHz: Double, _ highHz: Double) -> Double? {
            var best: Double?
            var bestPower = -Double.infinity
            for i in frequencies.indices where frequencies[i] >= lowHz && frequencies[i] <= highHz && power[i] > bestPower {
                bestPower = power[i]
                best = frequencies[i]
            }
            return best
        }
    }

    static func grid(_ lowHz: Double, _ highHz: Double, count: Int) -> [Double] {
        guard count > 1 else { return count == 1 ? [lowHz] : [] }
        let step = (highHz - lowHz) / Double(count - 1)
        return (0..<count).map { lowHz + step * Double($0) }
    }

    /// - Parameters:
    ///   - times: sample times in seconds.
    ///   - values: the samples.
    /// - Returns: nil with fewer than 4 points, no variance, or no time span.
    static func lombScargle(times t: [Double], values y: [Double], frequencies: [Double]) -> Result? {
        let n = t.count
        guard n >= 4, y.count == n, !frequencies.isEmpty else { return nil }
        let mean = y.reduce(0, +) / Double(n)
        let centred = y.map { $0 - mean }
        guard centred.reduce(0, { $0 + $1 * $1 }) > 0, let first = t.min(), let last = t.max(), last > first else { return nil }
        let scale = 2.0 * (last - first) / Double(n - 1)

        var power = [Double](repeating: 0, count: frequencies.count)
        for (index, frequency) in frequencies.enumerated() where frequency != 0 {
            let w = 2 * Double.pi * frequency
            var sin2 = 0.0, cos2 = 0.0
            for time in t {
                sin2 += sin(2 * w * time)
                cos2 += cos(2 * w * time)
            }
            let tau = atan2(sin2, cos2) / (2 * w)
            var cNum = 0.0, cDen = 0.0, sNum = 0.0, sDen = 0.0
            for i in 0..<n {
                let arg = w * (t[i] - tau)
                let c = cos(arg), s = sin(arg)
                cNum += centred[i] * c
                cDen += c * c
                sNum += centred[i] * s
                sDen += s * s
            }
            let term1 = cDen == 0 ? 0 : cNum * cNum / cDen
            let term2 = sDen == 0 ? 0 : sNum * sNum / sDen
            power[index] = 0.5 * (term1 + term2) * scale
        }
        return Result(frequencies: frequencies, power: power)
    }
}
