// Ported to Swift from OpenStrap analytics, lib/src/onehz/sleep/cardio_stager.dart
// (classifyCardioEpochs deep score, _cleanBeatsInWindow, _windowSdnn, _windowRemFeatures, _mergeShortDeep).
// Source: https://github.com/OpenStrap/analytics at commit e59d63ccc39713a6deb2facfd1c8288a5203398a
// License: MIT, Copyright (c) 2026 OpenStrap. See docs/THIRD_PARTY.md for the full notice.
//
// Changed for Pulse: one epoch is one minute instead of 30 seconds (Pulse stores minutes), the band's
// filler beats are removed first, and a "still" epoch means a minute Pulse already counts as asleep.

import Foundation

/// Which asleep minutes are restful: a quiet heart, scored from four measures against the same night.
/// This is an estimate of cardiac calm, not a measurement of deep sleep.
enum OpenStrapDeepSleep {
    /// The weights are the effect sizes OpenStrap measured on 99 sleep-lab nights (DREAMT).
    static let weightJitter = 0.53
    static let weightHeartRateSpread = 0.43
    static let weightSDNN = 0.41
    static let weightLFHF = 0.33
    /// OpenStrap ships 0.3. 0.4 is tuned on the owner's night of 2026-11-18: 1h48 of 9h asleep (20%).
    static let scoreCut = 0.4
    static let shortestBoutMinutes = 3

    private struct Beat { var interval: Double; var time: Double; var seam: Bool }

    private struct Scale {
        var middle: Double, spread: Double

        init?(_ sample: [Double]) {
            guard sample.count >= 4 else { return nil }
            middle = Stats.median(sample)
            let centre = middle
            spread = Stats.median(sample.map { abs($0 - centre) }) * 1.4826     // scaled median absolute deviation
            guard spread > 0 else { return nil }
        }

        func z(_ value: Double) -> Double { (value - middle) / spread }
    }

    /// The clean beats of one minute, timed from the start of the night (seconds).
    private static func beats(in minute: MinuteSample?, offset: Double) -> [Beat] {
        guard let minute else { return [] }
        var out: [Beat] = []
        var clock = offset
        var previous: Double?
        var broken = true
        for raw in minute.rrIntervalsMs.map(Double.init) {
            guard raw != HRV.fillerRRMs, (HRV.rrMinMs...HRV.rrMaxMs).contains(raw) else {
                previous = nil
                broken = true
                continue
            }
            clock += raw / 1000
            if let last = previous, abs(raw - last) > 200 {
                previous = raw
                broken = true
                continue
            }
            out.append(Beat(interval: raw, time: clock, seam: broken))
            broken = false
            previous = raw
        }
        return out
    }

    private static func heartRateSpread(_ minute: MinuteSample?) -> Double? {
        guard let rates = minute?.heartRate.filter({ $0 > 0 }).map(Double.init), rates.count >= 2 else { return nil }
        let spread = Stats.sampleSD(rates)
        return spread > 0 ? spread : nil
    }

    /// Mean change in instantaneous heart rate from beat to beat, and LF/HF, over about 3 minutes.
    private static func jitterAndBalance(_ window: [Beat]) -> (jitter: Double?, balance: Double?) {
        guard window.count >= 16, let first = window.first, let last = window.last else { return (nil, nil) }
        var total = 0.0, pairs = 0
        for i in window.indices.dropFirst() where !window[i].seam {
            total += abs(60_000 / window[i].interval - 60_000 / window[i - 1].interval)
            pairs += 1
        }
        let jitter = pairs >= 15 ? total / Double(pairs) : nil
        let span = last.time - first.time
        guard span > 0 else { return (jitter, nil) }
        let low = min(0.04, max(0.0005, 1 / span))
        guard let spectrum = OpenStrapSpectrum.lombScargle(times: window.map { $0.time - first.time }, values: window.map(\.interval),
                                                           frequencies: OpenStrapSpectrum.grid(low, 0.4, count: 240)) else {
            return (jitter, nil)
        }
        let high = spectrum.bandPower(0.15, 0.40)
        return (jitter, high > 0 ? spectrum.bandPower(0.04, 0.15) / high : nil)
    }

    /// - Parameters:
    ///   - night: one entry per minute of the sleep. nil = no band data.
    ///   - asleep: true for the minutes counted as asleep.
    /// - Returns: one flag per minute.
    static func restful(night: [MinuteSample?], asleep: [Bool], cut: Double = scoreCut) -> [Bool] {
        let count = night.count
        let perMinute = night.enumerated().map { beats(in: $1, offset: Double($0) * 60) }
        func window(_ minute: Int, reach: Int) -> [Beat] {
            var out: [Beat] = []
            for index in max(0, minute - reach)...min(count - 1, minute + reach) {
                out += perMinute[index]
            }
            return out
        }

        var jitter = [Double?](repeating: nil, count: count), balance = jitter, sdnn = jitter, spread = jitter
        for minute in 0..<count where asleep[minute] {
            let wide = window(minute, reach: 2).map(\.interval)
            if wide.count >= 5 { sdnn[minute] = Stats.sampleSD(wide) }
            (jitter[minute], balance[minute]) = jitterAndBalance(window(minute, reach: 1))
            spread[minute] = heartRateSpread(night[minute])
        }

        let scales = [jitter, spread, sdnn, balance].map { Scale($0.compactMap { $0 }) }
        let weights = [weightJitter, weightHeartRateSpread, weightSDNN, weightLFHF]
        var flags = [Bool](repeating: false, count: count)
        for minute in 0..<count where asleep[minute] {
            var score = 0.0, weightUsed = 0.0
            for (series, (scale, weight)) in zip([jitter, spread, sdnn, balance], zip(scales, weights)) {
                guard let value = series[minute], let scale else { continue }
                score -= scale.z(value) * weight
                weightUsed += weight
            }
            flags[minute] = weightUsed > 0 && score / weightUsed > cut
        }

        // Remove single-minute flicker, then bouts too short to be a settled stretch.
        var filtered = flags
        if count >= 3 {
            for minute in 1..<(count - 1) where flags[minute - 1] == flags[minute + 1] && flags[minute] != flags[minute - 1] {
                filtered[minute] = flags[minute - 1] && asleep[minute]
            }
        }
        var minute = 0
        while minute < count {
            guard filtered[minute] else { minute += 1; continue }
            var end = minute
            while end < count, filtered[end] { end += 1 }
            if end - minute < shortestBoutMinutes { for index in minute..<end { filtered[index] = false } }
            minute = end
        }
        return filtered
    }
}
