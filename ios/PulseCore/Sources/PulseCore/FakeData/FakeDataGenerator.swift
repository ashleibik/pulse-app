import Foundation

/// Settings for the fake data generator.
public struct FakeDataConfig: Sendable {
    public var days: Int
    public var seed: UInt64
    /// "Now" for the simulation. Nothing is generated after this moment.
    public var endDate: Date
    public var timeZone: TimeZone
    public var restingHeartRate: Double
    public var baselineHRV: Double      // RMSSD, ms
    public var maxHeartRate: Double
    /// Raw minute samples are big (~43k for 30 days). Turn off when you only need summaries.
    public var includeMinuteSamples: Bool

    public init(days: Int = 30, seed: UInt64 = 42, endDate: Date = Date(), timeZone: TimeZone = .current,
                restingHeartRate: Double = 54, baselineHRV: Double = 62, maxHeartRate: Double = 190,
                includeMinuteSamples: Bool = true) {
        self.days = days
        self.seed = seed
        self.endDate = endDate
        self.timeZone = timeZone
        self.restingHeartRate = restingHeartRate
        self.baselineHRV = baselineHRV
        self.maxHeartRate = maxHeartRate
        self.includeMinuteSamples = includeMinuteSamples
    }
}

/// Everything the generator produces. All records have `source == .simulated`.
public struct FakeDataset: Sendable {
    public var minutes: [MinuteSample]
    public var sleeps: [SleepSession]
    public var workouts: [Workout]
    public var days: [DailySummary]
}

/// Generates realistic-looking band data so the UI and metrics can be built before the band exists.
///
/// It simulates a body, not random numbers:
///   * A hidden day-to-day "readiness" level that drops after hard days and short nights.
///   * Readiness drives that night's resting HR (lower = better) and HRV (higher = better).
///   * Sleep: HR starts high, dips in ~90-minute cycles, rises toward morning, with brief awakenings.
///   * Daytime: everyday movement with occasional walks. 0-2 workouts per day.
///   * RR intervals are generated beat by beat with a known RMSSD, and per-second HR is derived
///     from them, like a real optical sensor does. So HR and RR always agree.
///   * Every third day the band is "charging" for 40 minutes (a gap, so the UI must handle missing data).
///
/// The `days` summaries hold the simulation's TRUE values. Phase 3's metrics engine must recover
/// numbers close to them from the raw minutes. That's how we'll test it.
public struct FakeDataGenerator {

    public static func generate(_ config: FakeDataConfig = FakeDataConfig()) -> FakeDataset {
        var generator = FakeDataGenerator(config: config)
        return generator.run()
    }

    // MARK: - Internal plan types

    struct Awakening { var start: Date; var minutes: Int }

    struct NightPlan {
        var start: Date
        var end: Date
        var restingHR: Double
        var hrv: Double
        var awakenings: [Awakening]
        var durationMinutes: Double { end.timeIntervalSince(start) / 60 }
    }

    struct WorkoutPlan {
        var kind: WorkoutKind
        var start: Date
        var end: Date
        var intensity: Double      // fraction of heart-rate reserve (0 = resting HR, 1 = max HR)
        var load: Double { end.timeIntervalSince(start) / 60 * intensity * intensity / 45 }
    }

    struct DayPlan {
        var dayStart: Date
        var night: NightPlan
        var workouts: [WorkoutPlan]
        var readiness: Double      // -1 (wrecked) ... +1 (fresh)
        var chargingGap: Range<Date>?
        var load: Double           // feeds strain; 0.25 = ordinary day with no training
    }

    enum SegmentKind {
        case asleep(NightPlan)
        case workout(WorkoutPlan, restingHR: Double)
        case charging
    }

    struct Segment { var start: Date; var end: Date; var kind: SegmentKind }

    // MARK: - State

    let config: FakeDataConfig
    var rng: SeededRandom
    let calendar: Calendar

    init(config: FakeDataConfig) {
        self.config = config
        self.rng = SeededRandom(seed: config.seed)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = config.timeZone
        self.calendar = cal
    }

    mutating func run() -> FakeDataset {
        let plans = planDays()
        let minutes = simulateMinutes(plans)
        let workouts = buildWorkouts(plans, minutes: minutes)
        let sleeps = buildSleeps(plans)
        let days = buildSummaries(plans, workouts: workouts)
        return FakeDataset(minutes: config.includeMinuteSamples ? minutes : [],
                           sleeps: sleeps, workouts: workouts, days: days)
    }

    // MARK: - 1. Plan each day

    mutating func planDays() -> [DayPlan] {
        let lastDay = calendar.startOfDay(for: config.endDate)
        var plans: [DayPlan] = []
        var readiness = 0.0
        var previousLoad = 0.8

        for i in 0..<config.days {
            let dayStart = calendar.date(byAdding: .day, value: i - (config.days - 1), to: lastDay)!

            // Night ending this morning. Bedtime around 23:00 the evening before.
            let bedtimeOffset = rng.normal(mean: -60, sd: 35) * 60
            let sleepHours = min(9.3, max(5.0, rng.normal(mean: 7.4, sd: 0.75)))
            let nightStart = floorToMinute(dayStart.addingTimeInterval(bedtimeOffset))
            let nightEnd = floorToMinute(nightStart.addingTimeInterval(sleepHours * 3600))

            // Readiness: carries over from yesterday, hurt by yesterday's load, helped by sleep.
            let sleepEffect = (sleepHours - 7.4) / 0.75 * 0.12
            readiness = 0.5 * readiness + rng.normal(sd: 0.3) - 0.35 * (previousLoad - 0.8) + sleepEffect
            readiness = min(1, max(-1, readiness))

            let restingHR = config.restingHeartRate - 3.5 * readiness + rng.normal(sd: 0.8)
            let hrv = config.baselineHRV * exp(0.22 * readiness + rng.normal(sd: 0.05))

            var awakenings: [Awakening] = []
            for _ in 0..<Int(rng.uniform(2...7.99)) {
                let at = nightStart.addingTimeInterval(rng.uniform(0.1...0.95) * sleepHours * 3600)
                awakenings.append(Awakening(start: floorToMinute(at), minutes: 1 + Int(rng.unit() * 5)))
            }
            awakenings.sort { $0.start < $1.start }

            // Training: less likely when wrecked.
            var workouts: [WorkoutPlan] = []
            if rng.chance(readiness < -0.4 ? 0.35 : 0.65) {
                let kind = pickWorkoutKind()
                let (minutesRange, intensityRange) = Self.profile(for: kind)
                let morning = rng.chance(0.4)
                let start = morning
                    ? nightEnd.addingTimeInterval(rng.uniform(30...75) * 60)
                    : dayStart.addingTimeInterval(rng.uniform(17...19) * 3600)
                let duration = rng.uniform(minutesRange) * 60
                let intensity = min(0.95, rng.uniform(intensityRange) + 0.03 * readiness)
                workouts.append(WorkoutPlan(kind: kind, start: floorToMinute(start),
                                            end: floorToMinute(start.addingTimeInterval(duration)),
                                            intensity: intensity))
            }
            if rng.chance(0.25) {   // lunchtime walk
                let start = floorToMinute(dayStart.addingTimeInterval((12.25 + rng.uniform(0...0.5)) * 3600))
                workouts.append(WorkoutPlan(kind: .walk, start: start,
                                            end: start.addingTimeInterval(rng.uniform(20...40).rounded() * 60),
                                            intensity: rng.uniform(0.30...0.40)))
            }
            workouts.sort { $0.start < $1.start }

            let charging: Range<Date>? = (i % 3 == 1)
                ? dayStart.addingTimeInterval(15 * 3600)..<dayStart.addingTimeInterval(15 * 3600 + 40 * 60)
                : nil

            let load = 0.25 + workouts.reduce(0) { $0 + $1.load }
            previousLoad = load
            plans.append(DayPlan(dayStart: dayStart,
                                 night: NightPlan(start: nightStart, end: nightEnd, restingHR: restingHR,
                                                  hrv: hrv, awakenings: awakenings),
                                 workouts: workouts, readiness: readiness, chargingGap: charging, load: load))
        }
        return plans
    }

    mutating func pickWorkoutKind() -> WorkoutKind {
        let table: [(WorkoutKind, Double)] = [(.run, 3), (.ride, 2), (.strength, 2), (.hiit, 1), (.walk, 1)]
        var roll = rng.unit() * table.reduce(0) { $0 + $1.1 }
        for (kind, weight) in table {
            roll -= weight
            if roll < 0 { return kind }
        }
        return .run
    }

    /// (duration in minutes, intensity as fraction of heart-rate reserve)
    static func profile(for kind: WorkoutKind) -> (ClosedRange<Double>, ClosedRange<Double>) {
        switch kind {
        case .run: (30...60, 0.70...0.85)
        case .ride: (45...90, 0.60...0.78)
        case .strength: (40...65, 0.45...0.60)
        case .hiit: (20...35, 0.78...0.90)
        case .walk: (30...60, 0.30...0.42)
        case .other: (30...45, 0.50...0.65)
        }
    }

    // MARK: - 2. Simulate minute by minute

    mutating func simulateMinutes(_ plans: [DayPlan]) -> [MinuteSample] {
        guard let first = plans.first, let last = plans.last else { return [] }

        // Flatten everything into time-sorted, non-overlapping segments.
        var segments: [Segment] = []
        for p in plans {
            segments.append(Segment(start: p.night.start, end: p.night.end, kind: .asleep(p.night)))
            for w in p.workouts {
                segments.append(Segment(start: w.start, end: w.end, kind: .workout(w, restingHR: p.night.restingHR)))
            }
            if let gap = p.chargingGap {
                segments.append(Segment(start: gap.lowerBound, end: gap.upperBound, kind: .charging))
            }
        }
        segments.sort { $0.start < $1.start }

        let simEnd = min(config.endDate, calendar.date(byAdding: .day, value: 1, to: last.dayStart)!)
        var minutes: [MinuteSample] = []
        minutes.reserveCapacity(Int(simEnd.timeIntervalSince(first.night.start) / 60) + 1)

        var segIndex = 0
        var dayRestingHR = first.night.restingHR
        var walkMinutesLeft = 0
        var beatClock = BeatClock()
        var t = first.night.start

        while t.addingTimeInterval(60) <= simEnd {
            while segIndex < segments.count && segments[segIndex].end <= t { segIndex += 1 }
            let current: SegmentKind? = (segIndex < segments.count && segments[segIndex].start <= t)
                ? segments[segIndex].kind : nil

            // What the body is doing this minute: base HR, HRV, movement.
            var baseHR: Double
            var hrv: Double
            var activityMean: Double
            var activitySD: Double
            var worn = true

            switch current {
            case .asleep(let night):
                dayRestingHR = night.restingHR
                let m = t.timeIntervalSince(night.start) / 60
                let isAwake = night.awakenings.contains {
                    t >= $0.start && t < $0.start.addingTimeInterval(Double($0.minutes) * 60)
                }
                if isAwake {
                    baseHR = night.restingHR + 14
                    hrv = night.hrv * 0.7
                    (activityMean, activitySD) = (60, 25)
                } else {
                    // falling-asleep elevation + 90-min cycles + pre-wake rise.
                    // Cycles swing ABOVE restingHR, so "resting HR" = the lowest sustained sleeping HR,
                    // which is exactly what the metrics engine measures (docs/METRICS.md).
                    baseHR = night.restingHR
                        + 7 * exp(-m / 45)
                        + 2.5 * (1 + sin(2 * .pi * m / 90))
                        + 4 * pow(m / night.durationMinutes, 3)
                        + rng.normal(sd: 0.6)
                    hrv = night.hrv
                    // occasional twitch / position change (not a full awakening)
                    (activityMean, activitySD) = rng.chance(0.02) ? (15, 5) : (1.5, 1.5)
                }
            case .workout(let w, let restingHR):
                let elapsed = t.timeIntervalSince(w.start) / 60
                let remaining = w.end.timeIntervalSince(t) / 60
                let ramp = min(1, elapsed / 5) * min(1, remaining / 4)
                let target = restingHR + w.intensity * (config.maxHeartRate - restingHR)
                var hr = restingHR + 20 + (target - restingHR - 20) * ramp
                switch w.kind {
                case .strength: hr += 12 * sin(2 * .pi * elapsed / 3)                       // sets and rests
                case .hiit: hr += (Int(elapsed) % 2 == 0 ? 12 : -10) * ramp                 // 1 min on / 1 min off
                default: break
                }
                baseHR = hr + rng.normal(sd: 1.5)
                hrv = 6 + 25 * (1 - w.intensity)
                (activityMean, activitySD) = Self.activityProfile(for: w.kind)
            case .charging:
                worn = false
                (baseHR, hrv, activityMean, activitySD) = (0, 0, 0, 0)
            case nil:
                if walkMinutesLeft == 0 && rng.chance(0.03) { walkMinutesLeft = Int(rng.uniform(3...12)) }
                let walking = walkMinutesLeft > 0
                if walking { walkMinutesLeft -= 1 }
                baseHR = dayRestingHR + (walking ? 32 : 14) + rng.normal(sd: 3)
                hrv = config.baselineHRV * (walking ? 0.35 : 0.5)
                (activityMean, activitySD) = walking ? (75, 15) : (12, 8)
            }

            minutes.append(makeMinute(start: t, worn: worn, baseHR: baseHR, hrv: hrv,
                                      activityMean: activityMean, activitySD: activitySD, beats: &beatClock))
            t = t.addingTimeInterval(60)
        }
        return minutes
    }

    static func activityProfile(for kind: WorkoutKind) -> (Double, Double) {
        switch kind {
        case .run: (180, 25)
        case .ride: (120, 20)
        case .strength: (90, 50)
        case .hiit: (200, 30)
        case .walk: (80, 15)
        case .other: (110, 30)
        }
    }

    /// Carries the heartbeat across minute boundaries so RR intervals are continuous.
    struct BeatClock {
        var pendingBeatOffset: Double? = nil   // seconds into the next minute when the pending beat ends
        var pendingRR: Double = 0
        var lastRR: Double = 1000
    }

    /// One minute: generate heartbeats, then derive per-second HR from them.
    mutating func makeMinute(start: Date, worn: Bool, baseHR: Double, hrv: Double,
                             activityMean: Double, activitySD: Double, beats: inout BeatClock) -> MinuteSample {
        guard worn else {
            beats = BeatClock()   // contact lost: the beat sequence restarts
            return MinuteSample(start: start, heartRate: Array(repeating: 0, count: 60), rrIntervalsMs: [],
                                activity: Array(repeating: 0, count: 60), source: .simulated)
        }

        // Successive differences of i.i.d. noise have SD = sigma * sqrt(2), so RMSSD ~= sigma * sqrt(2).
        // To hit a target RMSSD, use sigma = RMSSD / sqrt(2).
        let meanRR = 60_000 / max(baseHR, 30)
        let sigma = hrv / 2.0.squareRoot()

        var rrList: [UInt16] = []
        var beatEnds: [(offset: Double, rr: Double)] = []   // seconds into this minute
        var cursor: Double
        if let pending = beats.pendingBeatOffset {
            rrList.append(UInt16(beats.pendingRR.rounded()))
            beatEnds.append((pending, beats.pendingRR))
            cursor = pending
        } else {
            cursor = rng.uniform(0...0.8)
        }
        beats.pendingBeatOffset = nil
        while true {
            let rr = min(2000, max(300, meanRR + rng.normal(sd: sigma)))
            let end = cursor + rr / 1000
            if end >= 60 {
                beats.pendingBeatOffset = end - 60
                beats.pendingRR = rr
                break
            }
            rrList.append(UInt16(rr.rounded()))
            beatEnds.append((end, rr))
            cursor = end
        }

        // Per-second HR = 60000 / (most recent RR at that second), like a real optical sensor.
        var heartRate = [UInt8](repeating: 0, count: 60)
        var activity = [UInt8](repeating: 0, count: 60)
        var beatIndex = 0
        var currentRR = beats.lastRR
        for s in 0..<60 {
            while beatIndex < beatEnds.count && beatEnds[beatIndex].offset <= Double(s) + 1 {
                currentRR = beatEnds[beatIndex].rr
                beatIndex += 1
            }
            heartRate[s] = UInt8(min(220, max(30, (60_000 / currentRR).rounded())))
            activity[s] = UInt8(min(255, max(0, rng.normal(mean: activityMean, sd: activitySD).rounded())))
        }
        beats.lastRR = currentRR
        return MinuteSample(start: start, heartRate: heartRate, rrIntervalsMs: rrList,
                            activity: activity, source: .simulated)
    }

    // MARK: - 3. Build summaries from the plans (+ measured HR for workouts)

    mutating func buildWorkouts(_ plans: [DayPlan], minutes: [MinuteSample]) -> [Workout] {
        guard let firstStart = minutes.first?.start else { return [] }
        var result: [Workout] = []
        for p in plans {
            for w in p.workouts where w.end <= config.endDate {
                // Pull the per-second HR the simulation produced for this workout.
                let from = Int(w.start.timeIntervalSince(firstStart) / 60)
                let to = Int(w.end.timeIntervalSince(firstStart) / 60)
                guard from >= 0, to <= minutes.count, from < to else { continue }
                let hr = minutes[from..<to].flatMap(\.heartRate).filter { $0 > 0 }.map { Double($0) }
                guard !hr.isEmpty else { continue }

                var zones = [0, 0, 0, 0, 0]
                for bpm in hr {
                    let pct = bpm / config.maxHeartRate
                    if pct >= 0.5 { zones[min(4, Int((pct - 0.5) * 10))] += 1 }
                }
                let reserve = config.maxHeartRate - p.night.restingHR
                let calories = hr.reduce(0) { $0 + max(0, ($1 - p.night.restingHR) / reserve) * 0.2 }

                result.append(Workout(id: rng.uuid(), kind: w.kind, start: w.start, end: w.end,
                                      averageHeartRate: Int((hr.reduce(0, +) / Double(hr.count)).rounded()),
                                      maxHeartRate: Int(hr.max() ?? 0),
                                      strain: Self.strain(load: w.load),
                                      zoneSeconds: zones, calories: Int(calories.rounded()),
                                      source: .simulated))
            }
        }
        return result
    }

    mutating func buildSleeps(_ plans: [DayPlan]) -> [SleepSession] {
        var result: [SleepSession] = []
        for p in plans where p.night.end <= config.endDate {
            let awake = p.night.awakenings.reduce(0) { $0 + $1.minutes }
            let inBed = Int(p.night.durationMinutes)
            result.append(SleepSession(id: rng.uuid(), start: p.night.start, end: p.night.end,
                                       asleepMinutes: inBed - awake, awakeMinutes: awake,
                                       disturbances: p.night.awakenings.count, source: .simulated))
        }
        return result
    }

    mutating func buildSummaries(_ plans: [DayPlan], workouts: [Workout]) -> [DailySummary] {
        var summaries: [DailySummary] = []
        for (i, p) in plans.enumerated() {
            let slept = p.night.end <= config.endDate
            let asleep = slept
                ? Int(p.night.durationMinutes) - p.night.awakenings.reduce(0) { $0 + $1.minutes }
                : nil

            // Baseline = average of up to 14 previous nights (or tonight's, on day one).
            let window = plans[max(0, i - 14)..<max(i, 1)]
            let baselineHRV = window.map(\.night.hrv).reduce(0, +) / Double(window.count)
            let baselineRHR = window.map(\.night.restingHR).reduce(0, +) / Double(window.count)

            let previousLoad = i > 0 ? plans[i - 1].load : 0.8
            let sleepNeed = min(540, max(420, 450 + Int((previousLoad - 0.8) * 40)))

            let dayEnd = calendar.date(byAdding: .day, value: 1, to: p.dayStart)!
            let doneLoad = 0.25 + p.workouts.filter { $0.end <= config.endDate }.reduce(0) { $0 + $1.load }
            let fractionOfDay = min(1, max(0, config.endDate.timeIntervalSince(p.dayStart) / dayEnd.timeIntervalSince(p.dayStart)))
            let dayLoad = doneLoad - 0.25 * (1 - fractionOfDay)   // everyday load accrues through the day

            let recovery: Double? = slept
                ? min(99, max(3, 52 + 38 * p.readiness + rng.normal(sd: 4)))
                : nil

            let rhr = slept ? p.night.restingHR : nil
            let hrv = slept ? p.night.hrv : nil
            summaries.append(DailySummary(
                date: p.dayStart,
                recoveryScore: recovery,
                strain: Self.strain(load: dayLoad),
                sleepMinutes: asleep,
                sleepNeedMinutes: sleepNeed,
                restingHeartRate: rhr,
                hrvRMSSD: hrv,
                baselineRestingHeartRate: baselineRHR,
                baselineHRV: baselineHRV,
                explanation: PulseFormat.recoveryExplanation(
                    hrv: hrv, baselineHRV: baselineHRV, restingHR: rhr, baselineRestingHR: baselineRHR,
                    sleepMinutes: asleep, sleepNeedMinutes: sleepNeed),
                source: .simulated))
        }
        return summaries
    }

    /// Placeholder strain curve for simulated data: 0-21, saturating. Phase 3 replaces this with
    /// a TRIMP-based formula computed from real HR.
    static func strain(load: Double) -> Double {
        (21 * (1 - exp(-max(0, load))) * 10).rounded() / 10
    }

    func floorToMinute(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.down) * 60)
    }
}
