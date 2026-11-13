import Foundation

/// Decides WHAT goes to Apple Health. The app's HealthKit code only carries it out, so the rules
/// below are tested on Windows (HealthExportTests).
///
/// Rules:
/// 1. Simulated data is never exported. Apple Health is the user's real medical record; writing
///    a made-up month into it would be hard to undo.
/// 2. Only what Pulse actually measures is written: sleep (asleep / awake, no stages), resting
///    heart rate, and workouts. NOT written: HRV (Apple Health only has the SDNN kind, Pulse
///    calculates RMSSD, and they are different numbers) and calories (a rough guess).
/// 3. Recent days are written again on every export, because a late sync can still change them.
public enum HealthExport {

    public enum SleepKind: String, Sendable, Equatable { case inBed, asleep, awake }

    public struct SleepInterval: Sendable, Equatable {
        public let start: Date
        public let end: Date
        public let kind: SleepKind
    }

    public struct Plan: Sendable, Equatable {
        public var sleeps: [SleepSession]
        public var workouts: [Workout]
        /// Days that have a resting heart rate to write.
        public var restingDays: [DailySummary]

        public var isEmpty: Bool { sleeps.isEmpty && workouts.isEmpty && restingDays.isEmpty }
    }

    public static func isExportable(_ source: DataSource) -> Bool { source != .simulated }

    /// - Parameter since: only items that end at or after this moment (`nil` = everything).
    public static func plan(sleeps: [SleepSession], workouts: [Workout], days: [DailySummary],
                            since: Date? = nil) -> Plan {
        let cutoff = since ?? .distantPast
        return Plan(
            sleeps: sleeps.filter { isExportable($0.source) && $0.end >= cutoff }.sorted { $0.start < $1.start },
            workouts: workouts.filter { isExportable($0.source) && $0.end >= cutoff }.sorted { $0.start < $1.start },
            restingDays: days.filter { isExportable($0.source) && $0.restingHeartRate != nil && $0.date >= cutoff.addingTimeInterval(-86_400) }
                .sorted { $0.date < $1.date })
    }

    /// One night as Apple Health intervals: one "in bed" interval for the whole session, plus
    /// "asleep" / "awake" intervals inside it. Pulse's "restful" and "light" both become plain
    /// "asleep", because Pulse does not claim to know sleep stages.
    /// Without a timeline (raw minutes missing), the whole session counts as asleep.
    public static func sleepIntervals(for session: SleepSession, segments: [SleepSegment]) -> [SleepInterval] {
        var out = [SleepInterval(start: session.start, end: session.end, kind: .inBed)]
        let inside = segments
            .filter { $0.end > session.start && $0.start < session.end }
            .sorted { $0.start < $1.start }
        guard !inside.isEmpty else {
            out.append(SleepInterval(start: session.start, end: session.end, kind: .asleep))
            return out
        }
        var runStart = max(inside[0].start, session.start)
        var runEnd = min(inside[0].end, session.end)
        var runKind = kind(inside[0].phase)
        for segment in inside.dropFirst() {
            let next = kind(segment.phase)
            if next == runKind && segment.start <= runEnd {
                runEnd = min(segment.end, session.end)          // same kind, touching: one longer interval
            } else {
                out.append(SleepInterval(start: runStart, end: runEnd, kind: runKind))
                runStart = max(segment.start, session.start)
                runEnd = min(segment.end, session.end)
                runKind = next
            }
        }
        out.append(SleepInterval(start: runStart, end: runEnd, kind: runKind))
        return out
    }

    private static func kind(_ phase: SleepPhase) -> SleepKind {
        phase == .awake ? .awake : .asleep
    }
}
