// Ported to Swift for Pulse from NOOP, Packages/StrandAnalytics/Sources/StrandAnalytics/DaytimeStress.swift
// (the .dayRelative mode: calmReference, quantile, std, rawScore, squash, the motion gate and the post-activity shadow)
// and Strand/Screens/StressView.swift (StressBand).
// Source: https://github.com/ryanbr/noop at commit 2a1de7609843b095505274ad6fc811757210be80
// License: PolyForm Noncommercial License 1.0.0 <https://polyformproject.org/licenses/noncommercial/1.0.0>
// Required Notice: Copyright 2026 NoopApp
//
// Noncommercial use only. Changed for Pulse: the caller works out each hour's values from the band's minutes,
// and says how much of the hour was moving, because the WHOOP 4.0 data has no gravity reading in NOOP's units.

import Foundation

/// Scores each waking hour against the calmest hours of the same day, on a scale of 0 to 3.
enum NoopDaytimeStress {
    /// An hour needs this many seconds of heart rate.
    static let minHourHeartRateSeconds = 300
    static let wakingHours = 6..<22
    /// An hour with at least this share of moving time is exertion, not stress.
    static let activityMaskShare = 0.30
    /// The hour after a moving one stays masked while its heart rate is this far above the calm reference.
    static let postActivityShadowBPM = 8.0
    static let moderateFloor = 1.0
    static let highFloor = 2.0
    /// Below this many hours the calm reference is the plain mean.
    static let quartileHours = 4

    struct HourInput: Sendable, Equatable {
        var start: Date
        var hourOfDay: Int
        /// nil = too few seconds of heart rate.
        var meanHeartRate: Double?
        var rmssd: Double?
        var movingShare: Double
    }

    struct HourScore: Sendable, Equatable {
        var start: Date
        /// 0 to 3. nil = not scored.
        var level: Double?
        var isMasked: Bool
    }

    static func isWaking(_ hour: HourInput) -> Bool { wakingHours.contains(hour.hourOfDay) }
    static func isMoving(_ hour: HourInput) -> Bool { hour.movingShare >= activityMaskShare }

    static func mean(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    /// Population standard deviation. 0 without a spread.
    static func std(_ values: [Double]) -> Double {
        guard values.count > 1, let average = mean(values) else { return 0 }
        return (values.reduce(0) { $0 + ($1 - average) * ($1 - average) } / Double(values.count)).squareRoot()
    }

    /// Linear-interpolated quantile of sorted values.
    static func quantile(_ sorted: [Double], _ q: Double) -> Double {
        guard let first = sorted.first else { return 0 }
        guard sorted.count > 1 else { return first }
        let position = q * Double(sorted.count - 1)
        let low = Int(position), high = min(low + 1, sorted.count - 1)
        return sorted[low] + (position - Double(low)) * (sorted[high] - sorted[low])
    }

    /// The quartile toward the calm end, or the mean with fewer than 4 values.
    static func calmReference(_ values: [Double], calmIsLow: Bool) -> Double? {
        guard !values.isEmpty else { return nil }
        guard values.count >= quartileHours else { return mean(values) }
        return quantile(values.sorted(), calmIsLow ? 0.25 : 0.75)
    }

    /// Heart rate up and RMSSD down both push the score up.
    static func rawScore(heartRate: Double?, calmHeartRate: Double?, heartRateSpread: Double,
                         rmssd: Double?, calmRMSSD: Double?, rmssdSpread: Double) -> Double {
        var sum = 0.0
        if let heartRate, let calmHeartRate, heartRateSpread > 0.0001 { sum += (heartRate - calmHeartRate) / heartRateSpread }
        if let rmssd, let calmRMSSD, rmssdSpread > 0.0001 { sum += (calmRMSSD - rmssd) / rmssdSpread }
        return sum
    }

    /// 0 raw reads 1.5, the middle of the scale.
    static func squash(_ raw: Double) -> Double {
        min(max(3.0 / (1.0 + exp(-raw)), 0), 3)
    }

    /// - Parameter hours: every hour with data, in time order, including hours outside the waking window.
    /// - Returns: one score per waking hour.
    static func score(_ hours: [HourInput]) -> [HourScore] {
        let reference = hours.filter { isWaking($0) && !isMoving($0) }
        let heartRates = reference.compactMap(\.meanHeartRate)
        let rmssds = reference.compactMap(\.rmssd)
        let calmHeartRate = calmReference(heartRates, calmIsLow: true)
        let calmRMSSD = calmReference(rmssds, calmIsLow: false)
        let heartRateSpread = std(heartRates)
        let rmssdSpread = std(rmssds)
        let movingStarts = Set(hours.filter(isMoving).map(\.start))

        return hours.filter(isWaking).map { hour in
            guard let heartRate = hour.meanHeartRate else { return HourScore(start: hour.start, level: nil, isMasked: false) }
            let afterMoving = movingStarts.contains(hour.start.addingTimeInterval(-3600))
            let shadow = afterMoving && calmHeartRate.map { heartRate > $0 + postActivityShadowBPM } == true
            guard !isMoving(hour), !shadow else { return HourScore(start: hour.start, level: nil, isMasked: true) }
            let raw = rawScore(heartRate: heartRate, calmHeartRate: calmHeartRate, heartRateSpread: heartRateSpread,
                               rmssd: hour.rmssd, calmRMSSD: calmRMSSD, rmssdSpread: rmssdSpread)
            return HourScore(start: hour.start, level: squash(raw), isMasked: false)
        }
    }
}
