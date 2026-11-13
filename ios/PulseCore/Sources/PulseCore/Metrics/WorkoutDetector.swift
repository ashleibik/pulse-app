import Foundation

/// Finds workouts in raw band data, so nobody has to press "start".
///
/// OUR OWN heuristic (not WHOOP's, which is proprietary). The idea is the standard sports-science
/// definition of "moderate or harder" exercise: heart rate at 40% or more of your heart-rate
/// reserve (ACSM guidelines call 40-59% HRR "moderate").
///
///   heart-rate reserve % = (HR - resting) / (max - resting)
///   active minute  = average HR at or above 40% HRR
///   workout        = at least 10 active minutes, where pauses of up to 3 minutes don't end it
///
/// Limits, stated honestly:
/// - It can't tell a run from a ride (no GPS, and wrist motion alone is unreliable), so every
///   detected workout has kind `.other` ("Workout") until the user renames it.
/// - Stress or a hot shower can raise the heart rate too. The 10-minute minimum filters most of that.
/// - Calories are a rough estimate from heart rate only (no weight, no power).
public enum WorkoutDetector {
    public static let intensityThreshold = 0.40     // fraction of heart-rate reserve
    public static let minimumMinutes = 10
    public static let maximumPauseMinutes = 3

    /// - Parameters:
    ///   - minutes: raw minutes, any order.
    ///   - restingHeartRate: gives the resting HR for the day a minute belongs to (the daily
    ///     summaries have it). Return `nil` when unknown; 60 bpm is used then.
    public static func detect(minutes: [MinuteSample], profile: MetricsProfile = MetricsProfile(),
                              restingHeartRate: (Date) -> Double?) -> [Workout] {
        let sorted = minutes.sorted { $0.start < $1.start }
        var workouts: [Workout] = []
        var current: [MinuteSample] = []      // minutes of the workout being built (pauses included)
        var lastActive: Date?

        func close() {
            // Drop the trailing pause minutes, then keep it only if it is long enough.
            while let last = current.last, let end = lastActive, last.start > end { current.removeLast() }
            if let workout = build(current, profile: profile, restingHeartRate: restingHeartRate) {
                workouts.append(workout)
            }
            current = []
            lastActive = nil
        }

        for minute in sorted {
            let rest = restingHeartRate(minute.start) ?? 60
            let reserve = max(1, profile.maxHeartRate - rest)
            let active = minute.averageHeartRate.map { ($0 - rest) / reserve >= intensityThreshold } ?? false

            if let last = lastActive {
                let gap = minute.start.timeIntervalSince(last) / 60
                if gap > Double(maximumPauseMinutes) + 1 { close() }
            }
            if active {
                current.append(minute)
                lastActive = minute.start
            } else if lastActive != nil {
                current.append(minute)        // a pause inside a workout (kept if activity resumes)
            }
        }
        close()
        return workouts
    }

    private static func build(_ minutes: [MinuteSample], profile: MetricsProfile,
                              restingHeartRate: (Date) -> Double?) -> Workout? {
        guard let first = minutes.first, let last = minutes.last else { return nil }
        let rest = restingHeartRate(first.start) ?? 60
        let reserve = max(1, profile.maxHeartRate - rest)
        let averages = minutes.compactMap(\.averageHeartRate)
        let activeCount = averages.filter { ($0 - rest) / reserve >= intensityThreshold }.count
        guard activeCount >= minimumMinutes, !averages.isEmpty else { return nil }

        let start = first.start
        let end = last.start.addingTimeInterval(60)
        let peak = minutes.flatMap(\.heartRate).max() ?? 0
        let zones = HeartRateZones.minutesPerZone(minutes.map(\.averageHeartRate), maxHeartRate: profile.maxHeartRate)
        let trimp = Strain.trimp(minutes.map(\.averageHeartRate), resting: rest,
                                 maximum: profile.maxHeartRate, sex: profile.sex)
        // Rough energy estimate: 12 kcal per minute at 100% of heart-rate reserve, scaled down linearly.
        let calories = averages.reduce(0.0) { $0 + max(0, ($1 - rest) / reserve) * 12 }

        return Workout(id: stableID(start: start), kind: .other, start: start, end: end,
                       averageHeartRate: Int((averages.reduce(0, +) / Double(averages.count)).rounded()),
                       maxHeartRate: Int(peak), strain: Strain.fromTRIMP(trimp),
                       zoneSeconds: zones.map { $0 * 60 }, calories: Int(calories.rounded()), source: .history)
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
