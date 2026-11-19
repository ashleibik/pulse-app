import Foundation

/// Finds workouts in raw band data, so nobody has to press "start". Spec: docs/METRICS.md §10.
///
/// Three kinds of stretch are looked for:
/// - **Cardio:** heart rate held high for 12+ minutes (OpenStrap's detector).
/// - **Strength:** heart rate going up and down for 20+ minutes with the arms moving. NOOP's classifier decides
///   whether the pattern looks like sets and rests.
/// - **Walk:** 10+ minutes of sustained movement with a raised heart rate. Only suggested, never assumed: at one
///   reading a second the band can't see the rhythm of steps.
public enum WorkoutDetector {
    public static let minimumMinutes = 10
    /// Shorter than this is a mis-tap, not a workout.
    public static let minimumSavedSeconds = 60.0

    // Our choices, tuned on the owner's data: neither source has a detector for these patterns.
    static let strengthMinutes = 20
    static let strengthPauseMinutes = 5
    static let strengthLongestMinutes = 180
    static let strengthAverageReserve = 0.20
    static let strengthPeakReserve = 0.30
    static let strengthMovement = 8.0
    /// Sets and rests: the heart rate has to climb and fall by this much, this many times.
    static let strengthSwingBeats = 15.0
    static let strengthSwings = 3
    static let walkMinutes = 10
    static let walkPauseMinutes = 2
    static let walkMovement = 30.0
    static let walkReserve = 0.10

    /// True when a workout this long should not be saved.
    public static func isTooShort(start: Date, end: Date) -> Bool {
        end.timeIntervalSince(start) < minimumSavedSeconds
    }

    /// - Parameters:
    ///   - minutes: raw minutes, any order.
    ///   - body: for calories. Without it a workout has 0 calories, which the app shows as `--`.
    ///   - restingHeartRate: the resting heart rate of the day a minute belongs to. nil = unknown, 60 is used.
    public static func detect(minutes: [MinuteSample], profile: MetricsProfile = MetricsProfile(),
                              body: DailyCalories.Body? = nil, restingHeartRate: (Date) -> Double?) -> [Workout] {
        let sorted = minutes.filter(\.isWorn).sorted { $0.start < $1.start }
        var found: [Workout] = []
        for region in regions(sorted, profile: profile, restingHeartRate: restingHeartRate) {
            let window = Array(sorted[region])
            guard let first = window.first else { continue }
            let known = restingHeartRate(first.start)
            let rest = known ?? 60
            var taken: [Range<Date>] = []

            func add(_ range: Range<Date>, suggested: Bool = false, kind fixed: WorkoutKind? = nil) {
                let inside = window.filter { $0.start >= range.lowerBound && $0.start < range.upperBound }
                guard !inside.isEmpty else { return }
                var workout = build(inside, start: range.lowerBound, end: range.upperBound, kind: fixed ?? .other, profile: profile,
                                    body: body, resting: rest, restingKnown: known != nil, id: stableID(start: range.lowerBound))
                if fixed == nil { workout.kind = NoopWorkoutType.classify(features(inside, workout: workout, resting: rest, profile: profile)) }
                workout.isSuggestion = suggested ? true : nil
                workout.source = inside.allSatisfy { $0.source == .simulated } ? .simulated : .history
                found.append(workout)
                taken.append(range)
            }

            for bout in cardio(window, resting: rest, profile: profile) { add(bout) }
            for range in strength(window, resting: rest, profile: profile, excluding: taken) {
                let inside = window.filter { $0.start >= range.lowerBound && $0.start < range.upperBound }
                let draft = build(inside, start: range.lowerBound, end: range.upperBound, kind: .strength, profile: profile, body: body,
                                  resting: rest, restingKnown: known != nil, id: stableID(start: range.lowerBound))
                if NoopWorkoutType.classify(features(inside, workout: draft, resting: rest, profile: profile)) == .strength {
                    add(range, kind: .strength)
                }
            }
            for range in walks(window, resting: rest, profile: profile, excluding: taken) { add(range, suggested: true, kind: .walk) }
        }
        return found.sorted { $0.start < $1.start }
    }

    /// Stretches worth a closer look. Quiet minutes are skipped so that a sync stays fast with a long history.
    private static func regions(_ sorted: [MinuteSample], profile: MetricsProfile,
                                restingHeartRate: (Date) -> Double?) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var current: Range<Int>?
        for (index, minute) in sorted.enumerated() {
            let rest = restingHeartRate(minute.start) ?? 60
            let peak = Double(minute.heartRate.max() ?? 0)
            let raised = peak >= rest + strengthAverageReserve * max(1, profile.maxHeartRate - rest)
            let moving = minute.averageActivity >= walkMovement || (minute.wristAngle != nil && minute.movement >= walkMovement)
            guard raised || moving else { continue }
            if let open = current, minute.start.timeIntervalSince(sorted[open.upperBound - 1].start) <= 10 * 60 {
                current = open.lowerBound..<(index + 1)
            } else {
                if let open = current { out.append(open) }
                current = index..<(index + 1)
            }
        }
        if let current { out.append(current) }
        return out.map { max(0, $0.lowerBound - 3)..<min(sorted.count, $0.upperBound + 3) }
    }

    private static func cardio(_ window: [MinuteSample], resting: Double, profile: MetricsProfile) -> [Range<Date>] {
        var seconds: [(time: Int, rate: Double)] = []
        for minute in window {
            let base = Int(minute.start.timeIntervalSince1970)
            for (second, rate) in minute.heartRate.enumerated() where rate > 0 { seconds.append((base + second, Double(rate))) }
        }
        let floor = OpenStrapAutoDetect.floor(resting: resting, maximum: profile.maxHeartRate)
        let bouts = OpenStrapAutoDetect.detect(seconds: seconds, floor: floor) { low, high in
            let inside = window.filter { Int($0.start.timeIntervalSince1970) + 59 >= low && Int($0.start.timeIntervalSince1970) <= high }
            return inside.isEmpty ? nil : inside.reduce(0) { $0 + $1.movement } / Double(inside.count)
        }
        return bouts.map { bout in
            let start = Date(timeIntervalSince1970: Double(bout.start / 60 * 60))
            return start..<Date(timeIntervalSince1970: Double(bout.end / 60 * 60 + 60))
        }
    }

    /// Groups minutes that pass `test`, allowing short pauses, into stretches of at least `shortest` minutes.
    private static func stretches(_ window: [MinuteSample], pause: Int, shortest: Int, longest: Int,
                                  excluding taken: [Range<Date>], test: (MinuteSample) -> Bool) -> [Range<Date>] {
        var out: [Range<Date>] = []
        var start: Date?, last: Date?
        func close() {
            if let start, let last {
                let end = last.addingTimeInterval(60)
                let length = Int(end.timeIntervalSince(start) / 60)
                if length >= shortest, length <= longest, !taken.contains(where: { $0.lowerBound < end && start < $0.upperBound }) {
                    out.append(start..<end)
                }
            }
            start = nil
            last = nil
        }
        for minute in window {
            if let previous = last, minute.start.timeIntervalSince(previous) > Double(pause + 1) * 60 { close() }
            if test(minute) {
                if start == nil { start = minute.start }
                last = minute.start
            }
        }
        close()
        return out
    }

    private static func strength(_ window: [MinuteSample], resting: Double, profile: MetricsProfile,
                                 excluding taken: [Range<Date>]) -> [Range<Date>] {
        let reserve = max(1, profile.maxHeartRate - resting)
        let found = stretches(window, pause: strengthPauseMinutes, shortest: strengthMinutes, longest: strengthLongestMinutes,
                              excluding: taken) { minute in
            guard let average = minute.averageHeartRate else { return false }
            return average >= resting + strengthAverageReserve * reserve
                || Double(minute.heartRate.max() ?? 0) >= resting + strengthPeakReserve * reserve
        }
        return found.filter { range in
            let inside = window.filter { range.contains($0.start) }
            return !inside.isEmpty && inside.reduce(0) { $0 + $1.movement } / Double(inside.count) >= strengthMovement
                && swings(inside) >= strengthSwings
        }
    }

    /// How many times the heart rate climbed and then fell back, from 30-second averages.
    static func swings(_ minutes: [MinuteSample]) -> Int {
        var count = 0
        var low = Double.infinity, high = -Double.infinity
        var climbing = false
        for minute in minutes {
            for half in stride(from: 0, to: minute.heartRate.count, by: 30) {
                let rates = minute.heartRate[half..<min(half + 30, minute.heartRate.count)].filter { $0 > 0 }
                guard !rates.isEmpty else { continue }
                let rate = Double(rates.reduce(0) { $0 + Int($1) }) / Double(rates.count)
                if climbing {
                    high = max(high, rate)
                    if rate <= high - strengthSwingBeats {
                        count += 1
                        climbing = false
                        low = rate
                    }
                } else {
                    low = min(low, rate)
                    if rate >= low + strengthSwingBeats {
                        climbing = true
                        high = rate
                    }
                }
            }
        }
        return count
    }

    private static func walks(_ window: [MinuteSample], resting: Double, profile: MetricsProfile,
                              excluding taken: [Range<Date>]) -> [Range<Date>] {
        let reserve = max(1, profile.maxHeartRate - resting)
        return stretches(window, pause: walkPauseMinutes, shortest: walkMinutes, longest: strengthLongestMinutes, excluding: taken) { minute in
            guard let average = minute.averageHeartRate else { return false }
            return minute.movement >= walkMovement && average >= resting + walkReserve * reserve
        }
    }

    private static func features(_ minutes: [MinuteSample], workout: Workout, resting: Double,
                                 profile: MetricsProfile) -> NoopWorkoutType.Features {
        let rates = minutes.flatMap { $0.heartRate.filter { $0 > 0 }.map(Double.init) }
        let mean = rates.isEmpty ? 0 : Stats.mean(rates)
        let reserve = max(1, profile.maxHeartRate - resting)
        let motion = minutes.flatMap { minute -> [Double] in
            if let angle = minute.wristAngle, WristAngle.movement(angle) != nil {
                return angle.filter { $0 != WristAngle.noReading }.map { Double($0) / 10 * .pi / 180 }
            }
            let steady = minute.averageActivity - minute.movement
            return minute.activity.map { max(0, Double($0) - steady) / MinuteBuilder.activityScale }
        }
        let motionMean = motion.isEmpty ? 0 : Stats.mean(motion)
        let variance = motion.isEmpty ? 0 : motion.reduce(0) { $0 + ($1 - motionMean) * ($1 - motionMean) } / Double(motion.count)
        let length = workout.end.timeIntervalSince(workout.start) / 60
        return NoopWorkoutType.Features(meanReservePercent: 100 * (mean - resting) / reserve,
                                        heartRateVariation: rates.count > 1 && mean > 0 ? Stats.sampleSD(rates) / mean : 0,
                                        motionVariance: variance,
                                        kcalPerMinute: workout.calories > 0 && length > 0 ? Double(workout.calories) / length : nil)
    }

    private static func build(_ minutes: [MinuteSample], start: Date, end: Date, kind: WorkoutKind, profile: MetricsProfile,
                              body: DailyCalories.Body?, resting: Double, restingKnown: Bool, id: UUID) -> Workout {
        let rates = minutes.flatMap { $0.heartRate.filter { $0 > 0 } }
        let average = rates.isEmpty ? 0 : Double(rates.reduce(0) { $0 + Int($1) }) / Double(rates.count)
        let zones = OpenStrapZones.zones(restingHistory: restingKnown ? [resting] : [], maxHeartRate: profile.maxHeartRate)
        let trimp = Strain.trimp(minutes.map(\.averageHeartRate), resting: resting, maximum: profile.maxHeartRate, sex: profile.sex)
        let calories = body.flatMap { OpenStrapCalories.boutActive(minutes: minutes, body: $0, maxHeartRate: profile.maxHeartRate,
                                                                   restingHeartRate: resting) } ?? 0
        return Workout(id: id, kind: kind, start: start, end: end, averageHeartRate: Int(average.rounded()),
                       maxHeartRate: Int(rates.max() ?? 0), strain: Strain.fromTRIMP(trimp),
                       zoneSeconds: OpenStrapZones.secondsInZones(minutes, zones: zones), calories: Int(calories.rounded()),
                       source: .manual)
    }

    /// A workout the user adds by hand or records live. The user gives type and time, and every number is
    /// computed from the band data in that window. With no data there, the numbers are zero.
    public static func manual(id: UUID = UUID(), kind: WorkoutKind, start: Date, end: Date, minutes: [MinuteSample],
                              profile: MetricsProfile = MetricsProfile(), body: DailyCalories.Body? = nil,
                              restingHeartRate: Double?) -> Workout {
        let window = minutes.filter { $0.start >= start && $0.start < end }
        var workout = build(window, start: start, end: end, kind: kind, profile: profile, body: body,
                            resting: restingHeartRate ?? 60, restingKnown: restingHeartRate != nil, id: id)
        // Entered on top of simulated data = still simulated (never sent to Apple Health or Strava).
        if !window.isEmpty, window.allSatisfy({ $0.source == .simulated }) { workout.source = .simulated }
        return workout
    }

    /// The same workout must get the same ID every time detection runs (after each sync), otherwise
    /// its Apple Health / Strava export marks would be lost. So the ID is derived from the start minute.
    public static func stableID(start: Date) -> UUID {
        var minute = UInt64(max(0, start.timeIntervalSince1970 / 60)).bigEndian
        var bytes: [UInt8] = [0x50, 0x55, 0x4C, 0x53, 0x45, 0x00, 0x40, 0x00]      // "PULSE", version nibble 4
        bytes.append(contentsOf: withUnsafeBytes(of: &minute) { Array($0) })
        bytes[8] = (bytes[8] & 0x3F) | 0x80                                        // RFC 4122 variant bits
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
