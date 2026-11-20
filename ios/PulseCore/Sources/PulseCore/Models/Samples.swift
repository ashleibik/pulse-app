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
    /// 60 values: how far the wrist turned each second, in tenths of a degree (`WristAngle`).
    /// nil on minutes saved before Pulse stored this.
    public var wristAngle: [UInt8]?

    public init(start: Date, heartRate: [UInt8], rrIntervalsMs: [UInt16], activity: [UInt8], source: DataSource,
                wristAngle: [UInt8]? = nil) {
        self.wristAngle = wristAngle
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

    /// The highest value the band reports for a wrist lying still. On a real night it sat at a steady
    /// 0 to 10 for minutes at a time, changing only when the wrist settled into a new position.
    public static let restingOffsetLimit = 12.0

    /// How much the wrist really moved this minute. New minutes use how far the wrist turned. Older ones
    /// use the seconds above the minute's own steady level, and a steady level above
    /// `restingOffsetLimit` can't be a resting wrist, so all of it counts.
    public var movement: Double {
        if let turned = WristAngle.movement(wristAngle) { return turned }
        guard !activity.isEmpty else { return 0 }
        let sorted = activity.sorted()
        let mid = sorted.count / 2
        let steady = sorted.count % 2 == 1 ? Double(sorted[mid]) : (Double(sorted[mid - 1]) + Double(sorted[mid])) / 2
        guard steady <= Self.restingOffsetLimit else { return averageActivity }
        return activity.reduce(0.0) { $0 + max(0, Double($1) - steady) } / Double(activity.count)
    }
}
