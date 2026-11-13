import Foundation

/// Personal settings the formulas need.
public struct MetricsProfile: Sendable, Equatable {
    public var maxHeartRate: Double
    public var sex: BiologicalSex
    public var sleepGoalMinutes: Double

    public init(maxHeartRate: Double = 190, sex: BiologicalSex = .unspecified, sleepGoalMinutes: Double = 480) {
        self.maxHeartRate = maxHeartRate
        self.sex = sex
        self.sleepGoalMinutes = sleepGoalMinutes
    }
}

public struct MetricsResult: Sendable {
    public var sleeps: [SleepSession]
    public var days: [DailySummary]
}

/// Raw minutes in -> sleep sessions + daily summaries out. Pure function: same input, same output.
///
/// Steps (docs/METRICS.md):
///   1. lay the minutes on a gap-aware timeline (missing minutes = not worn)
///   2. detect sleep (Cole-Kripke + HR gate) and group into sessions
///   3. for each calendar day: main sleep -> resting HR + overnight HRV
///   4. baseline = previous 14 days; sleep need; recovery; day strain; plain-language explanation
public enum MetricsEngine {
    public static let algorithmVersion = 1
    public static let baselineDays = 14

    /// Minute-by-minute arrays with no gaps.
    struct Timeline {
        var start: Date
        var hr: [Double?]
        var activity: [Double?]
        var rr: [[Double]]
        var source: DataSource

        var count: Int { hr.count }
        func date(_ index: Int) -> Date { start.addingTimeInterval(Double(index) * 60) }
        func index(_ date: Date) -> Int { Int((date.timeIntervalSince(start) / 60).rounded(.down)) }
    }

    static func timeline(_ minutes: [MinuteSample]) -> Timeline? {
        let sorted = minutes.sorted { $0.start < $1.start }
        guard let first = sorted.first, let last = sorted.last else { return nil }
        let count = Int((last.start.timeIntervalSince(first.start) / 60).rounded()) + 1
        var t = Timeline(start: first.start,
                         hr: Array(repeating: nil, count: count),
                         activity: Array(repeating: nil, count: count),
                         rr: Array(repeating: [], count: count),
                         source: sorted.allSatisfy { $0.source == .simulated } ? .simulated : last.source)
        for m in sorted where m.isWorn {
            let i = Int((m.start.timeIntervalSince(first.start) / 60).rounded())
            guard i >= 0 && i < count else { continue }
            t.hr[i] = m.averageHeartRate
            t.activity[i] = m.averageActivity
            t.rr[i] = m.rrIntervalsMs.map { Double($0) }
        }
        return t
    }

    public static func run(minutes: [MinuteSample], profile: MetricsProfile = MetricsProfile(),
                           calendar: Calendar, now: Date) -> MetricsResult {
        guard let tl = timeline(minutes) else { return MetricsResult(sleeps: [], days: []) }

        // 1-2. Sleep. HR threshold per 24 h block starting at local noon (docs/METRICS.md §4).
        let startMidnight = calendar.startOfDay(for: tl.start)
        var anchor = calendar.date(byAdding: .hour, value: 12, to: startMidnight)!
        if anchor > tl.start { anchor = calendar.date(byAdding: .day, value: -1, to: anchor)! }
        let blocks = (0..<tl.count).map { Int((tl.date($0).timeIntervalSince(anchor) / 86_400).rounded(.down)) }
        let asleep = SleepDetector.classify(hr: tl.hr, activity: tl.activity, blocks: blocks)
        let found = SleepDetector.sessions(asleep)
        let sleeps = found.map { s -> SleepSession in
            // Deterministic ID from the start time: re-running the engine updates, not duplicates.
            var idSource = SeededRandom(seed: UInt64(bitPattern: Int64(tl.date(s.start).timeIntervalSince1970)))
            return SleepSession(id: idSource.uuid(), start: tl.date(s.start), end: tl.date(s.end),
                                asleepMinutes: s.asleep, awakeMinutes: s.awake, disturbances: s.disturbances,
                                isNap: s.isNap, source: tl.source)
        }

        // 3-4. Days. If data starts late in the evening, that day is incomplete: start the next day.
        let firstMidnight = calendar.startOfDay(for: tl.start)
        var day = tl.start.timeIntervalSince(firstMidnight) < 6 * 3600
            ? firstMidnight
            : calendar.date(byAdding: .day, value: 1, to: firstMidnight)!
        let lastDay = calendar.startOfDay(for: now)

        struct Night { var hrv: Double?; var rhr: Double? }
        var days: [DailySummary] = []
        var nights: [Night] = []
        var previousStrain: Double?
        var previousNeed: Double?
        var previousAsleep: Double?

        while day <= lastDay {
            let next = calendar.date(byAdding: .day, value: 1, to: day)!

            // Main sleep = longest non-nap session that ends on this day.
            let main = found
                .filter { !$0.isNap && tl.date($0.end) >= day && tl.date($0.end) < next }
                .max { $0.span < $1.span }

            var rhr: Double?
            var hrv: Double?
            var asleepMinutes: Int?
            if let main {
                let range = main.start..<main.end
                rhr = RestingHeartRate.lowestSustained(range.map { asleep[$0] ? tl.hr[$0] : nil })
                hrv = HRV.overnightRMSSD(minuteRR: range.map { tl.rr[$0] }, asleep: range.map { asleep[$0] })
                asleepMinutes = main.asleep
            }

            // Baseline: previous 14 days that have values.
            let window = nights.suffix(baselineDays)
            let baseHRV = window.compactMap(\.hrv)
            let baseRHR = window.compactMap(\.rhr)

            let need = Recovery.sleepNeed(goal: profile.sleepGoalMinutes, previousStrain: previousStrain,
                                          previousNeed: previousNeed, previousAsleep: previousAsleep)
            let score = Recovery.score(hrv: hrv, rhr: rhr, sleepMinutes: asleepMinutes.map { Double($0) },
                                       need: need, baselineHRV: baseHRV, baselineRHR: baseRHR)

            // Day strain from every minute of the calendar day.
            let lo = max(0, tl.index(day)), hi = min(tl.count, tl.index(next))
            let dayHR = lo < hi ? Array(tl.hr[lo..<hi]) : []
            let restForStrain = rhr ?? (baseRHR.isEmpty ? 60 : Stats.mean(baseRHR))
            let strain = Strain.fromTRIMP(Strain.trimp(dayHR, resting: restForStrain,
                                                       maximum: profile.maxHeartRate, sex: profile.sex))

            let baselineHRVMean = baseHRV.isEmpty ? nil : Stats.mean(baseHRV)
            let baselineRHRMean = baseRHR.isEmpty ? nil : Stats.mean(baseRHR)
            let needMinutes = Int(need.rounded())
            let explanation = (score == nil && hrv != nil && baseHRV.count < Recovery.minimumBaselineNights)
                ? PulseFormat.learningExplanation(nightsSoFar: baseHRV.count, needed: Recovery.minimumBaselineNights,
                                                  sleepMinutes: asleepMinutes, sleepNeedMinutes: needMinutes)
                : PulseFormat.recoveryExplanation(hrv: hrv, baselineHRV: baselineHRVMean, restingHR: rhr,
                                                  baselineRestingHR: baselineRHRMean, sleepMinutes: asleepMinutes,
                                                  sleepNeedMinutes: needMinutes)

            days.append(DailySummary(date: day, recoveryScore: score, strain: strain, sleepMinutes: asleepMinutes,
                                     sleepNeedMinutes: needMinutes, restingHeartRate: rhr, hrvRMSSD: hrv,
                                     baselineRestingHeartRate: baselineRHRMean, baselineHRV: baselineHRVMean,
                                     explanation: explanation, source: tl.source))
            nights.append(Night(hrv: hrv, rhr: rhr))
            previousStrain = strain
            previousNeed = need
            previousAsleep = asleepMinutes.map { Double($0) }
            day = next
        }
        return MetricsResult(sleeps: sleeps, days: days)
    }

    /// Strain for a time range (e.g. one workout).
    public static func strain(of minutes: [MinuteSample], from start: Date, to end: Date,
                              restingHR: Double, profile: MetricsProfile = MetricsProfile()) -> Double {
        let hr = minutes.filter { $0.start >= start && $0.start < end }.map(\.averageHeartRate)
        return Strain.fromTRIMP(Strain.trimp(hr, resting: restingHR, maximum: profile.maxHeartRate, sex: profile.sex))
    }
}

/// Demo data for the app: SIMULATED raw minutes, but every summary is computed by the REAL engine.
/// (The generator's own "truth" summaries are only used by tests.)
public enum DemoData {
    public static func make(config: FakeDataConfig, profile: MetricsProfile = MetricsProfile(),
                            calendar: Calendar) -> FakeDataset {
        let raw = FakeDataGenerator.generate(config)
        let result = MetricsEngine.run(minutes: raw.minutes, profile: profile, calendar: calendar, now: config.endDate)
        let workouts = raw.workouts.map { workout -> Workout in
            var w = workout
            let rest = result.days.first { calendar.isDate($0.date, inSameDayAs: w.start) }?.restingHeartRate ?? 55
            w.strain = MetricsEngine.strain(of: raw.minutes, from: w.start, to: w.end, restingHR: rest, profile: profile)
            return w
        }
        return FakeDataset(minutes: config.includeMinuteSamples ? raw.minutes : [],
                           sleeps: result.sleeps, workouts: workouts, days: result.days)
    }
}
