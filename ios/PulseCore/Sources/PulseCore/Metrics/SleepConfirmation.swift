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

    /// The answer "yes, this was sleep": the detected times, unchanged.
    public static func confirming(start: Date, end: Date, createdAt: Date) -> SleepCorrection {
        SleepCorrection(detectedStart: start, detectedEnd: end, start: start, end: end, createdAt: createdAt)
    }

    /// True when the user has already answered for a sleep at these times.
    public func answers(start otherStart: Date, end otherEnd: Date) -> Bool {
        if applies(toStart: otherStart, end: otherEnd) { return true }
        guard let start, let end else { return false }
        return SleepCorrection(detectedStart: start, detectedEnd: end, createdAt: createdAt).applies(toStart: otherStart, end: otherEnd)
    }
}

/// When a sleep found by `SleepModel` may be shown. Spec: docs/METRICS.md §4.
extension SleepDetector {
    /// A minute at or below this much movement (`MinuteSample.movement`) is near-zero motion.
    /// Real night of 2026-11-18: 95% of asleep minutes were under 2.2, half of the awake evening above 2.
    public static let nearStillActivity = 2.5

    /// Clearly awake minutes needed within `upWindowMinutes`, somewhere after the sleep.
    public static let upMinutes = 15
    public static let upWindowMinutes = 45
    /// An hour without the wrist after a sleep also ends it (the band was taken off).
    public static let offWristMinutes = 60
    /// After this long a sleep is shown whatever came after it (the band stopped syncing).
    public static let showAnywayMinutes = 360.0

    /// A sleep is only final once the person is clearly up again. Until then it is not shown.
    /// Getting up counts at any point after the sleep, not only in the first minutes: lying still in bed for an hour
    /// and then getting up still finishes it (the owner's morning sleep of 2026-11-20 waited 6 hours for that).
    /// - Parameters:
    ///   - minutesSinceEnd: minutes between the end of the sleep and now.
    ///   - nextStart: where the next sleep found after this one starts. Only the minutes before it can show the person was up.
    public static func isFinished(_ session: Session, asleep: [Bool], hr: [Double?], activity: [Double?],
                                  minutesSinceEnd: Double, nextStart: Int? = nil) -> Bool {
        if minutesSinceEnd >= showAnywayMinutes { return true }
        let sleeping = (session.start..<session.end).filter { asleep[$0] }.compactMap { hr[$0] }
        guard !sleeping.isEmpty else { return false }
        let usual = Stats.median(sleeping)
        func isUp(_ i: Int) -> Bool {
            guard let rate = hr[i] else { return false }
            return (activity[i] ?? 0) > nearStillActivity || rate >= usual + 10
        }
        let after = session.end..<min(nextStart ?? hr.count, hr.count)
        var up = 0, offWrist = 0
        for i in after {
            // 15 clearly awake minutes in any 45 after the sleep.
            if isUp(i) { up += 1 }
            if i - upWindowMinutes >= after.lowerBound, isUp(i - upWindowMinutes) { up -= 1 }
            if up >= upMinutes { return true }
            // Taken off: an hour of the band reporting no wrist.
            offWrist = hr[i] == nil ? offWrist + 1 : 0
            if offWrist >= offWristMinutes { return true }
        }
        return false
    }

    /// `isFinished` for every sleep, oldest first. A sleep followed by a finished one is finished too: the person woke from
    /// it, whether or not they got up in between.
    /// - Parameter minutesSinceEnd: minutes between a sleep's end (a timeline index) and now.
    static func finished(_ sessions: [Session], asleep: [Bool], hr: [Double?], activity: [Double?],
                         minutesSinceEnd: (Int) -> Double) -> [Bool] {
        var flags = [Bool](repeating: false, count: sessions.count)
        var laterIsFinished = false
        for k in sessions.indices.reversed() {
            let next = k + 1 < sessions.count ? sessions[k + 1].start : nil
            laterIsFinished = laterIsFinished
                || isFinished(sessions[k], asleep: asleep, hr: hr, activity: activity,
                              minutesSinceEnd: minutesSinceEnd(sessions[k].end), nextStart: next)
            flags[k] = laterIsFinished
        }
        return flags
    }

    /// Counts the minutes of a span with the same rules as `sessions`.
    /// - Parameter observed: false = no band data for that minute. It counts as neither asleep nor awake.
    static func session(start: Int, end: Int, asleep: [Bool], observed: [Bool]? = nil, napLimit: Int = 180) -> Session {
        var sleeping = 0, awake = 0, disturbances = 0
        var previousAsleep = true
        for k in start..<end {
            if asleep[k] {
                sleeping += 1
                previousAsleep = true
            } else if observed?[k] ?? true {
                awake += 1
                if previousAsleep { disturbances += 1 }
                previousAsleep = false
            }
        }
        return Session(start: start, end: end, asleep: sleeping, awake: awake,
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
