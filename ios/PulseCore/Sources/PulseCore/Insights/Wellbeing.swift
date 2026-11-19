import Foundation

// Everyday extras built on data Pulse already has. All of these are OUR OWN simple, documented
// estimates (not WHOOP's formulas). Each one says what it can't know.

// MARK: - Sleep consistency

/// How regular your bed and wake times are over the last 7 nights (0-100%).
/// 100% = the same times every night. Being off by 2 hours on average = 0%.
public enum SleepConsistency {

    /// `nil` with fewer than 3 nights.
    public static func score(_ sleeps: [SleepSession], calendar: Calendar) -> Double? {
        let nights = recentNights(sleeps)
        guard nights.count >= 3 else { return nil }
        let bedtimes = nights.map { minuteOfDay($0.start, calendar) }
        let wakeTimes = nights.map { minuteOfDay($0.end, calendar) }
        let spread = (meanDeviation(bedtimes) + meanDeviation(wakeTimes)) / 2      // minutes
        return Stats.clamp(100 - spread / 1.2, 0, 100)
    }

    static func recentNights(_ sleeps: [SleepSession]) -> [SleepSession] {
        Array(sleeps.filter { !$0.isNap }.sorted { $0.end < $1.end }.suffix(7))
    }

    static func minuteOfDay(_ date: Date, _ calendar: Calendar) -> Double {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return Double((parts.hour ?? 0) * 60 + (parts.minute ?? 0))
    }

    /// Distance between two clock times, the short way round (23:50 and 00:10 are 20 minutes apart).
    static func clockDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 1440)
        return min(d, 1440 - d)
    }

    /// Average clock time. Uses angles, so 23:50 and 00:10 average to midnight, not to noon.
    static func typicalTime(_ minutes: [Double]) -> Double {
        var x = 0.0, y = 0.0
        for m in minutes {
            let angle = m / 1440 * 2 * Double.pi
            x += cos(angle)
            y += sin(angle)
        }
        let mean = atan2(y, x) / (2 * Double.pi) * 1440
        return mean < 0 ? mean + 1440 : mean
    }

    static func meanDeviation(_ minutes: [Double]) -> Double {
        guard !minutes.isEmpty else { return 0 }
        let typical = typicalTime(minutes)
        return minutes.reduce(0) { $0 + clockDistance($1, typical) } / Double(minutes.count)
    }
}

// MARK: - Bedtime recommendation

/// "Be in bed by 10:45 PM": your usual wake-up time minus tonight's sleep need, with a little
/// extra for the time you normally lie awake.
public enum Bedtime {

    /// `nil` with fewer than 3 nights (no "usual wake-up time" yet).
    public static func recommended(sleeps: [SleepSession], needMinutes: Double, now: Date,
                                   calendar: Calendar) -> Date? {
        let nights = SleepConsistency.recentNights(sleeps)
        guard nights.count >= 3 else { return nil }
        let usualWake = SleepConsistency.typicalTime(nights.map { SleepConsistency.minuteOfDay($0.end, calendar) })
        // You are not asleep every minute in bed. Use your own average (kept between 75% and 100%).
        let efficiency = Stats.clamp(Stats.mean(nights.map(\.efficiency)), 0.75, 1.0)
        let inBedMinutes = needMinutes / efficiency

        // The next time your usual wake-up comes round.
        var wake = calendar.startOfDay(for: now).addingTimeInterval(usualWake * 60)
        if wake <= now { wake = calendar.date(byAdding: .day, value: 1, to: wake) ?? wake.addingTimeInterval(86_400) }
        return wake.addingTimeInterval(-inBedMinutes * 60)
    }
}

// MARK: - Respiratory rate

/// Breaths per minute, estimated from the beat-to-beat intervals. Breathing makes the heart speed
/// up and slow down slightly with every breath (respiratory sinus arrhythmia).
///
/// Honest limits: it needs clean beat-to-beat data, and it refuses to answer when the rhythm isn't stable.
public enum RespiratoryRate {

    /// A whole night, from OpenStrap's spectral method (docs/THIRD_PARTY.md). Each minute's beats are
    /// cleaned on their own and timed from the start of that minute. nil when there is no stable rhythm.
    public static func night(minutes: [MinuteSample]) -> Double? {
        let sorted = minutes.sorted { $0.start < $1.start }
        guard let origin = sorted.first?.start else { return nil }
        var beats: [Double] = [], times: [Double] = []
        for minute in sorted where minute.isWorn {
            var clock = minute.start.timeIntervalSince(origin) * 1000
            let raw = minute.rrIntervalsMs.map { Double($0) }
            for (interval, clean) in zip(raw, HRV.cleanBeats(raw)) {
                // The filler value is not a beat, so no time passes for it.
                if interval != HRV.fillerRRMs, (HRV.rrMinMs...HRV.rrMaxMs).contains(interval) { clock += interval }
                if let clean {
                    beats.append(clean)
                    times.append(clock)
                }
            }
        }
        return OpenStrapRespiration.rate(beats: beats, times: times)
    }
}

// MARK: - Stress

public enum StressLevel: Int, Sendable, CaseIterable, Comparable {
    case calm, medium, high

    public var title: String {
        switch self {
        case .calm: "Calm"
        case .medium: "Moderate"
        case .high: "High"
        }
    }

    /// NOOP's bands on the 0 to 3 scale.
    public init(score: Double) {
        self = score < NoopDaytimeStress.moderateFloor ? .calm : score < NoopDaytimeStress.highFloor ? .medium : .high
    }

    public static func < (a: StressLevel, b: StressLevel) -> Bool { a.rawValue < b.rawValue }
}

/// Daytime stress, hour by hour: each waking hour against the calmest hours of the same day
/// (`NoopDaytimeStress`). Spec: docs/METRICS.md §14.
///
/// Honest limits: caffeine, heat, a big meal or illness look the same as mental stress. It is a
/// hint, not a measurement of how you feel.
public enum StressMonitor {
    /// A minute counts as "still" below this activity value. Only for the sleep stress of `SleepPerformance`.
    public static let stillActivity = 8.0
    /// With fewer scored hours than this, the day has little to compare against.
    public static let settledHours = NoopDaytimeStress.quartileHours

    /// One minute of a night, for the sleep stress of `SleepPerformance`. `nil` = can't tell (moving, or the band was off).
    public static func level(for minute: MinuteSample, restingHR: Double, maxHR: Double) -> StressLevel? {
        guard let hr = minute.averageHeartRate, minute.averageActivity < stillActivity else { return nil }
        let reserve = (hr - restingHR) / max(1, maxHR - restingHR)
        if reserve < 0.10 { return .calm }
        return reserve < 0.20 ? .medium : .high
    }

    public struct Hour: Identifiable, Sendable, Equatable {
        public let start: Date
        /// 0 (calm) to 3 (high). `nil` = not scored.
        public let score: Double?
        /// true = left out because you were moving, or still recovering from it.
        public let isMoving: Bool
        /// The awake time measured in this hour.
        public let minutes: Int
        public var id: Date { start }
        public var level: StressLevel? { score.map { StressLevel(score: $0) } }
    }

    public struct Day: Sendable, Equatable {
        /// The newest hour scored in the last two clock hours. `nil` = nothing recent to say.
        public let current: Hour?
        /// true = the newest hour with data was left out because you were moving.
        public let isMovingNow: Bool
        public let calmMinutes: Int
        public let mediumMinutes: Int
        public let highMinutes: Int
        /// Scores are withheld until `settledHours`, so `hours` holds none before then.
        public let hours: [Hour]
        public let scoredHours: Int
        /// true = too few hours to compare yet. With two hours, one always reads calm and the other high.
        public var isEarlyRead: Bool { scoredHours < settledHours }
    }

    /// - Parameters:
    ///   - minutes: today's raw minutes.
    ///   - sleeps: sleep sessions (their minutes are skipped).
    ///   - workouts: recorded workouts (their minutes count as moving).
    public static func day(minutes: [MinuteSample], sleeps: [SleepSession], workouts: [Workout], now: Date,
                           calendar: Calendar) -> Day {
        guard let first = minutes.map(\.start).min(), let last = minutes.map(\.start).max() else {
            return Day(current: nil, isMovingNow: false, calmMinutes: 0, mediumMinutes: 0, highMinutes: 0, hours: [], scoredHours: 0)
        }
        let sleeping = sleeps.filter { $0.end > first && $0.start <= last }
        let training = workouts.filter { $0.isSuggestion != true && $0.end > first && $0.start <= last }

        var byHour: [Date: [MinuteSample]] = [:]
        for minute in minutes where minute.isWorn && minute.source != .simulated {
            if sleeping.contains(where: { $0.start <= minute.start && minute.start < $0.end }) { continue }
            if let hour = calendar.dateInterval(of: .hour, for: minute.start)?.start { byHour[hour, default: []].append(minute) }
        }

        var seconds: [Date: Int] = [:]
        let inputs = byHour.keys.sorted().map { start -> NoopDaytimeStress.HourInput in
            let inHour = (byHour[start] ?? []).sorted { $0.start < $1.start }
            let beats = inHour.flatMap(\.heartRate).filter { $0 > 0 }
            seconds[start] = beats.count
            let moving = inHour.filter { minute in
                minute.movement >= WorkoutDetector.walkMovement
                    || training.contains { $0.start <= minute.start && minute.start < $0.end }
            }
            // Each minute is cleaned alone, and the nil between minutes stops a pair forming across them.
            let clean = inHour.flatMap { HRV.cleanBeats($0.rrIntervalsMs.map(Double.init)) + [nil] }
            let enough = beats.count >= NoopDaytimeStress.minHourHeartRateSeconds
            return NoopDaytimeStress.HourInput(start: start, hourOfDay: calendar.component(.hour, from: start),
                                               meanHeartRate: enough ? Double(beats.reduce(0) { $0 + Int($1) }) / Double(beats.count) : nil,
                                               rmssd: HRV.rmssd(clean), movingShare: Double(moving.count) / Double(inHour.count))
        }

        let hours = NoopDaytimeStress.score(inputs).map {
            Hour(start: $0.start, score: $0.level, isMoving: $0.isMasked, minutes: Int((Double(seconds[$0.start] ?? 0) / 60).rounded()))
        }
        let scored = hours.filter { $0.score != nil }.count
        let newest = hours.last { now.timeIntervalSince($0.start) < 2 * 3600 && ($0.score != nil || $0.isMoving) }
        guard scored >= settledHours else {
            let withheld = hours.map { Hour(start: $0.start, score: nil, isMoving: $0.isMoving, minutes: $0.minutes) }
            return Day(current: nil, isMovingNow: newest?.isMoving == true, calmMinutes: 0, mediumMinutes: 0, highMinutes: 0,
                       hours: withheld, scoredHours: scored)
        }
        var counts = [0, 0, 0]
        for hour in hours { if let level = hour.level { counts[level.rawValue] += hour.minutes } }
        return Day(current: newest?.score == nil ? nil : newest, isMovingNow: newest?.isMoving == true,
                   calmMinutes: counts[0], mediumMinutes: counts[1], highMinutes: counts[2], hours: hours, scoredHours: scored)
    }
}

// MARK: - Energy

