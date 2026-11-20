// Ported to Swift for Pulse from OpenStrap analytics, lib/src/onehz/motion/steps.dart (Tier A: StepParams,
// pedometer, calcSteps, livePedometer, PedometerResult).
// Source: https://github.com/OpenStrap/analytics at commit e59d63ccc39713a6deb2facfd1c8288a5203398a (MIT, see docs/THIRD_PARTY.md)
// Copyright (c) 2026 OpenStrap
//
// The logic is line for line. OpenStrap's notes, kept: this counts steps on the band's 100 Hz stream, which exists
// only while the app is connected and streaming. It is AN-2554's structure on the acceleration's size, plus Zhao's
// "confirm 8 steps first" rule. It reads 0 at rest and rejects irregular movement, but not rhythmic arm work (a steady
// stir counts). On OxWalk (39 adults, camera ground truth, free living) it measured 33% average error at 100 Hz on the
// wrist; on clean walking the raw count is exact. Use it for walks it supervises, not as an all-day step source.

import Foundation

enum OpenStrapPedometer {
    // StepParams
    /// Default sample rate (Hz). The interval bounds are converted through the buffer's real rate.
    static let fs = 100.0
    /// Low-pass moving-average taps.
    static let filter = 8
    /// Centred peak window (~0.33 s at 100 Hz).
    static let window = 33
    /// g: dead zone around the dynamic threshold.
    static let sens = 0.10
    /// Dynamic-threshold smoothing buffer.
    static let thrOrder = 4
    /// Consecutive possible steps before any count.
    static let confirm = 8
    /// Samples to find a minimum after a maximum.
    static let maxMinTimeout = 120
    /// AN-2554's step-interval window: at most ~5 steps a second, at least ~0.5.
    static let minStepIntervalS = 0.2
    static let maxStepIntervalS = 2.0
    /// Per-user trim. 1.00 by default: a population fudge factor is not a calibration.
    static let gain = 1.00

    struct Result: Equatable, Sendable {
        var steps: Int
        /// Span the buffer covered (s).
        var durationS: Double
        /// Steps a minute over the span (0 if none).
        var cadenceSpm: Double
        /// The magnitude's range (g).
        var peakToPeakG: Double
        /// 0...1.
        var confidence: Double

        static let none = Result(steps: 0, durationS: 0, cadenceSpm: 0, peakToPeakG: 0, confidence: 0)
    }

    /// Steps over ONE contiguous acceleration-magnitude signal (g, gravity included). Raw count, no gain.
    static func pedometer(_ sig: [Double], sampleRateHz: Double = fs) -> Int {
        let n = sig.count
        if n < window || sampleRateHz <= 0 { return 0 }
        let minGap = minStepIntervalS * sampleRateHz
        let maxGap = maxStepIntervalS * sampleRateHz
        // low-pass: trailing moving average
        var lp = [Double](repeating: 0, count: n)
        var acc = 0.0
        for i in 0..<n {
            acc += sig[i]
            if i >= filter { acc -= sig[i - filter] }
            lp[i] = acc / Double(min(i + 1, filter))
        }
        let half = window >> 1
        // centred-window extrema candidates
        var candI: [Int] = [], candMax: [Bool] = [], candV: [Double] = []
        if n - half > half {
            for i in half..<(n - half) {
                var isMax = true, isMin = true
                let v = lp[i]
                for j in (i - half)...(i + half) {
                    if lp[j] > v { isMax = false }
                    if lp[j] < v { isMin = false }
                    if !isMax && !isMin { break }
                }
                if isMax {
                    candI.append(i); candMax.append(true); candV.append(v)
                } else if isMin {
                    candI.append(i); candMax.append(false); candV.append(v)
                }
            }
        }
        // dynamic threshold + CONFIRM-step regularity
        var dyn: [Double] = []
        var dynVal = 0.0
        for v in sig { dynVal += v }
        dynVal /= Double(n)
        var steps = 0, poss = 0
        var regulation = false
        var stateMax = true
        var curMax = 0.0
        var curMaxIdx = -1
        var lastStepIdx = -1
        for k in 0..<candI.count {
            let ci = candI[k], cMax = candMax[k], cv = candV[k]
            if stateMax {
                if cMax {
                    curMax = cv
                    curMaxIdx = ci
                    stateMax = false
                }
            } else {
                if cMax {
                    if cv > curMax {
                        curMax = cv
                        curMaxIdx = ci
                    }
                    continue
                }
                if ci - curMaxIdx > maxMinTimeout {
                    stateMax = true
                    poss = 0
                    regulation = false
                    lastStepIdx = -1
                    continue
                }
                let mx = curMax, mn = cv
                if mx > dynVal + sens / 2 && mn < dynVal - sens / 2 {
                    let gap: Int? = lastStepIdx < 0 ? nil : curMaxIdx - lastStepIdx
                    lastStepIdx = curMaxIdx
                    if let gap, Double(gap) < minGap || Double(gap) > maxGap {
                        poss = 0
                        regulation = false
                        stateMax = true
                        continue
                    }
                    if mx - mn > sens {
                        dyn.append((mx + mn) / 2)
                        if dyn.count > thrOrder { dyn.removeFirst() }
                        var s = 0.0
                        for v in dyn { s += v }
                        dynVal = s / Double(dyn.count)
                    }
                    poss += 1
                    if regulation {
                        steps += 1
                    } else if poss >= confirm {
                        steps += poss
                        regulation = true
                    }
                } else {
                    poss = 0
                    regulation = false
                }
                stateMax = true
            }
        }
        return steps
    }

    /// Daily total: `pedometer` over each per-minute signal, summed and scaled by `gain`.
    static func calcSteps(_ minuteSignals: [[Double]], sampleRateHz: Double = fs) -> Int {
        var total = 0
        for sig in minuteSignals { total += pedometer(sig, sampleRateHz: sampleRateHz) }
        return Int((Double(total) * gain).rounded())
    }

    /// `pedometer` over a three-axis buffer (g, gravity included), with the cadence over its span.
    static func livePedometer(_ x: [Double], _ y: [Double], _ z: [Double], sampleRateHz: Double = fs) -> Result {
        let n = min(x.count, min(y.count, z.count))
        if n < window || sampleRateHz <= 0 { return .none }
        var mag = [Double]()
        mag.reserveCapacity(n)
        for i in 0..<n {
            let sum: Double = x[i] * x[i] + y[i] * y[i] + z[i] * z[i]
            mag.append(sum.squareRoot())
        }
        let steps = pedometer(mag, sampleRateHz: sampleRateHz)
        let durationS = Double(n) / sampleRateHz
        if steps <= 0 { return Result(steps: 0, durationS: durationS, cadenceSpm: 0, peakToPeakG: 0, confidence: 0) }
        let cadence = durationS > 0 ? Double(steps) / (durationS / 60.0) : 0.0
        let mn = mag.min() ?? 0, mx = mag.max() ?? 0
        let conf = max(0.0, min(1.0, cadence >= 60 && cadence <= 200 ? 0.85 : 0.5))
        return Result(steps: steps, durationS: durationS, cadenceSpm: cadence, peakToPeakG: mx - mn, confidence: conf)
    }
}
