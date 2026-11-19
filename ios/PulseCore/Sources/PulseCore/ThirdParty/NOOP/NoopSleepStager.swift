// Ported to Swift for Pulse from NOOP, Packages/StrandAnalytics/Sources/StrandAnalytics/SleepStagerV2.swift
// (features, respRegularity, remLatencyGuard, cyclePrior, sustainedSleepOnset, viterbi, stageEpochs and every constant).
// Source: https://github.com/ryanbr/noop at commit 2a1de7609843b095505274ad6fc811757210be80
// License: PolyForm Noncommercial License 1.0.0 <https://polyformproject.org/licenses/noncommercial/1.0.0>
// Required Notice: Copyright 2026 NoopApp
//
// Noncommercial use only. Changed for Pulse: `input(from:)` turns the band's stored minutes into NOOP's three streams.
// Pulse keeps how far the wrist moved each second rather than the gravity vector, so the jerk arrives ready-made.
// The jerk floor can't go below `smallestJerk`, the smallest movement the stored values can show.

import Foundation

/// Sleep stages for each 30 seconds of a night, from heart rate, beat intervals and movement. An estimate.
enum NoopSleepStager {
    /// The order matters: Viterbi ties go to the earlier stage.
    enum Stage: Int, CaseIterable, Sendable { case deep, rem, light, awake }

    struct Input: Sendable {
        var heartRate: [(second: Int, bpm: Double)] = []
        /// How far the wrist moved since the second before, in g.
        var jerk: [(second: Int, value: Double)] = []
        var beats: [(second: Int, ms: Double)] = []
    }

    struct StagedEpoch: Sendable, Equatable {
        let start: Int
        let stage: Stage
    }

    /// The farthest any per-epoch window reads before and after the night, in seconds.
    static let padLo = 330
    static let padHi = 390
    /// The smallest step in the stored movement values: 1 / `MinuteBuilder.activityScale`.
    static let smallestJerk = 0.002

    /// Population sleep-architecture base rates as log-priors, in `Stage` order.
    static let baseLogPrior = [log(0.15), log(0.22), log(0.50), log(0.10)]
    static let deepGateThresh = 0.25
    static let deepGateSlope = 5.0
    static let jerkFloorMoveMult = 38.0
    static let jerkFloorGateMult = 55.0
    static let motionGateBoost = 2.0
    static let respWeight = 0.6
    static let remLatencyPenalty = 3.0
    static let remLatencyMinutes = 60.0
    static let onsetSustainedEpochs = 10

    /// Rows = from, columns = to, in `Stage` order.
    static let transition: [[Double]] = [
        [0.86, 0.007, 0.126, 0.007],
        [0.005, 0.88, 0.10, 0.015],
        [0.06, 0.06, 0.85, 0.03],
        [0.0, 0.0, 0.10, 0.90],
    ]

    struct Epoch: Sendable {
        let start: Int
        let hr: Double?
        let hrVar: Double?
        let hrFlat11: Double?
        let moveFrac: Double
        let jerkMax: Double
        let respReg: Double?
        let clock: Double
        let jerkScale: Double
        let minutesSinceOnset: Double
    }

    // MARK: - The band's minutes

    /// NOOP's three streams from the stored minutes. New minutes use how far the wrist turned, older ones the band's activity.
    static func input(from minutes: [MinuteSample]) -> Input {
        let worn = minutes.filter(\.isWorn).sorted { $0.start < $1.start }
        let turned = worn.filter { WristAngle.movement($0.wristAngle) != nil }.count
        let useAngle = turned > 0 && turned * 2 >= worn.count
        var input = Input()
        input.heartRate.reserveCapacity(worn.count * 60)
        input.jerk.reserveCapacity(worn.count * 60)
        for minute in worn {
            let start = Int(minute.start.timeIntervalSince1970)
            for (second, bpm) in minute.heartRate.enumerated() where bpm > 0 {
                input.heartRate.append((start + second, Double(bpm)))
            }
            if useAngle {
                for (second, tenths) in (minute.wristAngle ?? []).enumerated() where tenths != WristAngle.noReading {
                    // Two unit vectors this far apart differ by this much.
                    input.jerk.append((start + second, 2 * sin(Double(tenths) / 10 * .pi / 180 / 2)))
                }
            } else {
                for (second, activity) in minute.activity.enumerated() {
                    input.jerk.append((start + second, Double(activity) / MinuteBuilder.activityScale))
                }
            }
            // The band doesn't time each beat, so the time is rebuilt from the start of the minute.
            var clock = 0.0
            for beat in minute.rrIntervalsMs {
                let ms = Double(beat)
                guard ms != HRV.fillerRRMs, (HRV.rrMinMs...HRV.rrMaxMs).contains(ms) else { continue }
                clock += ms
                input.beats.append((start + Int(clock / 1000), ms))
            }
        }
        return input
    }

    /// One stage per 30 seconds of the night that has data.
    static func stage(start: Int, end: Int, input: Input) -> [StagedEpoch] {
        let epochs = features(start: start, end: end, input: input)
        return zip(epochs, stageEpochs(epochs)).map { StagedEpoch(start: $0.start, stage: $1) }
    }

    // MARK: - Features

    static func features(start: Int, end: Int, input: Input) -> [Epoch] {
        guard end > start else { return [] }
        let span = Double(max(1, end - start))
        let low = start - padLo
        let count = end + padHi - low

        var hrSum = [Double](repeating: 0, count: count)
        var hrCount = [Int](repeating: 0, count: count)
        for reading in input.heartRate where reading.second >= low && reading.second - low < count {
            hrSum[reading.second - low] += reading.bpm
            hrCount[reading.second - low] += 1
        }
        var jerkAt = [Double?](repeating: nil, count: count)
        for reading in input.jerk where reading.second >= low && reading.second - low < count {
            jerkAt[reading.second - low] = reading.value
        }
        var beatsAt = [[Double]](repeating: [], count: count)
        for beat in input.beats where beat.second >= low && beat.second - low < count {
            beatsAt[beat.second - low].append(beat.ms)
        }

        // Prefix sums make each windowed standard deviation a constant-time lookup.
        var prefixCount = [Int](repeating: 0, count: count + 1)
        var prefixSum = [Double](repeating: 0, count: count + 1)
        var prefixSquare = [Double](repeating: 0, count: count + 1)
        for index in 0..<count {
            let present = hrCount[index] > 0
            let value = present ? hrSum[index] / Double(hrCount[index]) : 0
            prefixCount[index + 1] = prefixCount[index] + (present ? 1 : 0)
            prefixSum[index + 1] = prefixSum[index] + value
            prefixSquare[index + 1] = prefixSquare[index] + value * value
        }
        func deviation(_ from: Int, _ to: Int) -> Double? {
            let a = max(from - low, 0), b = min(to - low, count)
            guard b > a else { return nil }
            let present = prefixCount[b] - prefixCount[a]
            guard present >= 2 else { return nil }
            let n = Double(present)
            let sum = prefixSum[b] - prefixSum[a]
            let square = prefixSquare[b] - prefixSquare[a]
            let mean = sum / n
            let variance = (square - 2 * mean * sum + n * mean * mean) / n
            return (variance < 0 ? 0 : variance).squareRoot()
        }

        struct Raw {
            let start: Int, hr: Double?, hrVar: Double?, hrFlat11: Double?
            let jerks: [Double], gapSeconds: Int, jerkMax: Double, respReg: Double?, clock: Double, minutes: Double
        }
        var raws: [Raw] = []
        var allJerks: [Double] = []
        var tables: [Int: RespDFT] = [:]
        var epoch = ((start + 29) / 30) * 30
        while epoch < end {
            defer { epoch += 30 }
            var rates: [Double] = []
            var moved: [Double] = []
            for second in epoch..<(epoch + 30) {
                let index = second - low
                if hrCount[index] > 0 { rates.append(hrSum[index] / Double(hrCount[index])) }
                if let value = jerkAt[index] { moved.append(value) }
            }
            if rates.isEmpty && moved.isEmpty { continue }

            // The first reading of an epoch has no earlier reading inside the epoch to compare with.
            let jerks = Array(moved.dropFirst())
            allJerks.append(contentsOf: jerks)

            var beats: [(Double, Double)] = []
            for second in (epoch - 90)..<(epoch + 120) {
                for value in beatsAt[second - low] { beats.append((Double(second), min(max(value, 300), 2000))) }
            }
            beats.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }

            raws.append(Raw(start: epoch, hr: rates.isEmpty ? nil : rates.reduce(0, +) / Double(rates.count),
                            hrVar: deviation(epoch - 150, epoch + 30 + 150),
                            hrFlat11: deviation(epoch - 330, epoch + 30 + 360),
                            jerks: jerks, gapSeconds: max(1, moved.count - 1), jerkMax: jerks.max() ?? 0,
                            respReg: respRegularity(beats, tables: &tables),
                            clock: Double(epoch + 15 - start) / span, minutes: Double(epoch + 15 - start) / 60))
        }

        let jerkScale: Double
        if allJerks.isEmpty {
            jerkScale = 1e-6
        } else {
            let sorted = allJerks.sorted(), n = sorted.count
            jerkScale = max(smallestJerk, n % 2 == 1 ? sorted[n / 2] : 0.5 * (sorted[n / 2 - 1] + sorted[n / 2]))
        }
        let moveThreshold = jerkScale * jerkFloorMoveMult
        return raws.map { raw in
            let moves = raw.jerks.reduce(0) { $0 + ($1 > moveThreshold ? 1 : 0) }
            return Epoch(start: raw.start, hr: raw.hr, hrVar: raw.hrVar, hrFlat11: raw.hrFlat11,
                         moveFrac: Double(moves) / Double(raw.gapSeconds), jerkMax: raw.jerkMax, respReg: raw.respReg,
                         clock: raw.clock, jerkScale: jerkScale, minutesSinceOnset: raw.minutes)
        }
    }

    /// The band-limited transform's sines and cosines for one grid length.
    struct RespDFT {
        let kLo: Int
        let cosines: [[Double]]
        let sines: [[Double]]

        init(n: Int, kLo: Int, kHi: Int) {
            self.kLo = kLo
            var cosines: [[Double]] = [], sines: [[Double]] = []
            for k in kLo...kHi {
                let w = -2.0 * Double.pi * Double(k) / Double(n)
                var c = [Double](repeating: 0, count: n), s = [Double](repeating: 0, count: n)
                for j in 0..<n {
                    let a = w * Double(j)
                    c[j] = cos(a)
                    s[j] = sin(a)
                }
                cosines.append(c)
                sines.append(s)
            }
            self.cosines = cosines
            self.sines = sines
        }
    }

    /// How regular breathing is: the share of the 0.15 to 0.40 Hz power held by its strongest frequency.
    /// nil with too few beats.
    static func respRegularity(_ beats: [(Double, Double)], tables: inout [Int: RespDFT]) -> Double? {
        guard beats.count >= 12, let t0 = beats.first?.0, let tN = beats.last?.0, tN > t0 else { return nil }
        let n = Int(ceil((tN - t0) / 0.25 - 1e-9))
        guard n >= 16 else { return nil }

        var y = [Double](repeating: 0, count: n)
        var segment = 0
        for i in 0..<n {
            let t = t0 + 0.25 * Double(i)
            while segment < beats.count - 2 && beats[segment + 1].0 < t { segment += 1 }
            let (ta, va) = beats[segment], (tb, vb) = beats[segment + 1]
            y[i] = tb <= ta ? va : va + min(max((t - ta) / (tb - ta), 0), 1) * (vb - va)
        }
        let mean = y.reduce(0, +) / Double(n)
        for i in 0..<n { y[i] -= mean }

        let kLo = Int(ceil(0.15 * 0.25 * Double(n)))
        let kHi = Int(floor(0.40 * 0.25 * Double(n)))
        guard kHi >= kLo, kLo >= 0 else { return nil }
        let table: RespDFT
        if let cached = tables[n] {
            table = cached
        } else {
            table = RespDFT(n: n, kLo: kLo, kHi: kHi)
            tables[n] = table
        }
        var maxPower = 0.0, sumPower = 0.0
        y.withUnsafeBufferPointer { values in
            for k in kLo...kHi {
                var re = 0.0, im = 0.0
                table.cosines[k - kLo].withUnsafeBufferPointer { c in
                    table.sines[k - kLo].withUnsafeBufferPointer { s in
                        for j in 0..<n {
                            re += values[j] * c[j]
                            im += values[j] * s[j]
                        }
                    }
                }
                let power = re * re + im * im
                sumPower += power
                if power > maxPower { maxPower = power }
            }
        }
        return sumPower == 0 ? nil : maxPower / sumPower
    }

    // MARK: - Staging

    /// A still wrist: a raised heart rate alone can't vote an epoch awake.
    static func motionQuiescent(_ epoch: Epoch) -> Bool {
        epoch.moveFrac <= 0 && epoch.jerkMax <= epoch.jerkScale * jerkFloorGateMult
    }

    /// REM is held back at sleep onset, fading to nothing an hour later.
    static func remLatencyGuard(_ minutesSinceOnset: Double) -> Double {
        remLatencyPenalty * min(1.0, max(0.0, 1.0 - minutesSinceOnset / remLatencyMinutes))
    }

    /// Deep sleep comes early in the night and REM rises toward morning. In `Stage` order.
    static func cyclePrior(_ clock: Double, _ minutesSinceOnset: Double) -> [Double] {
        [1.2 * max(0.0, 1.0 - clock / 0.55), 1.0 * clock - remLatencyGuard(minutesSinceOnset), 0, 0]
    }

    /// The first epoch of the first 5 minutes without an awake epoch.
    static func sustainedSleepOnset(_ labels: [Stage]) -> Int? {
        var run = 0
        for index in labels.indices {
            if labels[index] == .awake {
                run = 0
                continue
            }
            run += 1
            if run >= onsetSustainedEpochs { return index - onsetSustainedEpochs + 1 }
        }
        return nil
    }

    /// The most likely path through the night's stages.
    static func viterbi(_ emissions: [[Double]]) -> [Stage] {
        guard let first = emissions.first else { return [] }
        let stages = Stage.allCases.count
        // The floor keeps a zero in the transition matrix from becoming minus infinity.
        let logT = transition.map { row in row.map { log(max($0, 1e-9)) } }
        var current = first
        var back: [[Int]] = []
        back.reserveCapacity(emissions.count)
        for t in emissions.indices.dropFirst() {
            var next = [Double](repeating: 0, count: stages)
            var pointers = [Int](repeating: 0, count: stages)
            for s in 0..<stages {
                var bestPrevious = 0
                var bestValue = current[0] + logT[0][s]
                for p in 1..<stages {
                    let value = current[p] + logT[p][s]
                    if value > bestValue {
                        bestValue = value
                        bestPrevious = p
                    }
                }
                next[s] = bestValue + emissions[t][s]
                pointers[s] = bestPrevious
            }
            current = next
            back.append(pointers)
        }
        var last = 0
        for s in 1..<stages where current[s] > current[last] { last = s }
        var path = [last]
        for pointers in back.reversed() {
            last = pointers[last]
            path.append(last)
        }
        return path.reversed().compactMap { Stage(rawValue: $0) }
    }

    /// Standardizes values within the night. A missing value is neutral, and a flat channel stays neutral.
    private static func standardizer(_ values: [Double?]) -> (Double?) -> Double {
        let present = values.compactMap { $0 }
        guard !present.isEmpty else { return { _ in 0 } }
        let mean = present.reduce(0, +) / Double(present.count)
        let spread = (present.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) } / Double(present.count)).squareRoot()
        let divisor = spread == 0 ? 1.0 : spread
        return { value in value.map { ($0 - mean) / divisor } ?? 0 }
    }

    /// One stage per epoch. All comparisons are within the night.
    static func stageEpochs(_ epochs: [Epoch]) -> [Stage] {
        guard !epochs.isEmpty else { return [] }
        let zHR = standardizer(epochs.map(\.hr))
        let zVar = standardizer(epochs.map(\.hrVar))
        let zMove = standardizer(epochs.map { Optional($0.moveFrac) })
        let zResp = standardizer(epochs.map(\.respReg))

        let flatness = epochs.compactMap(\.hrFlat11).sorted()
        func flatnessRank(_ value: Double?) -> Double {
            guard let value, !flatness.isEmpty else { return 0.5 }
            var low = 0, high = flatness.count
            while low < high {
                let middle = (low + high) / 2
                if flatness[middle] <= value { low = middle + 1 } else { high = middle }
            }
            return Double(low) / Double(flatness.count)
        }

        let deep = Stage.deep.rawValue, rem = Stage.rem.rawValue, light = Stage.light.rawValue, awake = Stage.awake.rawValue
        var emissions: [[Double]] = []
        emissions.reserveCapacity(epochs.count)
        for epoch in epochs {
            let hr = zHR(epoch.hr), variation = zVar(epoch.hrVar), movement = zMove(epoch.moveFrac)
            let gate = deepGateSlope * max(0.0, flatnessRank(epoch.hrFlat11) - deepGateThresh)
            let cardiac = 0.8 * variation + 0.4 * hr
            let awakeCardiac = motionQuiescent(epoch) ? min(0.0, cardiac) : cardiac
            var emission = [Double](repeating: 0, count: Stage.allCases.count)
            emission[deep] = -1.1 * variation - 0.5 * movement - gate + baseLogPrior[deep]
            emission[rem] = 0.6 * variation - 0.6 * movement + 0.4 * hr + baseLogPrior[rem]
            emission[light] = baseLogPrior[light]
            emission[awake] = 1.0 * movement + awakeCardiac + baseLogPrior[awake]
            // The REM guard needs the sleep onset, which only the first pass can find.
            let prior = cyclePrior(epoch.clock, .infinity)
            for stage in emission.indices { emission[stage] += prior[stage] }
            if epoch.jerkMax > epoch.jerkScale * jerkFloorGateMult { emission[awake] += motionGateBoost }
            if let regularity = epoch.respReg {
                let z = zResp(regularity)
                emission[deep] += respWeight * z
                emission[rem] -= respWeight * z
            }
            emissions.append(emission)
        }

        let provisional = viterbi(emissions)
        let origin = sustainedSleepOnset(provisional).map { epochs[$0].minutesSinceOnset } ?? 0
        for index in epochs.indices {
            emissions[index][rem] -= remLatencyGuard(epochs[index].minutesSinceOnset - origin)
        }
        return viterbi(emissions)
    }
}
