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
/// up and slow down slightly with every breath (respiratory sinus arrhythmia), so counting those
/// waves counts breaths. Works best during sleep.
///
/// Honest limits: needs clean beat-to-beat data (whether the band stores it overnight is still
/// unverified), and it refuses to answer when the waves are irregular instead of guessing.
public enum RespiratoryRate {

    /// One window of beats (a few minutes). `nil` when there is no clear, regular breathing wave.
    public static func estimate(rrMs: [Double]) -> Double? {
        guard rrMs.count >= 90 else { return nil }
        // 1. Remove the slow drift: subtract the average of the surrounding beats.
        let half = 8
        var detrended: [Double] = []
        var times: [Double] = []
        var clock = 0.0
        for i in rrMs.indices {
            clock += rrMs[i] / 1000
            let window = rrMs[max(0, i - half)...min(rrMs.count - 1, i + half)]
            detrended.append(rrMs[i] - window.reduce(0, +) / Double(window.count))
            times.append(clock)
        }
        // 2. Smooth lightly (3 beats), so single noisy beats don't count as breaths.
        var smooth: [Double] = []
        for i in detrended.indices {
            let window = detrended[max(0, i - 1)...min(detrended.count - 1, i + 1)]
            smooth.append(window.reduce(0, +) / Double(window.count))
        }
        // 3. Each upward crossing of zero is one breath.
        var crossings: [Double] = []
        for i in 1..<smooth.count where smooth[i - 1] < 0 && smooth[i] >= 0 {
            crossings.append(times[i])
        }
        guard crossings.count >= 8, let first = crossings.first, let last = crossings.last, last > first else { return nil }
        // 4. Real breathing is regular. Random noise also crosses zero, but at irregular intervals.
        var gaps: [Double] = []
        for i in 1..<crossings.count { gaps.append(crossings[i] - crossings[i - 1]) }
        let meanGap = Stats.mean(gaps)
        let variance = gaps.reduce(0) { $0 + ($1 - meanGap) * ($1 - meanGap) } / Double(gaps.count)
        guard meanGap > 0, variance.squareRoot() / meanGap < 0.40 else { return nil }

        let rate = 60 / meanGap
        return (6...30).contains(rate) ? rate : nil
    }

    /// A whole night: the middle value of all 3-minute windows that gave a clear answer.
    public static func night(minutes: [MinuteSample]) -> Double? {
        let sorted = minutes.sorted { $0.start < $1.start }
        var estimates: [Double] = []
        var index = 0
        while index < sorted.count {
            let window = sorted[index..<min(index + 3, sorted.count)]
            let cleaned = HRV.cleanRR(window.flatMap { $0.rrIntervalsMs.map { Double($0) } }).compactMap { $0 }
            if let rate = estimate(rrMs: cleaned) { estimates.append(rate) }
            index += 3
        }
        return estimates.count >= 5 ? Stats.median(estimates) : nil
    }
}

// MARK: - Stress

public enum StressLevel: Int, Sendable, CaseIterable, Comparable {
    case calm, medium, high

    public var title: String {
        switch self {
        case .calm: "Calm"
        case .medium: "Elevated"
        case .high: "High"
        }
    }

    public static func < (a: StressLevel, b: StressLevel) -> Bool { a.rawValue < b.rawValue }
}

/// A simple daytime stress signal: how far your heart rate sits above resting **while you are
/// still**. Moving raises the heart rate for normal reasons, so moving minutes are ignored, and
/// so is sleep.
///
/// Honest limits: caffeine, heat, a big meal or illness look the same as mental stress. It is a
/// hint, not a measurement of how you feel.
public enum StressMonitor {
    /// A minute counts as "still" below this activity value (sitting is about 12 in METRICS.md terms,
    /// so this is "barely moving").
    public static let stillActivity = 8.0

    /// `nil` = can't tell (moving, or the band was off).
    public static func level(for minute: MinuteSample, restingHR: Double, maxHR: Double) -> StressLevel? {
        guard let hr = minute.averageHeartRate, minute.averageActivity < stillActivity else { return nil }
        let reserve = (hr - restingHR) / max(1, maxHR - restingHR)
        if reserve < 0.10 { return .calm }
        return reserve < 0.20 ? .medium : .high
    }

    public struct Hour: Identifiable, Sendable, Equatable {
        public let start: Date
        /// 0 (calm) ... 2 (high), averaged over the classified minutes. `nil` = no still minutes.
        public let score: Double?
        public var id: Date { start }
    }

    public struct Day: Sendable, Equatable {
        /// The level over the last half hour. `nil` = not enough still minutes to say.
        public let current: StressLevel?
        public let calmMinutes: Int
        public let mediumMinutes: Int
        public let highMinutes: Int
        public let hours: [Hour]
    }

    /// - Parameters:
    ///   - minutes: today's raw minutes.
    ///   - sleeps: sleep sessions (their minutes are skipped).
    public static func day(minutes: [MinuteSample], sleeps: [SleepSession], restingHR: Double, maxHR: Double,
                           now: Date, calendar: Calendar) -> Day {
        var counts = [0, 0, 0]
        var byHour: [Date: [Int]] = [:]
        var recent: [StressLevel] = []
        for minute in minutes.sorted(by: { $0.start < $1.start }) {
            if sleeps.contains(where: { $0.start <= minute.start && minute.start < $0.end }) { continue }
            guard let level = level(for: minute, restingHR: restingHR, maxHR: maxHR) else { continue }
            counts[level.rawValue] += 1
            let parts = calendar.dateComponents([.year, .month, .day, .hour], from: minute.start)
            if let hour = calendar.date(from: parts) { byHour[hour, default: []].append(level.rawValue) }
            if now.timeIntervalSince(minute.start) <= 30 * 60 { recent.append(level) }
        }
        var current: StressLevel?
        if recent.count >= 5 {
            let average = Double(recent.reduce(0) { $0 + $1.rawValue }) / Double(recent.count)
            current = StressLevel(rawValue: Int(average.rounded()))
        }
        let hours = byHour.keys.sorted().map { hour -> Hour in
            let values = byHour[hour] ?? []
            return Hour(start: hour, score: values.isEmpty ? nil : Double(values.reduce(0, +)) / Double(values.count))
        }
        return Day(current: current, calmMinutes: counts[0], mediumMinutes: counts[1], highMinutes: counts[2], hours: hours)
    }
}

// MARK: - Energy

/// Active calories for a stretch of time: a rough estimate from heart rate alone.
/// 12 kcal per minute at 100% of heart-rate reserve, scaled down linearly, counted only above
/// 15% of reserve (below that you are resting). No weight, no power meter: treat it as a ballpark.
public enum DailyEnergy {
    public static func activeCalories(minutes: [MinuteSample], restingHR: Double, maxHR: Double) -> Int {
        let reserveSize = max(1, maxHR - restingHR)
        var total = 0.0
        for minute in minutes {
            guard let hr = minute.averageHeartRate else { continue }
            let reserve = (hr - restingHR) / reserveSize
            if reserve > 0.15 { total += min(reserve, 1) * 12 }
        }
        return Int(total.rounded())
    }
}
