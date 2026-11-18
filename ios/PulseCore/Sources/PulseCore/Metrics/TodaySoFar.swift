import Foundation

/// Today's numbers while the day is still going: what the home screen shows before the first
/// recovery exists. Same formulas as the daily summary (MetricsEngine), on today's minutes so far.
public struct TodaySoFar: Sendable, Equatable {
    /// Minutes the band was worn and measured a heart rate.
    public var wornMinutes: Int
    public var averageHeartRate: Double?
    /// Lowest 10-minute average so far (the same rule as resting HR from a night, but awake).
    public var restingHeartRate: Double?
    /// 0-21, from every minute so far.
    public var strain: Double

    public var hoursOfData: Double { Double(wornMinutes) / 60 }

    /// - Parameter minutes: today's raw minutes (local midnight to now), any order.
    /// - Returns: nil when the band recorded nothing worn today.
    public static func compute(minutes: [MinuteSample], profile: MetricsProfile = MetricsProfile()) -> TodaySoFar? {
        let worn = minutes.filter(\.isWorn)
        guard !worn.isEmpty, let tl = MetricsEngine.timeline(minutes) else { return nil }
        let averages = worn.compactMap(\.averageHeartRate)
        let resting = RestingHeartRate.lowestSustained(tl.hr)
        let strain = Strain.fromTRIMP(Strain.trimp(tl.hr, resting: resting ?? 60,
                                                   maximum: profile.maxHeartRate, sex: profile.sex))
        return TodaySoFar(wornMinutes: worn.count,
                          averageHeartRate: averages.isEmpty ? nil : Stats.mean(averages),
                          restingHeartRate: resting, strain: strain)
    }
}
