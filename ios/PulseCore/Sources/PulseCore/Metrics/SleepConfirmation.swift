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

/// The stricter stage of sleep detection. Spec: docs/METRICS.md §4, steps 6-9.
///
/// `classify` + `sessions` find candidates: minutes that are fairly still with a fairly low heart
/// rate. Sitting at a computer can pass that. A candidate only becomes a sleep here, when it starts
/// with a long stretch of near-zero motion and a calm heart rate, and the heart rate sits clearly
/// below the same person's awake resting level.
extension SleepDetector {
    /// A minute at or below this much movement (`MinuteSample.movement`) is near-zero motion.
    /// Real night of 2026-11-18: 95% of asleep minutes were under 2.2, half of the awake evening above 2.
    public static let nearStillActivity = 2.5
    /// Minutes of sustained stillness needed to start a sleep.
    public static let onsetMinutes = 45
    /// The same, when the band reported no motion at all and only heart rate can be judged.
    public static let onsetMinutesWithoutMotion = 90
    /// Share of the onset minutes that must be still, and calm in heart rate.
    public static let onsetShare = 0.85
    /// Longest moving stretch allowed inside the onset (a short awake burst).
    public static let longestOnsetBurst = 5
    /// A heart rate this far above the median is not calm.
    public static let heartRateSpike = 8.0
    /// A sleep's heart rate must sit this far below the awake level (or 8% of it, if that is more).
    public static let minimumHeartRateDrop = 5.0
    /// More than this share of raised heart-rate minutes means the person was awake.
    public static let maximumRaisedShare = 0.25
    /// Heart-rate surges (2+ minutes, 10+ bpm over the median) per hour that sleep does not have.
    public static let maximumSurgesPerHour = 2.0
    /// Right after the onset a sleep has to settle: at most one surge in this many minutes.
    public static let settlingMinutes = 90
    /// This many minutes of being up, within `activePeriodWindow`, end a sleep. A shorter wake-up stays inside it.
    public static let activePeriodMinutes = 30
    public static let activePeriodWindow = 35
    /// Candidates this close together are one night: a wake-up under 30 minutes, plus the few minutes
    /// around it that Cole-Kripke also scores as awake.
    public static let shortWakeGap = 36
    /// Sleep after a wake-up has to last this many minutes to count as going back to sleep.
    public static let shortestLastStretch = 30
    /// A heart rate this far above the sleep's own median counts as being up.
    public static let awakeHeartRateRise = 8.0

    /// The candidates that really are sleep, trimmed to where the sleep starts and ends.
    /// - Parameters:
    ///   - activity: movement per minute, without the band's resting offset (`MinuteSample.movement`).
    ///   - rawActivity: the band's own values, to tell a still wrist from a band reporting no motion at all.
    public static func confirmed(_ candidates: [Session], asleep: [Bool], hr: [Double?],
                                 activity: [Double?], rawActivity: [Double?]) -> [Session] {
        var excluded = [Bool](repeating: false, count: hr.count)
        for candidate in candidates { for i in candidate.start..<candidate.end { excluded[i] = true } }

        var out: [Session] = []
        for candidate in candidates {
            let worn = (candidate.start..<candidate.end).filter { hr[$0] != nil }
            let moving = worn.filter { (rawActivity[$0] ?? 0) > 0 }
            let motionKnown = !worn.isEmpty && Double(moving.count) >= 0.2 * Double(worn.count)
            let onset = motionKnown ? onsetMinutes : onsetMinutesWithoutMotion
            let sleepingRates = worn.filter { asleep[$0] }.compactMap { hr[$0] }
            guard !sleepingRates.isEmpty else { continue }
            let usual = Stats.median(sleepingRates)

            var cursor = candidate.start
            while cursor + onset <= candidate.end {
                guard let start = (cursor...(candidate.end - onset)).first(where: {
                    startsSleep(at: $0, length: onset, hr: hr, activity: activity)
                }) else { break }
                let stop = firstActivePeriod(from: start + onset, before: candidate.end, usual: usual, hr: hr, activity: activity)
                let limit = stop ?? candidate.end
                guard let last = (start..<limit).last(where: { asleep[$0] }) else { break }
                let end = stop == nil ? candidate.end : last + 1
                if looksAsleep(start: start, end: end, asleep: asleep, hr: hr, activity: activity, excluded: excluded) {
                    out.append(session(start: start, end: end, asleep: asleep))
                }
                guard let stop else { break }
                cursor = stop + activePeriodMinutes
            }
        }
        return out
    }

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

    private static func isStill(_ i: Int, hr: [Double?], activity: [Double?]) -> Bool {
        hr[i] != nil && (activity[i] ?? .infinity) <= nearStillActivity
    }

    /// Sustained near-zero motion with a steady heart rate over the whole onset.
    private static func startsSleep(at start: Int, length: Int, hr: [Double?], activity: [Double?]) -> Bool {
        let window = start..<(start + length)
        let needed = onsetShare * Double(length)
        guard isStill(start, hr: hr, activity: activity),
              Double(window.filter { isStill($0, hr: hr, activity: activity) }.count) >= needed else { return false }
        var burst = 0
        for i in window {
            burst = isStill(i, hr: hr, activity: activity) ? 0 : burst + 1
            if burst > longestOnsetBurst { return false }
        }
        let rates = window.compactMap { hr[$0] }
        guard !rates.isEmpty else { return false }
        let median = Stats.median(rates)
        guard Double(rates.filter { $0 <= median + heartRateSpike }.count) >= needed else { return false }
        // A surge with a moving wrist is a short wake-up. A surge with a still wrist is someone awake
        // and sitting, so the sleep can't have started yet.
        var stillSurge = 0
        for i in window {
            if let rate = hr[i], rate >= median + 10, isStill(i, hr: hr, activity: activity) {
                stillSurge += 1
                if stillSurge >= 2 { return false }
            } else {
                stillSurge = 0
            }
        }
        return surges(in: start..<min(start + settlingMinutes, hr.count), above: median, hr: hr) <= 1
    }

    /// Separate stretches of 2 or more minutes with a heart rate 10+ bpm above `median`.
    private static func surges(in range: Range<Int>, above median: Double, hr: [Double?]) -> Int {
        var count = 0, run = 0
        for i in range {
            if let rate = hr[i], rate >= median + 10 {
                run += 1
                if run == 2 { count += 1 }
            } else {
                run = 0
            }
        }
        return count
    }

    /// Joins candidates split by a short wake-up, when the person really went back to sleep afterwards.
    /// Lying quietly for a few minutes after getting up is not more sleep.
    public static func joiningShortWakes(_ candidates: [Session], asleep: [Bool]) -> [Session] {
        var out: [Session] = []
        for candidate in candidates {
            if let last = out.last, candidate.start - last.end <= shortWakeGap, candidate.asleep >= shortestLastStretch {
                out[out.count - 1] = session(start: last.start, end: candidate.end, asleep: asleep)
            } else {
                out.append(candidate)
            }
        }
        return out
    }

    /// The first long stretch of being up (moving, or a heart rate well above the sleep's), which ends the sleep.
    private static func firstActivePeriod(from start: Int, before end: Int, usual: Double, hr: [Double?],
                                          activity: [Double?]) -> Int? {
        func isUp(_ i: Int) -> Bool {
            guard let rate = hr[i] else { return false }
            return (activity[i] ?? 0) > nearStillActivity || rate >= usual + awakeHeartRateRise
        }
        guard start < end else { return nil }
        return (start..<end).first { i in
            isUp(i) && (i..<min(i + activePeriodWindow, hr.count)).filter(isUp).count >= activePeriodMinutes
        }
    }

    /// Heart rate: steady through the sleep, and clearly below the awake resting level.
    private static func looksAsleep(start: Int, end: Int, asleep: [Bool], hr: [Double?], activity: [Double?],
                                    excluded: [Bool]) -> Bool {
        let sleeping = (start..<end).filter { asleep[$0] }.compactMap { hr[$0] }
        guard !sleeping.isEmpty else { return false }
        let median = Stats.median(sleeping)
        let rates = (start..<end).compactMap { hr[$0] }
        let raised = rates.filter { $0 >= median + 10 }.count
        guard Double(raised) < maximumRaisedShare * Double(rates.count) else { return false }
        let hours = Double(end - start) / 60
        guard Double(surges(in: start..<end, above: median, hr: hr)) <= maximumSurgesPerHour * hours else { return false }
        guard let awake = awakeRestingHeartRate(around: start..<end, hr: hr, activity: activity, excluded: excluded) else {
            return end - start >= 180       // no awake data to compare with: only a full night counts
        }
        return median <= awake - max(minimumHeartRateDrop, 0.08 * awake)
    }

    /// Median heart rate of calm awake minutes in the 12 hours before the sleep, or after it when
    /// there are too few before (the first night on the band). nil = not enough of either.
    private static func awakeRestingHeartRate(around sleep: Range<Int>, hr: [Double?], activity: [Double?],
                                              excluded: [Bool]) -> Double? {
        let calm: (Range<Int>) -> [Double] = { range in
            range.filter { !excluded[$0] && (activity[$0] ?? .infinity) < 30 }.compactMap { hr[$0] }
        }
        let before = calm(max(0, sleep.lowerBound - 720)..<sleep.lowerBound)
        if before.count >= 60 { return Stats.median(before) }
        let after = calm(sleep.upperBound..<min(hr.count, sleep.upperBound + 720))
        return after.count >= 60 ? Stats.median(after) : nil
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
