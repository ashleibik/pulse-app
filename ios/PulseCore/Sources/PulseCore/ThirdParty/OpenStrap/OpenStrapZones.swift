// Ported to Swift from OpenStrap analytics, lib/src/onehz/workout/hr_zones.dart
// (zonesFromMaxHr, reserveZones, timeInZone).
// Source: https://github.com/OpenStrap/analytics at commit e59d63ccc39713a6deb2facfd1c8288a5203398a
// License: MIT, Copyright (c) 2026 OpenStrap. See docs/THIRD_PARTY.md for the full notice.
//
// Changed for Pulse: reserve zones accept one night of resting heart rate (OpenStrap waits for 14),
// because the owner asked for zones based on their own resting heart rate from the start.

import Foundation

/// Five heart-rate zones as bpm limits.
public struct HeartRateZoneSet: Sendable, Equatable {
    /// The lower limit of zones 1 to 5, in bpm.
    public let lowerLimits: [Double]
    /// True when the zones use heart-rate reserve (Karvonen), false for a share of maximum heart rate.
    public let usesReserve: Bool

    /// 0...4, or nil below zone 1.
    public func zone(for heartRate: Double) -> Int? {
        lowerLimits.lastIndex { heartRate >= $0 }
    }
}

public enum OpenStrapZones {
    static let edges = [0.50, 0.60, 0.70, 0.80, 0.90]

    public static func percentOfMax(maxHeartRate: Double) -> HeartRateZoneSet {
        HeartRateZoneSet(lowerLimits: edges.map { $0 * maxHeartRate }, usesReserve: false)
    }

    /// Karvonen zones: `resting + share × (max − resting)`, anchored on the median of the resting heart
    /// rates given. nil without a usable resting heart rate.
    public static func reserve(restingHistory: [Double], maxHeartRate: Double) -> HeartRateZoneSet? {
        let valid = restingHistory.filter { $0.isFinite && $0 > 0 }
        guard !valid.isEmpty else { return nil }
        let resting = Stats.median(valid)
        guard maxHeartRate > resting else { return nil }
        return HeartRateZoneSet(lowerLimits: edges.map { resting + $0 * (maxHeartRate - resting) }, usesReserve: true)
    }

    /// Reserve zones when a resting heart rate is known, otherwise a share of the maximum.
    public static func zones(restingHistory: [Double], maxHeartRate: Double) -> HeartRateZoneSet {
        reserve(restingHistory: restingHistory, maxHeartRate: maxHeartRate) ?? percentOfMax(maxHeartRate: maxHeartRate)
    }

    /// Seconds in each zone, counted from every second the band measured, so short peaks are not averaged away.
    public static func secondsInZones(_ minutes: [MinuteSample], zones: HeartRateZoneSet) -> [Int] {
        var seconds = [0, 0, 0, 0, 0]
        for minute in minutes {
            for rate in minute.heartRate where rate > 0 {
                if let zone = zones.zone(for: Double(rate)) { seconds[zone] += 1 }
            }
        }
        return seconds
    }
}
