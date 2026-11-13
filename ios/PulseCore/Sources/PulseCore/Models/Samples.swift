import Foundation

/// Where a piece of data came from. Shown in the Debug screen and kept on every record,
/// so simulated data can never be mistaken for real data.
public enum DataSource: String, Codable, Sendable, CaseIterable {
    case history     // downloaded from the band's stored history
    case live        // streamed in real time while connected
    case manual      // entered by the user
    case simulated   // fake data generator
}

/// One minute of raw band data, stored as one record instead of 60.
///
/// Why minutes: 1 Hz for two weeks is ~1.2 million rows. As one row per minute it's 20,160,
/// which a phone database handles easily. See docs/PHASE0_PLAN.md §2D.
public struct MinuteSample: Codable, Sendable, Hashable {
    /// Start of the minute (seconds are always :00).
    public var start: Date
    /// 60 values, one per second, in bpm. 0 = no reading (off wrist, charging, bad signal).
    public var heartRate: [UInt8]
    /// Beat-to-beat (R-R) intervals that *ended* during this minute, in milliseconds.
    public var rrIntervalsMs: [UInt16]
    /// 60 values: movement intensity per second, 0 (still) ... 255 (very vigorous).
    public var activity: [UInt8]
    public var source: DataSource

    public init(start: Date, heartRate: [UInt8], rrIntervalsMs: [UInt16], activity: [UInt8], source: DataSource) {
        self.start = start
        self.heartRate = heartRate
        self.rrIntervalsMs = rrIntervalsMs
        self.activity = activity
        self.source = source
    }

    /// True if the band was worn for at least part of this minute.
    public var isWorn: Bool { heartRate.contains { $0 > 0 } }

    /// Average of the valid (non-zero) readings, or nil if there were none.
    public var averageHeartRate: Double? {
        let valid = heartRate.filter { $0 > 0 }
        guard !valid.isEmpty else { return nil }
        return Double(valid.reduce(0) { $0 + Int($1) }) / Double(valid.count)
    }

    public var averageActivity: Double {
        Double(activity.reduce(0) { $0 + Int($1) }) / Double(max(activity.count, 1))
    }
}
