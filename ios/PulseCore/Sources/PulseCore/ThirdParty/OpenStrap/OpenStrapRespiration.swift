// Ported to Swift from OpenStrap analytics, lib/src/onehz/respiration/resp_rate.dart (rsaRespRate).
// Source: https://github.com/OpenStrap/analytics at commit e59d63ccc39713a6deb2facfd1c8288a5203398a
// License: MIT, Copyright (c) 2026 OpenStrap. See docs/THIRD_PARTY.md for the full notice.
//
// Changed for Pulse: beat times are rebuilt from each minute's start, because the band's records don't
// carry a time per beat, and the result is a plain rate instead of OpenStrap's Metric wrapper.

import Foundation

/// Breaths per minute from respiratory sinus arrhythmia: breathing speeds the heart up and slows it down,
/// so the strongest rhythm in the beat intervals between 9 and 30 cycles a minute is the breathing rate.
enum OpenStrapRespiration {
    static let lowHz = 0.15
    static let classicHighHz = 0.40
    static let highestHz = 0.5
    static let segmentSeconds = 300.0
    static let agreementBreaths = 2.0
    static let minimumAgreement = 0.5

    /// The fastest breathing this beat interval can resolve (Hz).
    static func ceiling(beatSeconds: Double) -> Double {
        guard beatSeconds.isFinite, beatSeconds > 0 else { return highestHz }
        return min(0.5 / beatSeconds, highestHz)
    }

    /// nil when there is no stable breathing rhythm to report.
    /// - Parameters:
    ///   - beats: clean beat intervals in ms.
    ///   - times: when each beat happened, in ms, rising.
    static func rate(beats: [Double], times: [Double]) -> Double? {
        guard beats.count >= 20, times.count == beats.count else { return nil }
        let seconds = times.map { $0 / 1000 }
        guard let first = seconds.first, let last = seconds.last, last > first else { return nil }
        let span = last - first
        guard ceiling(beatSeconds: Stats.median(beats) / 1000) >= classicHighHz else { return nil }

        var segment = segmentSeconds
        if span < 2 * segment { segment = span / 2 }
        guard segment >= 60 else { return nil }

        var peaks: [Double] = []
        var start = first
        while start + segment <= last + 1e-9 {
            defer { start += segment / 2 }
            let low = lowerBound(seconds, start), high = lowerBound(seconds, start + segment)
            guard high - low >= 30 else { continue }
            let nn = Array(beats[low..<high])
            guard nn.reduce(0, +) / 1000 >= segment * 0.8 else { continue }
            let top = ceiling(beatSeconds: Stats.median(nn) / 1000)
            guard top >= classicHighHz else { continue }
            // Relative times keep the sines accurate and fast.
            let t = seconds[low..<high].map { $0 - start }
            guard let tail = t.last, let head = t.first, tail > head else { continue }
            let count = max(64, Int(((top - lowHz) * 4 * (tail - head)).rounded(.up)))
            guard let spectrum = OpenStrapSpectrum.lombScargle(times: t, values: nn,
                                                               frequencies: OpenStrapSpectrum.grid(lowHz, top, count: count)),
                  let peak = spectrum.peak(lowHz, top) else { continue }
            // A peak at the very top means the real rate can't be resolved here.
            guard peak < top - (top - lowHz) / Double(count - 1) else { continue }
            peaks.append(peak * 60)
        }
        guard peaks.count >= 3 else { return nil }
        let middle = Stats.median(peaks)
        let agreeing = peaks.filter { abs($0 - middle) <= agreementBreaths }.count
        guard Double(agreeing) / Double(peaks.count) >= minimumAgreement else { return nil }
        return peaks.min { abs($0 - middle) < abs($1 - middle) }
    }

    private static func lowerBound(_ values: [Double], _ target: Double) -> Int {
        var low = 0, high = values.count
        while low < high {
            let mid = (low + high) / 2
            if values[mid] < target { low = mid + 1 } else { high = mid }
        }
        return low
    }
}
