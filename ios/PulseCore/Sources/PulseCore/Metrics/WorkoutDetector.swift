import Foundation

/// Finds workouts by itself and records them, so nobody has to press "start" or confirm anything. Spec: docs/METRICS.md §10.
///
/// - **From heart rate and movement:** NOOP's exercise detector (`NoopWorkoutDetector`). Its type comes from the band's step
///   count when the band counted most of it, else from NOOP's classifier.
/// - **From steps:** 10 minutes or more of walking or running on the band's 100 Hz count (`Steps`), where no heart-rate workout is.
public enum WorkoutDetector {
    /// NOOP's shortest workout.
    public static let minimumMinutes = 5
    /// Shorter than this is a mis-tap, not a workout.
    public static let minimumSavedSeconds = 60.0
    /// A walk or run found from steps lasts at least this long ...
    public static let stepWorkoutMinutes = 10
    /// ... with pauses of up to this many minutes.
    public static let stepPauseMinutes = 2

    /// True when a workout this long should not be saved.
    public static func isTooShort(start: Date, end: Date) -> Bool {
        end.timeIntervalSince(start) < minimumSavedSeconds
    }

    /// - Parameters:
    ///   - minutes: raw minutes, any order.
    ///   - steps: the band's counted minutes (§15), any order. Without them only heart-rate workouts are found.
    ///   - body: for calories. Without it a workout has 0 calories, which the app shows as `--`.
    ///   - restingHeartRate: the resting heart rate of the day a minute belongs to. nil = unknown (NOOP's 10th percentile).
    public static func detect(minutes: [MinuteSample], steps: [StepMinute] = [], profile: MetricsProfile = MetricsProfile(),
                              body: DailyCalories.Body? = nil, restingHeartRate: (Date) -> Double?) -> [Workout] {
        let sorted = minutes.filter(\.isWorn).sorted { $0.start < $1.start }
        let counted = steps.filter { $0.seconds > 0 }.sorted { $0.start < $1.start }
        var found: [Workout] = []
        var taken: [Range<Date>] = []

        func add(_ range: Range<Date>, kind fixed: WorkoutKind?) {
            let inside = Array(sorted[slice(sorted, range, \.start)])
            guard !inside.isEmpty else { return }
            let resting = restingHeartRate(range.lowerBound)
            var workout = build(inside, start: range.lowerBound, end: range.upperBound, kind: fixed ?? .other, profile: profile,
                                body: body, resting: resting ?? 60, restingKnown: resting != nil,
                                id: stableID(start: range.lowerBound))
            let stepsInside = Array(counted[slice(counted, range, \.start)])
            if fixed == nil {
                let length = Int((range.upperBound.timeIntervalSince(range.lowerBound) / 60).rounded())
                workout.kind = Self.kind(cadenceOf: stepsInside, minutes: length)
                    ?? NoopWorkoutType.classify(features(inside, workout: workout, resting: resting ?? 60, profile: profile))
            }
            if let body, !stepsInside.isEmpty {
                let walking = stepsInside.reduce(0.0) { $0 + DailyCalories.walkingKcal($1, body: body) }
                workout.calories = max(workout.calories, Int(walking.rounded()))
            }
            workout.source = inside.allSatisfy { $0.source == .simulated } ? .simulated : .history
            found.append(workout)
            taken.append(range)
        }

        for bout in heartRateBouts(sorted, profile: profile, restingHeartRate: restingHeartRate) {
            let start = Date(timeIntervalSince1970: Double(bout.start / 60 * 60))
            let end = Date(timeIntervalSince1970: Double(bout.end / 60 * 60 + 60))
            add(start..<end, kind: nil)
        }
        for (range, kind) in stepWorkouts(counted)
        where !taken.contains(where: { $0.lowerBound < range.upperBound && range.lowerBound < $0.upperBound }) {
            add(range, kind: kind)
        }
        return found.sorted { $0.start < $1.start }
    }

    /// Kept minutes further apart than this can't end up in one workout: NOOP joins active seconds at most 150 s apart, and
    /// runs at most 300 s apart.
    static let separateAfterMinutes = 7

    /// NOOP's detector over the minutes with strong movement, plus one minute either side for its 10-second average. A quiet
    /// minute can't make a second active, so leaving the rest out changes nothing. Each stretch of kept minutes is run on its
    /// own (`separateAfterMinutes`), so a long history never sits in memory second by second.
    static func heartRateBouts(_ sorted: [MinuteSample], profile: MetricsProfile,
                               restingHeartRate: (Date) -> Double?) -> [NoopWorkoutDetector.Bout] {
        let strong = NoopWorkoutDetector.motionThreshold * MinuteBuilder.activityScale
        let starts = sorted.map { Int($0.start.timeIntervalSince1970.rounded()) }
        var kept = [Bool](repeating: false, count: sorted.count)
        for index in sorted.indices where sorted[index].activity.contains(where: { Double($0) > strong }) {
            kept[index] = true
            if index > 0, starts[index] - starts[index - 1] <= 60 { kept[index - 1] = true }
            if index + 1 < sorted.count, starts[index + 1] - starts[index] <= 60 { kept[index + 1] = true }
        }
        // A day without a resting heart rate uses NOOP's 10th percentile, here of the minutes' averages (worked out only if needed).
        var fallback: Double?
        var bouts: [NoopWorkoutDetector.Bout] = []

        func detect(from first: Int, through last: Int) {
            var motion: [NoopWorkoutDetector.MotionPoint] = []
            motion.reserveCapacity((first...last).filter { kept[$0] }.count * 60)
            for index in first...last where kept[index] {
                for (second, value) in sorted[index].activity.enumerated() {
                    motion.append(NoopWorkoutDetector.MotionPoint(ts: starts[index] + second,
                                                                  intensity: Double(value) / MinuteBuilder.activityScale))
                }
            }
            // Which stored minute holds each clock minute of the stretch, with two minutes of margin either side.
            let base = starts[first] - 120
            var minuteAt = [Int](repeating: -1, count: (starts[last] - base) / 60 + 4)
            for index in max(0, first - 2)...min(sorted.count - 1, last + 2) {
                let slot = (starts[index] - base) / 60
                if starts[index] >= base, slot < minuteAt.count { minuteAt[slot] = index }
            }
            func heartRate(_ ts: Int) -> Double? {
                guard ts >= base else { return nil }
                let slot = (ts - base) / 60
                guard slot < minuteAt.count, minuteAt[slot] >= 0 else { return nil }
                let index = minuteAt[slot]
                let second = ts - starts[index]
                guard second >= 0, second < sorted[index].heartRate.count, sorted[index].heartRate[second] > 0 else { return nil }
                return Double(sorted[index].heartRate[second])
            }
            // The resting heart rate of each clock minute of the stretch, looked up once (nan = not yet).
            var restingAt = [Double](repeating: .nan, count: minuteAt.count)
            func resting(_ ts: Int) -> Double {
                let minute = ts - ((ts % 60) + 60) % 60
                let slot = (minute - base) / 60
                if minute >= base, slot < restingAt.count, !restingAt[slot].isNaN { return restingAt[slot] }
                let value = restingHeartRate(Date(timeIntervalSince1970: Double(minute))) ?? {
                    let derived = fallback ?? NoopWorkoutDetector.deriveRestingHR(sorted.compactMap(\.averageHeartRate))
                    fallback = derived
                    return derived
                }()
                if minute >= base, slot < restingAt.count { restingAt[slot] = value }
                return value
            }
            bouts += NoopWorkoutDetector.detect(motion: motion, heartRateAt: heartRate, restingHR: resting,
                                                maxHR: profile.maxHeartRate)
        }

        var stretchStart: Int?
        var lastKept = 0
        for index in sorted.indices where kept[index] {
            if let open = stretchStart, starts[index] - starts[lastKept] > separateAfterMinutes * 60 {
                detect(from: open, through: lastKept)
                stretchStart = nil
            }
            if stretchStart == nil { stretchStart = index }
            lastKept = index
        }
        if let open = stretchStart { detect(from: open, through: lastKept) }
        return bouts
    }

    /// Walks and runs on the band's step count: minutes of 60 steps or more, with pauses of up to `stepPauseMinutes`, lasting
    /// at least `stepWorkoutMinutes`. A run when their median is 140 a minute or more.
    static func stepWorkouts(_ counted: [StepMinute]) -> [(Range<Date>, WorkoutKind)] {
        let moving = counted.filter { $0.cadence >= Double(Steps.walkingStepsPerMinute) }
        var out: [(Range<Date>, WorkoutKind)] = []
        var group: [StepMinute] = []
        func close() {
            defer { group = [] }
            guard let first = group.first, let last = group.last else { return }
            let end = last.start.addingTimeInterval(60)
            guard end.timeIntervalSince(first.start) >= Double(stepWorkoutMinutes) * 60 else { return }
            let median = Stats.median(group.map(\.cadence))
            out.append((first.start..<end, median >= Double(Steps.runningStepsPerMinute) ? .run : .walk))
        }
        for minute in moving {
            if let last = group.last, minute.start.timeIntervalSince(last.start) > Double(stepPauseMinutes + 1) * 60 { close() }
            group.append(minute)
        }
        close()
        return out
    }

    /// The indices of the elements of a list sorted by `key` that fall in `range`.
    static func slice<T>(_ sorted: [T], _ range: Range<Date>, _ key: KeyPath<T, Date>) -> Range<Int> {
        func firstIndex(atOrAfter date: Date) -> Int {
            var low = 0, high = sorted.count
            while low < high {
                let mid = (low + high) / 2
                if sorted[mid][keyPath: key] < date { low = mid + 1 } else { high = mid }
            }
            return low
        }
        let lower = firstIndex(atOrAfter: range.lowerBound)
        return lower..<max(lower, firstIndex(atOrAfter: range.upperBound))
    }

    /// Walk or Run from the band's step count, when it counted at least half of the workout's minutes. nil = it can't tell.
    static func kind(cadenceOf steps: [StepMinute], minutes: Int) -> WorkoutKind? {
        let full = steps.filter { $0.seconds >= 30 }
        guard minutes > 0, full.count * 2 >= minutes else { return nil }
        let median = Stats.median(full.map(\.cadence))
        if median >= Double(Steps.runningStepsPerMinute) { return .run }
        if median >= Double(Steps.walkingStepsPerMinute) { return .walk }
        return nil
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
        // Entered on top of simulated data = still simulated (never sent to Strava).
        if !window.isEmpty, window.allSatisfy({ $0.source == .simulated }) { workout.source = .simulated }
        return workout
    }

    /// The same workout must get the same ID every time detection runs (after each sync), otherwise
    /// its Strava mark would be lost. So the ID is derived from the start minute.
    public static func stableID(start: Date) -> UUID {
        var minute = UInt64(max(0, start.timeIntervalSince1970 / 60)).bigEndian
        var bytes: [UInt8] = [0x50, 0x55, 0x4C, 0x53, 0x45, 0x00, 0x40, 0x00]      // "PULSE", version nibble 4
        bytes.append(contentsOf: withUnsafeBytes(of: &minute) { Array($0) })
        bytes[8] = (bytes[8] & 0x3F) | 0x80                                        // RFC 4122 variant bits
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
