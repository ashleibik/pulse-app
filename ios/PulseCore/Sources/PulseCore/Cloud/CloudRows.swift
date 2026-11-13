import Foundation

/// The rows Pulse uploads to its own Supabase database (Phase 8), so Claude can read them
/// through the MCP server.
///
/// Data minimization (docs/PHASE0_PLAN.md §2C): only summaries leave the phone. Raw heartbeats
/// and per-minute data are never uploaded. Anything not in these three structs stays local.
///
/// Every row carries `source`, so the server can tell Claude when numbers are simulated instead
/// of presenting demo data as real.
///
/// Column names match supabase/migrations (snake_case). `user_id` is NOT sent by the app: the
/// database fills it in from the signed-in user, so one user can never write another's rows.
public enum CloudRows {

    public struct Day: Codable, Sendable, Equatable {
        public let day: String                  // "2026-11-13", the user's local calendar day
        public let recovery_pct: Double?
        public let recovery_word: String?       // Ready / Steady / Rest
        public let day_strain: Double
        public let sleep_minutes: Int?
        public let sleep_need_minutes: Int
        public let resting_hr: Double?
        public let hrv_rmssd: Double?
        public let baseline_resting_hr: Double?
        public let baseline_hrv: Double?
        public let explanation: String
        public let source: String
        public let algorithm_version: Int
    }

    public struct Sleep: Codable, Sendable, Equatable {
        public let id: String
        public let start_at: String             // ISO 8601, UTC
        public let end_at: String
        public let asleep_minutes: Int
        public let awake_minutes: Int
        public let disturbances: Int
        public let is_nap: Bool
        public let source: String
    }

    public struct WorkoutRow: Codable, Sendable, Equatable {
        public let id: String
        public let start_at: String
        public let end_at: String
        public let kind: String
        public let avg_hr: Int
        public let max_hr: Int
        public let strain: Double
        public let zone_seconds: [Int]
        public let source: String
    }

    public static func day(_ summary: DailySummary, calendar: Calendar) -> Day {
        let c = calendar.dateComponents([.year, .month, .day], from: summary.date)
        return Day(day: String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0),
                   recovery_pct: summary.recoveryScore.map(round1),
                   recovery_word: summary.recoveryScore.map { RecoveryZone(score: $0).word },
                   day_strain: round1(summary.strain),
                   sleep_minutes: summary.sleepMinutes,
                   sleep_need_minutes: summary.sleepNeedMinutes,
                   resting_hr: summary.restingHeartRate.map(round1),
                   hrv_rmssd: summary.hrvRMSSD.map(round1),
                   baseline_resting_hr: summary.baselineRestingHeartRate.map(round1),
                   baseline_hrv: summary.baselineHRV.map(round1),
                   explanation: summary.explanation,
                   source: summary.source.rawValue,
                   algorithm_version: MetricsEngine.algorithmVersion)
    }

    public static func sleep(_ session: SleepSession) -> Sleep {
        // The engine gives a night a new random id every time it recalculates, so the row id is
        // built from the wake-up minute instead. Re-uploading then replaces the row, not duplicates it.
        Sleep(id: WorkoutDetector.stableID(start: session.end).uuidString.lowercased(),
              start_at: StravaExport.iso(session.start), end_at: StravaExport.iso(session.end),
              asleep_minutes: session.asleepMinutes, awake_minutes: session.awakeMinutes,
              disturbances: session.disturbances, is_nap: session.isNap, source: session.source.rawValue)
    }

    public static func workout(_ workout: Workout) -> WorkoutRow {
        WorkoutRow(id: workout.id.uuidString.lowercased(),
                   start_at: StravaExport.iso(workout.start), end_at: StravaExport.iso(workout.end),
                   kind: workout.kind.rawValue, avg_hr: workout.averageHeartRate, max_hr: workout.maxHeartRate,
                   strain: round1(workout.strain), zone_seconds: workout.zoneSeconds, source: workout.source.rawValue)
    }

    /// One decimal is plenty for a summary, and avoids uploading noise like 54.38291.
    static func round1(_ value: Double) -> Double { (value * 10).rounded() / 10 }
}
