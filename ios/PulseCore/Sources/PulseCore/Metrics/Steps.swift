import Foundation

/// Steps from the band's motion. Spec: docs/METRICS.md §15. Always an estimate.
///
/// A WHOOP 4.0 sends no step count, and its history keeps one motion reading a second: too few to see each footfall
/// (a step takes about half a second). So Pulse finds the seconds the owner was walking or running from how the wrist
/// moved, counts them at a typical cadence, and passes the result through NOOP's sleep-aware step counter
/// (`NoopSteps`). The owner's own step tests and Apple Watch days then set a personal factor.
public enum Steps {

    // MARK: - Walking and running

    /// A second moves when its activity (`MinuteBuilder.activity`) is at least this: about 0.08 g, or a 4.6° turn.
    public static let movingFloor: UInt8 = 40
    /// ...and the wrist turned at least this much (tenths of a degree, `WristAngle`), unless the movement alone
    /// reaches `strongMovement`. Shaking without turning is a car or a machine, not an arm swinging.
    public static let turnFloor: UInt8 = 30
    public static let strongMovement: UInt8 = 150
    /// Each second is judged with the 5 seconds on either side.
    public static let windowRadius = 5
    public static let fewestWornInWindow = 8
    /// Walking: at least this share of the window's worn seconds move...
    public static let movingShare = 0.6
    /// ...and at least half of them reach this. The owner's walking minutes on 2026-11-18 had a median of 117 to 234;
    /// sitting stayed under 15 with a few spikes, and a shaking car reads about 50.
    public static let walkingLevel: UInt8 = 80
    public static let walkingLevelShare = 0.5
    /// A walk lasts at least this many seconds. Inside a sleep, `shortestBoutInSleep`.
    public static let shortestBout = 12
    public static let shortestBoutInSleep = 20
    /// A pause this long or shorter (a door, a light) doesn't end a walk.
    public static let longestPause = 3
    /// Running: at least `runningStrongShare` of the window's seconds at `strongMovement` or more, and the heart rate at
    /// `runningReserveShare` of its reserve or more. Movement alone can't tell: walking around at home on 2026-11-18
    /// reached 150 in 63% of its seconds, at 86 bpm.
    public static let runningStrongShare = 0.5
    public static let runningReserveShare = 0.55
    /// Steps per second before the owner's references set a factor: 108 and 162 a minute.
    public static let walkingCadence = 1.8
    public static let runningCadence = 2.7
    /// Under this share of the day measured, the day says how long the band measured.
    public static let fullCoverage = 0.90
    /// Without a resting heart rate.
    public static let fallbackRestingHeartRate = 60.0

    public enum Gait: Int, Sendable {
        case none = 0, walk = 1, run = 2
    }

    /// One value per second from `start`.
    struct Seconds {
        var start: Date
        var heartRate: [UInt8]
        var activity: [UInt8]
        /// `WristAngle.noReading` where unknown.
        var turn: [UInt8]
        var count: Int { heartRate.count }
        var startTs: Int { Int(start.timeIntervalSince1970.rounded()) }
    }

    static func seconds(_ minutes: [MinuteSample], from start: Date, to end: Date) -> Seconds {
        let count = max(0, Int(end.timeIntervalSince(start).rounded(.down)))
        var out = Seconds(start: start, heartRate: [UInt8](repeating: 0, count: count),
                          activity: [UInt8](repeating: 0, count: count),
                          turn: [UInt8](repeating: WristAngle.noReading, count: count))
        for minute in minutes {
            let offset = Int(minute.start.timeIntervalSince(start).rounded())
            guard offset > -60, offset < count else { continue }
            let turned = minute.wristAngle?.count == 60 ? minute.wristAngle : nil
            for second in 0..<min(60, minute.heartRate.count, minute.activity.count) {
                let i = offset + second
                guard i >= 0, i < count else { continue }
                out.heartRate[i] = minute.heartRate[second]
                out.activity[i] = minute.activity[second]
                if let turned { out.turn[i] = turned[second] }
            }
        }
        return out
    }

    /// Walking, running or neither, for every second.
    /// - Parameter inSleep: true for the seconds inside a sleep, where a walk must last `shortestBoutInSleep`.
    static func gait(_ s: Seconds, restingHeartRate: Double, maxHeartRate: Double, inSleep: [Bool]? = nil) -> [Gait] {
        let n = s.count
        guard n > 0 else { return [] }
        var movingSum = [Int](repeating: 0, count: n + 1)
        var wornSum = movingSum, levelSum = movingSum, strongSum = movingSum, heartSum = movingSum
        for i in 0..<n {
            let worn = s.heartRate[i] > 0
            let a = s.activity[i]
            let turned = s.turn[i] == WristAngle.noReading || s.turn[i] >= turnFloor || a >= strongMovement
            movingSum[i + 1] = movingSum[i] + (worn && a >= movingFloor && turned ? 1 : 0)
            levelSum[i + 1] = levelSum[i] + (worn && a >= walkingLevel ? 1 : 0)
            wornSum[i + 1] = wornSum[i] + (worn ? 1 : 0)
            strongSum[i + 1] = strongSum[i] + (worn && a >= strongMovement ? 1 : 0)
            heartSum[i + 1] = heartSum[i] + Int(s.heartRate[i])
        }
        func window(_ i: Int) -> (lo: Int, hi: Int) { (max(0, i - windowRadius), min(n, i + windowRadius + 1)) }

        var candidate = [Bool](repeating: false, count: n)
        for i in 0..<n where s.heartRate[i] > 0 {
            let w = window(i)
            let worn = wornSum[w.hi] - wornSum[w.lo]
            guard worn >= fewestWornInWindow else { continue }
            candidate[i] = Double(movingSum[w.hi] - movingSum[w.lo]) >= movingShare * Double(worn)
                && Double(levelSum[w.hi] - levelSum[w.lo]) >= walkingLevelShare * Double(worn)
        }

        let runningRate = restingHeartRate + runningReserveShare * max(0, maxHeartRate - restingHeartRate)
        var out = [Gait](repeating: .none, count: n)
        var i = 0
        while i < n {
            guard candidate[i] else { i += 1; continue }
            var end = i + 1
            var j = end
            while j < n {
                if candidate[j] {
                    end = j + 1
                    j += 1
                } else if j - end < longestPause {
                    j += 1
                } else {
                    break
                }
            }
            let sleeping = inSleep.map { flags in (i..<end).contains { flags[$0] } } ?? false
            if end - i >= (sleeping ? shortestBoutInSleep : shortestBout) {
                for k in i..<end where candidate[k] {
                    let w = window(k)
                    let worn = wornSum[w.hi] - wornSum[w.lo]
                    let strong = Double(strongSum[w.hi] - strongSum[w.lo]) >= runningStrongShare * Double(worn)
                    let heart = Double(heartSum[w.hi] - heartSum[w.lo]) / Double(max(1, worn))
                    out[k] = strong && heart >= runningRate ? .run : .walk
                }
            }
            i = max(end, j)
        }
        return out
    }

    /// The seconds as NOOP's cumulative step counter: one reading per worn second, its activity class the second's gait.
    static func counterSamples(_ s: Seconds, gait: [Gait]) -> [NoopSteps.StepSample] {
        var total = 0.0
        var out: [NoopSteps.StepSample] = []
        out.reserveCapacity(s.count)
        for i in 0..<s.count where s.heartRate[i] > 0 {
            switch gait[i] {
            case .walk: total += walkingCadence
            case .run: total += runningCadence
            case .none: break
            }
            out.append(NoopSteps.StepSample(ts: s.startTs + i, counter: Int(total) & 0xffff, activityClass: gait[i].rawValue))
        }
        return out
    }

    /// The sleeps as NOOP's counter reads them, with the minutes Pulse marks awake inside each.
    static func counterSleeps(_ sleeps: [SleepSession], minutes: [MinuteSample]) -> [NoopSteps.SleepSession] {
        guard !sleeps.isEmpty else { return [] }
        var byMinute: [Int: MinuteSample] = [:]
        for minute in minutes { byMinute[Int(minute.start.timeIntervalSince1970) / 60] = minute }
        return sleeps.map { sleep in
            let first = Int(sleep.start.timeIntervalSince1970) / 60
            let last = Int((sleep.end.timeIntervalSince1970 - 1) / 60)
            let span = first <= last ? Array(first...last) : []
            let hr = span.map { byMinute[$0].flatMap { $0.isWorn ? $0.averageHeartRate : nil } }
            let movement = span.map { index in byMinute[index].flatMap { $0.isWorn ? $0.movement : nil } }
            let phases = SleepTimeline.phases(hr: hr, movement: movement)
            let wake = zip(span, phases).compactMap { minute, phase in phase == .awake ? (minute * 60)..<(minute * 60 + 60) : nil }
            return NoopSteps.SleepSession(start: Int(sleep.start.timeIntervalSince1970), end: Int(sleep.end.timeIntervalSince1970),
                                          wake: wake)
        }
    }

    static func sleepFlags(_ s: Seconds, sleeps: [SleepSession]) -> [Bool] {
        var flags = [Bool](repeating: false, count: s.count)
        for sleep in sleeps {
            let lo = max(0, Int(sleep.start.timeIntervalSince(s.start).rounded()))
            let hi = min(s.count, Int(sleep.end.timeIntervalSince(s.start).rounded()))
            if lo < hi { for i in lo..<hi { flags[i] = true } }
        }
        return flags
    }

    /// How far a walk or a step test looks past its ends, so the first and last seconds are judged like the others.
    static let padding: TimeInterval = 60

    static func overlapping(_ sleeps: [SleepSession], from start: Date, to end: Date) -> [SleepSession] {
        sleeps.filter { $0.end > start.addingTimeInterval(-padding) && $0.start < end.addingTimeInterval(padding) }
    }

    // MARK: - A day

    public struct Day: Equatable, Sendable {
        /// After the personal factor.
        public var total: Int
        /// One value per hour of the day from its first hour (23 or 25 on a clock-change day). After the factor.
        public var hourly: [Int]
        /// Before the personal factor: what the references are compared with.
        public var uncalibrated: Int
        public var walkingSeconds: Int
        public var runningSeconds: Int
        public var measuredMinutes: Int
        /// Under `fullCoverage` of the day so far was measured.
        public var isPartial: Bool
    }

    /// The day's steps. nil when the band has no data for the day.
    /// - Parameters:
    ///   - minutes: the day's raw minutes, ideally with a minute either side.
    ///   - end: the end of the day, or now for today.
    ///   - factor: the personal factor (`factor(_:)`).
    public static func day(minutes: [MinuteSample], sleeps: [SleepSession], dayStart: Date, end: Date, calendar: Calendar,
                           restingHeartRate: Double?, maxHeartRate: Double, factor: Double = 1) -> Day? {
        let inDay = minutes.filter { $0.start >= dayStart && $0.start < end && $0.isWorn }
        guard !inDay.isEmpty, end > dayStart else { return nil }
        let sleeps = overlapping(sleeps, from: dayStart, to: end)
        let padded = seconds(minutes, from: dayStart.addingTimeInterval(-padding), to: end.addingTimeInterval(padding))
        let gaits = gait(padded, restingHeartRate: restingHeartRate ?? fallbackRestingHeartRate, maxHeartRate: maxHeartRate,
                         inSleep: sleepFlags(padded, sleeps: sleeps))
        let samples = counterSamples(padded, gait: gaits)
        let sessions = counterSleeps(sleeps, minutes: minutes)

        let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
        var hourStarts: [Date] = []
        var hour = dayStart
        while hour < nextDay {
            hourStarts.append(hour)
            hour = calendar.date(byAdding: .hour, value: 1, to: hour) ?? hour.addingTimeInterval(3600)
        }
        var raw: [Int] = []
        for (index, from) in hourStarts.enumerated() {
            let to = min(index + 1 < hourStarts.count ? hourStarts[index + 1] : nextDay, end)
            raw.append(from < to ? counted(samples, from: from, to: to, sleeps: sessions) : 0)
        }
        let dayRange = Int(dayStart.timeIntervalSince(padded.start).rounded())..<Int(end.timeIntervalSince(padded.start).rounded())
        let inRange = gaits.indices.filter { dayRange.contains($0) }
        let hourly = raw.map { Int((Double($0) * factor).rounded()) }
        let elapsed = end.timeIntervalSince(dayStart) / 60
        return Day(total: hourly.reduce(0, +), hourly: hourly, uncalibrated: raw.reduce(0, +),
                   walkingSeconds: inRange.filter { gaits[$0] == .walk }.count,
                   runningSeconds: inRange.filter { gaits[$0] == .run }.count,
                   measuredMinutes: inDay.count, isPartial: Double(inDay.count) < fullCoverage * elapsed)
    }

    /// Steps the counter accepts between two times: the readings in [from, to), each compared with the one before.
    static func counted(_ samples: [NoopSteps.StepSample], from: Date, to: Date, sleeps: [NoopSteps.SleepSession]) -> Int {
        let lo = Int(from.timeIntervalSince1970.rounded()), hi = Int(to.timeIntervalSince1970.rounded())
        guard let first = samples.firstIndex(where: { $0.ts >= lo }) else { return 0 }
        var page = first > 0 ? [samples[first - 1]] : []
        var i = first
        while i < samples.count, samples[i].ts < hi {
            page.append(samples[i])
            i += 1
        }
        return NoopSteps.count(page, sleepSessions: sleeps).totalTicks
    }

    /// Steps before the personal factor between two times (a step test), and the share of those seconds measured.
    public static func window(minutes: [MinuteSample], sleeps: [SleepSession] = [], from start: Date, to end: Date,
                              restingHeartRate: Double?, maxHeartRate: Double) -> (steps: Int, coverage: Double) {
        guard end > start else { return (0, 0) }
        let sleeps = overlapping(sleeps, from: start, to: end)
        let padded = seconds(minutes, from: start.addingTimeInterval(-padding), to: end.addingTimeInterval(padding))
        let gaits = gait(padded, restingHeartRate: restingHeartRate ?? fallbackRestingHeartRate, maxHeartRate: maxHeartRate,
                         inSleep: sleepFlags(padded, sleeps: sleeps))
        let steps = counted(counterSamples(padded, gait: gaits), from: start, to: end,
                            sleeps: counterSleeps(sleeps, minutes: minutes))
        let lo = Int(padding), hi = min(padded.count, lo + Int(end.timeIntervalSince(start).rounded()))
        let worn = lo < hi ? (lo..<hi).filter { padded.heartRate[$0] > 0 }.count : 0
        return (steps, Double(worn) / max(1, end.timeIntervalSince(start)))
    }

    // MARK: - The owner's references

    /// A count Pulse is checked against: a step test (counted by hand) or a day's Apple Watch total.
    public struct Reference: Codable, Equatable, Sendable, Identifiable {
        public enum Kind: String, Codable, Sendable { case stepTest, appleWatchDay }
        public var id: UUID
        public var kind: Kind
        public var start: Date
        public var end: Date
        public var steps: Int
        public var createdAt: Date
        /// A step test: the band's own 100 Hz count of the same walk (`LiveSteps`). nil without the stream.
        public var liveSteps: Int?

        public init(id: UUID = UUID(), kind: Kind, start: Date, end: Date, steps: Int, createdAt: Date, liveSteps: Int? = nil) {
            self.id = id
            self.kind = kind
            self.start = start
            self.end = end
            self.steps = steps
            self.createdAt = createdAt
            self.liveSteps = liveSteps
        }
    }

    /// A reference with Pulse's own count for the same time. `uncalibrated` is nil while the band has no data for it.
    public struct Checked: Equatable, Sendable {
        public var reference: Reference
        public var uncalibrated: Int?
        /// Share of the reference's time the band measured.
        public var coverage: Double

        public init(reference: Reference, uncalibrated: Int?, coverage: Double) {
            self.reference = reference
            self.uncalibrated = uncalibrated
            self.coverage = coverage
        }

        /// Good enough to learn from: measured, with something counted on both sides.
        var isUsable: Bool {
            guard let uncalibrated else { return false }
            return coverage >= fullCoverage && uncalibrated >= fewestStepsToLearnFrom && reference.steps >= fewestStepsToLearnFrom
        }
    }

    /// A reference with fewer steps than this on either side says too little about the factor.
    public static let fewestStepsToLearnFrom = 100
    /// The factor stays within these, so one wrong entry can't make the count absurd.
    public static let factorRange = 0.5...2.0

    public struct Factor: Equatable, Sendable {
        public var value: Double
        public var stepTests: Int
        public var appleWatchDays: Int
        /// NOOP's 0 to 1 confidence, from 3 references on. nil before.
        public var confidence: Double?

        public static let none = Factor(value: 1, stepTests: 0, appleWatchDays: 0, confidence: nil)
        public var isCalibrated: Bool { stepTests + appleWatchDays > 0 }
    }

    /// The personal factor. From 3 usable references on, NOOP's fit (the weighted median of reference ÷ Pulse, each
    /// weighted by Pulse's count). With 1 or 2, the plain median. With none, 1.
    public static func factor(_ checked: [Checked]) -> Factor {
        let usable = checked.filter(\.isUsable)
        guard !usable.isEmpty else { return .none }
        let points = usable.map { NoopSteps.CalibrationPoint(motion: Double($0.uncalibrated ?? 0), steps: Double($0.reference.steps)) }
        let fit = NoopSteps.calibrate(points)
        let value = fit?.coefficient ?? NoopSteps.median(points.map { $0.steps / $0.motion })
        return Factor(value: min(factorRange.upperBound, max(factorRange.lowerBound, value)),
                      stepTests: usable.filter { $0.reference.kind == .stepTest }.count,
                      appleWatchDays: usable.filter { $0.reference.kind == .appleWatchDay }.count,
                      confidence: fit?.confidence)
    }

    /// Each reference against what Pulse would have said without it (its factor learned from the others only), so the
    /// error is never flattered by the reference it is checked on.
    public struct Comparison: Equatable, Sendable, Identifiable {
        public var reference: Reference
        /// nil while the band has no data for it.
        public var pulse: Int?
        /// (Pulse − reference) ÷ reference.
        public var difference: Double?
        public var isPartial: Bool
        public var id: UUID { reference.id }
    }

    public static func compare(_ checked: [Checked]) -> [Comparison] {
        checked.map { item in
            let others = checked.filter { $0.reference.id != item.reference.id }
            guard let uncalibrated = item.uncalibrated else {
                return Comparison(reference: item.reference, pulse: nil, difference: nil, isPartial: false)
            }
            let pulse = Int((Double(uncalibrated) * factor(others).value).rounded())
            let difference = item.reference.steps > 0 ? Double(pulse - item.reference.steps) / Double(item.reference.steps) : nil
            return Comparison(reference: item.reference, pulse: pulse, difference: difference,
                              isPartial: item.coverage < fullCoverage)
        }
    }

    /// The average size of the error, as a share. Partial days and references without data are left out.
    public static func averageError(_ comparisons: [Comparison]) -> Double? {
        let errors = comparisons.filter { !$0.isPartial }.compactMap(\.difference).map(abs)
        return errors.isEmpty ? nil : errors.reduce(0, +) / Double(errors.count)
    }
}
