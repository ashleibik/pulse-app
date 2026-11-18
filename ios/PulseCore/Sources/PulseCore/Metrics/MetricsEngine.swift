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
///   2. estimate the chance of being asleep per minute (SleepModel), group into sessions, keep the
///      finished ones, and apply what the user corrected
///   3. for each calendar day: main sleep -> resting HR + overnight HRV
///   4. baseline = previous 14 days; sleep need; recovery; day strain; plain-language explanation
public enum MetricsEngine {
    /// 2: sleeps must be confirmed and finished (docs/METRICS.md §4, steps 6-9).
    /// 3: calibrated on a real night: movement without the band's resting offset, short wake-ups stay
    ///    inside a sleep, cleaner beats for HRV, and one definition of the awake minutes of a sleep.
    /// 4: sleep is a probability per minute from several signals, learned from the person's own nights and edits.
    public static let algorithmVersion = 4
    /// The building blocks that must match the Python reference (shared/test-vectors/metrics_v2.json).
    /// The confirmation stage on top of them is Swift only.
    public static let sharedFormulaVersion = 2
    public static let baselineDays = 14

    /// Minute-by-minute arrays with no gaps.
    struct Timeline {
        var start: Date
        var hr: [Double?]
        var activity: [Double?]
        /// `MinuteSample.movement`: what sleep detection judges, because `activity` holds a resting offset.
        var movement: [Double?]
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
                         movement: Array(repeating: nil, count: count),
                         rr: Array(repeating: [], count: count),
                         source: sorted.allSatisfy { $0.source == .simulated } ? .simulated : last.source)
        for m in sorted where m.isWorn {
            let i = Int((m.start.timeIntervalSince(first.start) / 60).rounded())
            guard i >= 0 && i < count else { continue }
            t.hr[i] = m.averageHeartRate
            t.activity[i] = m.averageActivity
            t.movement[i] = m.movement
            t.rr[i] = m.rrIntervalsMs.map { Double($0) }
        }
        return t
    }

    /// The user's corrections, oldest first, on top of what was detected. A time the user left as it
    /// was follows the detection, so better detection can still move it; a time they changed stays.
    static func applying(_ corrections: [SleepCorrection], to detected: [SleepDetector.Session], timeline tl: Timeline,
                         asleep: [Bool]) -> [SleepDetector.Session] {
        var sessions = detected
        for correction in corrections.sorted(by: { $0.createdAt < $1.createdAt }) {
            let matching = sessions.filter { correction.applies(toStart: tl.date($0.start), end: tl.date($0.end)) }
            sessions.removeAll { correction.applies(toStart: tl.date($0.start), end: tl.date($0.end)) }
            guard var start = correction.start, var end = correction.end else { continue }
            if start == correction.detectedStart, let first = matching.first { start = tl.date(first.start) }
            if end == correction.detectedEnd, let last = matching.last { end = tl.date(last.end) }
            let from = max(0, tl.index(start)), to = min(tl.count, tl.index(end))
            guard from < to else { continue }
            sessions.append(SleepDetector.session(start: from, end: to, asleep: asleep))
        }
        return sessions.sorted { $0.start < $1.start }
    }

    /// Counts each sleep's minutes from its phases, so its totals match what the Sleep screens show.
    /// Returns the sleeps and one flag per minute of the timeline: asleep inside a sleep.
    static func described(_ sessions: [SleepDetector.Session], timeline tl: Timeline) -> (sessions: [SleepDetector.Session], asleep: [Bool]) {
        var asleep = [Bool](repeating: false, count: tl.count)
        for session in sessions {
            let range = session.start..<session.end
            let phases = SleepTimeline.phases(hr: Array(tl.hr[range]), movement: Array(tl.movement[range]))
            for (offset, phase) in phases.enumerated() { asleep[session.start + offset] = phase != .awake }
        }
        return (sessions.map { SleepDetector.session(start: $0.start, end: $0.end, asleep: asleep) }, asleep)
    }

    public static func run(minutes: [MinuteSample], profile: MetricsProfile = MetricsProfile(),
                           calendar: Calendar, now: Date, corrections: [SleepCorrection] = []) -> MetricsResult {
        var cache = SleepModelCache()
        return run(minutes: minutes, profile: profile, calendar: calendar, now: now, corrections: corrections, sleepCache: &cache)
    }

    /// - Parameter sleepCache: what the last run worked out. Weeks whose data didn't change are reused from it.
    public static func run(minutes: [MinuteSample], profile: MetricsProfile = MetricsProfile(),
                           calendar: Calendar, now: Date, corrections: [SleepCorrection] = [],
                           sleepCache: inout SleepModelCache) -> MetricsResult {
        guard let tl = timeline(minutes) else {
            sleepCache = SleepModelCache()
            return MetricsResult(sleeps: [], days: [])
        }

        // 1-2. Sleep: the chance of being asleep per minute, then the sleeps in it (docs/METRICS.md §4).
        let probability = SleepModel.run(timeline: tl, calendar: calendar, corrections: corrections, cache: &sleepCache)
        let (detected, candidates) = SleepModel.sessions(probability: probability)
        let finished = detected
            .filter { session in
                SleepDetector.isFinished(session, asleep: candidates, hr: tl.hr, activity: tl.movement,
                                         minutesSinceEnd: now.timeIntervalSince(tl.date(session.end)) / 60)
            }
        let (found, asleep) = described(applying(corrections, to: finished, timeline: tl, asleep: candidates), timeline: tl)
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
