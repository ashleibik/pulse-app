import Foundation

/// A change the user made to a detected sleep. Kept apart from the detected data, because every
/// recalculation rebuilds the sleeps from the raw minutes.
public struct SleepCorrection: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    /// The sleep as it was when the user changed it.
    public var detectedStart: Date
    public var detectedEnd: Date
    /// The times the user chose. nil = "I wasn't asleep".
    public var start: Date?
    public var end: Date?
    public var createdAt: Date

    public init(id: UUID = UUID(), detectedStart: Date, detectedEnd: Date, start: Date? = nil, end: Date? = nil,
                createdAt: Date) {
        self.id = id
        self.detectedStart = detectedStart
        self.detectedEnd = detectedEnd
        self.start = start
        self.end = end
        self.createdAt = createdAt
    }

    /// True when a sleep shares at least half of the shorter of the two time spans with this one.
    public func applies(toStart otherStart: Date, end otherEnd: Date) -> Bool {
        let overlap = min(detectedEnd, otherEnd).timeIntervalSince(max(detectedStart, otherStart))
        let shorter = min(detectedEnd.timeIntervalSince(detectedStart), otherEnd.timeIntervalSince(otherStart))
        return overlap > 0 && shorter > 0 && overlap >= shorter / 2
    }
}

/// When a sleep found by `SleepModel` may be shown. Spec: docs/METRICS.md §4.
extension SleepDetector {
    /// A minute at or below this much movement (`MinuteSample.movement`) is near-zero motion.
    /// Real night of 2026-11-18: 95% of asleep minutes were under 2.2, half of the awake evening above 2.
    public static let nearStillActivity = 2.5

    /// A sleep is only final once the person is clearly up again. Until then it is not shown.
    /// - Parameter minutesSinceEnd: minutes between the end of the sleep and now.
    public static func isFinished(_ session: Session, asleep: [Bool], hr: [Double?], activity: [Double?],
                                  minutesSinceEnd: Double) -> Bool {
        if minutesSinceEnd >= 360 { return true }           // the band stopped syncing long ago
        let sleeping = (session.start..<session.end).filter { asleep[$0] }.compactMap { hr[$0] }
        guard !sleeping.isEmpty else { return false }
        let usual = Stats.median(sleeping)
        let after = session.end..<min(session.end + 45, hr.count)
        let up = after.filter { i in
            guard let rate = hr[i] else { return false }
            return (activity[i] ?? 0) > nearStillActivity || rate >= usual + 10
        }
        if up.count >= 15 { return true }
        // Taken off in the morning: an hour of the band reporting no wrist.
        return hr.count - session.end >= 60 && hr[session.end..<(session.end + 60)].allSatisfy { $0 == nil }
    }

    /// Counts the minutes of a span with the same rules as `sessions`.
    static func session(start: Int, end: Int, asleep: [Bool], napLimit: Int = 180) -> Session {
        var awake = 0, disturbances = 0
        var previousAsleep = true
        for k in start..<end {
            if !asleep[k] {
                awake += 1
                if previousAsleep { disturbances += 1 }
            }
            previousAsleep = asleep[k]
        }
        return Session(start: start, end: end, asleep: end - start - awake, awake: awake,
                       disturbances: disturbances, isNap: end - start < napLimit)
    }
}

/// Does the band's motion data actually change? Settings > Band > Motion check and the sync log.
public enum MotionCheck {
    public enum Verdict: Sendable, Equatable {
        case noData
        /// Every reading is zero: the accelerometer is not reaching Pulse.
        case noSignal
        /// There are readings, but they barely change.
        case flat
        case changing

        public var message: String {
            switch self {
            case .noData: "No band data for these minutes yet. Wear the band, wait a few minutes and sync."
            case .noSignal: "Every motion reading is zero, so the band's motion data is not being read."
            case .flat: "Motion barely changes. If you moved during these minutes, it is not being measured well."
            case .changing: "Motion readings change from minute to minute, so the sensor is being read."
            }
        }
    }

    /// Minutes whose averages differ by less than this count as unchanged.
    public static let changingSpread = 3.0

    public static func verdict(_ minutes: [MinuteSample]) -> Verdict {
        let worn = minutes.filter(\.isWorn)
        guard !worn.isEmpty else { return .noData }
        guard worn.contains(where: { $0.activity.contains { $0 > 0 } }) else { return .noSignal }
        let averages = worn.map(\.averageActivity)
        return (averages.max() ?? 0) - (averages.min() ?? 0) >= changingSpread ? .changing : .flat
    }

    /// One line per saved batch for the sync log: is the accelerometer alive, and how much does it move?
    public static func traceLine(_ records: [Whoop.HistoryRecord]) -> String {
        let readings = records.compactMap(\.accelG)
        guard !readings.isEmpty else {
            return "MOTION \(records.count) records: no usable accelerometer reading in any of them"
        }
        let sizes = readings.map { ($0[0] * $0[0] + $0[1] * $0[1] + $0[2] * $0[2]).squareRoot() }
        var previous: [Double]?
        let levels = readings.map { reading -> Int in
            defer { previous = reading }
            return Int(MinuteBuilder.activity(accelG: reading, previous: previous))
        }
        return String(format: "MOTION %d records, accel ok in %d, size %.3f-%.3f g, activity avg %.1f max %d",
                      records.count, readings.count, sizes.min() ?? 0, sizes.max() ?? 0,
                      Double(levels.reduce(0, +)) / Double(levels.count), levels.max() ?? 0)
    }
}
