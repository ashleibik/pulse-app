import Foundation

/// Decides WHAT goes to Apple Health. The app's HealthKit code only carries it out, so the rules
/// below are tested on Windows (HealthExportTests).
///
/// Rules:
/// 1. Simulated data is never exported, and neither is anything from before the data cutoff (the
///    band was bought used: older records belong to the previous owner).
/// 2. Written: sleep, heart rate, resting heart rate, HRV (SDNN, calculated from the real beats) and
///    workouts. NEVER written: steps and active energy (the owner's Apple Watch owns those) and
///    Pulse's calorie estimates.
/// 3. Sleep is written as asleep + awake. Stage estimates stay inside Pulse until they have been
///    validated. Only the setting "Write sleep stages to Apple Health (estimated)" (off by default)
///    writes "light" as Core and "restful" as Deep. REM is never written: Pulse cannot tell it apart.
/// 4. No duplicates: every sample carries a stable sync identifier, unchanged items are skipped
///    (`HealthLedger`), and what another install of Pulse or the Apple Watch already wrote is left
///    alone.
public enum HealthExport {

    public enum SleepKind: String, Sendable, Equatable {
        case inBed, awake
        /// Pulse's "light". Only with the stages setting on.
        case core
        /// Pulse's "restful". Only with the stages setting on.
        case deep
        /// Asleep, no stage claimed.
        case asleep
    }

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

    /// One minute of heart rate: the average of the seconds the band really measured.
    public struct HeartRatePoint: Sendable, Equatable {
        public let start: Date
        public let end: Date
        public let bpm: Int
        /// Seconds with a reading. A minute can grow when a later batch brings its other seconds,
        /// so this is also the sample's sync version: more readings replace fewer.
        public let readings: Int
        public var syncID: String { "pulse.hr.\(Int(start.timeIntervalSince1970))" }
    }

    /// One night's HRV.
    public struct HRVPoint: Sendable, Equatable {
        public let start: Date
        public let end: Date
        public let sdnnMs: Double
        public var syncID: String { "pulse.hrv.\(Int(start.timeIntervalSince1970))" }
    }

    public static func isExportable(_ source: DataSource) -> Bool { source != .simulated }

    /// - Parameters:
    ///   - since: only items that end at or after this moment (`nil` = everything).
    ///   - dataStart: the data cutoff. Band data from before it is never exported. Workouts added
    ///     by hand are the user's own, so they are kept.
    public static func plan(sleeps: [SleepSession], workouts: [Workout], days: [DailySummary],
                            since: Date? = nil, dataStart: Date? = nil) -> Plan {
        let cutoff = since ?? .distantPast
        let first = dataStart ?? .distantPast
        return Plan(
            sleeps: sleeps.filter { isExportable($0.source) && $0.end >= cutoff && $0.start >= first }
                .sorted { $0.start < $1.start },
            workouts: workouts.filter {
                $0.isSuggestion != true && isExportable($0.source) && $0.end >= cutoff
                    && ($0.source == .manual || $0.start >= first)
            }.sorted { $0.start < $1.start },
            restingDays: days.filter {
                isExportable($0.source) && $0.restingHeartRate != nil
                    && $0.date >= cutoff.addingTimeInterval(-86_400) && $0.date >= first
            }.sorted { $0.date < $1.date })
    }

    /// One night as Apple Health intervals: one "in bed" interval for the whole session, plus
    /// asleep / awake inside it. Minutes with no band data get neither. Without a timeline (raw minutes
    /// missing), the whole session counts as asleep, because that is the only thing known.
    /// - Parameter writeStages: the user's setting. Off: light and restful are both plain "asleep".
    public static func sleepIntervals(for session: SleepSession, segments: [SleepSegment],
                                      writeStages: Bool = false) -> [SleepInterval] {
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
        var runKind = kind(inside[0].phase, writeStages: writeStages)
        for segment in inside.dropFirst() {
            let next = kind(segment.phase, writeStages: writeStages)
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

    private static func kind(_ phase: SleepPhase, writeStages: Bool) -> SleepKind {
        switch phase {
        case .awake: .awake
        case .light: writeStages ? .core : .asleep
        case .restful: writeStages ? .deep : .asleep
        }
    }

    /// Worn minutes as heart-rate samples. Minutes without a believable reading are left out.
    public static func heartRatePoints(minutes: [MinuteSample], dataStart: Date? = nil) -> [HeartRatePoint] {
        let first = dataStart ?? .distantPast
        return minutes
            .filter { isExportable($0.source) && $0.start >= first }
            .sorted { $0.start < $1.start }
            .compactMap { minute in
                guard let average = minute.averageHeartRate, (25...250).contains(average) else { return nil }
                return HeartRatePoint(start: minute.start, end: minute.start.addingTimeInterval(60),
                                      bpm: Int(average.rounded()),
                                      readings: minute.heartRate.filter { $0 > 0 }.count)
            }
    }

    /// The night's HRV as SDNN, from the beats the band recorded while asleep. nil for naps,
    /// simulated data, and nights without enough real beats (nothing is estimated to fill the gap).
    public static func nightlySDNN(for session: SleepSession, minutes: [MinuteSample],
                                   segments: [SleepSegment]) -> HRVPoint? {
        guard !session.isNap, isExportable(session.source) else { return nil }
        let count = Int(session.end.timeIntervalSince(session.start) / 60)
        guard count > 0 else { return nil }
        var rr = [[Double]](repeating: [], count: count)
        var asleep = [Bool](repeating: false, count: count)
        for minute in minutes {
            let index = Int(minute.start.timeIntervalSince(session.start) / 60)
            guard minute.start >= session.start, index < count, minute.isWorn else { continue }
            rr[index] = minute.rrIntervalsMs.map(Double.init)
            asleep[index] = segments.contains {
                $0.phase != .awake && $0.start <= minute.start && minute.start < $0.end
            }
        }
        return HRV.overnightSDNN(minuteRR: rr, asleep: asleep).map {
            HRVPoint(start: session.start, end: session.end, sdnnMs: $0)
        }
    }

    /// True when another app's workout covers at least half of the shorter of the two, so the
    /// Apple Watch's recording of the same session is not doubled by the band's.
    public static func isAlreadyRecorded(_ workout: Workout, by others: [DateInterval]) -> Bool {
        others.contains { other in
            let overlap = min(workout.end, other.end).timeIntervalSince(max(workout.start, other.start))
            let shorter = min(workout.end.timeIntervalSince(workout.start), other.duration)
            return overlap > 0 && shorter > 0 && overlap >= shorter / 2
        }
    }

    // MARK: - Stable identifiers

    public static func sleepID(_ session: SleepSession) -> String {
        "pulse.sleep.\(Int(session.start.timeIntervalSince1970))"
    }

    public static func restingID(_ day: DailySummary) -> String {
        "pulse.rhr.\(Int(day.date.timeIntervalSince1970))"
    }

    public static func workoutID(_ workout: Workout) -> String { "pulse.workout.\(workout.id.uuidString)" }

    public static func fingerprint(_ intervals: [SleepInterval]) -> String {
        fingerprint(intervals.map {
            "\(Int($0.start.timeIntervalSince1970))-\(Int($0.end.timeIntervalSince1970))-\($0.kind.rawValue)"
        }.joined(separator: "|"))
    }

    public static func fingerprint(_ workout: Workout) -> String {
        fingerprint("\(workout.kind.rawValue)-\(Int(workout.start.timeIntervalSince1970))-\(Int(workout.end.timeIntervalSince1970))")
    }

    /// FNV-1a: short, and stable between launches (Swift's own `hashValue` is not).
    public static func fingerprint(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}

/// What has already been written to Apple Health, so a sync every few minutes costs almost nothing
/// and an unchanged night is not deleted and written again.
public struct HealthLedger: Codable, Sendable, Equatable {
    /// Heart-rate minutes are sent again from this far before the newest exported one, because a
    /// batch can end in the middle of a minute.
    public static let heartRateOverlap: TimeInterval = 15 * 60
    /// Recent items are checked again on every export: a late sync can still change them.
    public static let recheckWindow: TimeInterval = 3 * 86_400

    private struct Entry: Codable, Sendable, Equatable {
        var fingerprint: String
        var writtenAt: Date
    }

    private var entries: [String: Entry] = [:]
    /// The newest heart-rate minute that reached Apple Health. nil = nothing exported yet.
    public var exportedThrough: Date?

    public init() {}

    public func needsWrite(_ id: String, fingerprint: String) -> Bool {
        entries[id]?.fingerprint != fingerprint
    }

    public mutating func record(_ id: String, fingerprint: String, at date: Date) {
        entries[id] = Entry(fingerprint: fingerprint, writtenAt: date)
    }

    /// Makes the next export write these items again (the user changed a sleep).
    public mutating func forget(prefix: String) {
        entries = entries.filter { !$0.key.hasPrefix(prefix) }
    }

    /// Items older than the re-check window never come up again, so their entries can go.
    public mutating func prune(now: Date) {
        let oldest = now.addingTimeInterval(-10 * Self.recheckWindow)
        entries = entries.filter { $0.value.writtenAt >= oldest }
    }

    /// Items ending before this are not looked at. nil = look at everything.
    public var recheckFrom: Date? { exportedThrough?.addingTimeInterval(-Self.recheckWindow) }
    /// Heart-rate minutes starting before this are already in Apple Health. nil = send them all.
    public var heartRateFrom: Date? { exportedThrough?.addingTimeInterval(-Self.heartRateOverlap) }
}
