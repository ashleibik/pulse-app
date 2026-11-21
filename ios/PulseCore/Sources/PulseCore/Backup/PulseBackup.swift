import Foundation

/// Settings > Export all data / Import data: one JSON file with everything needed to move Pulse to
/// a new install without losing anything.
///
/// The file is ordinary JSON, laid out one record per line, so a phone can write and read months of
/// raw minutes without holding the whole file in memory:
///
///     {
///     "header":{...},
///     "workouts":[...],
///     "journal":[...],
///     "days":[...],
///     "sleeps":[...],
///     "sleep_corrections":[...],
///     "wear_sensor":[...],
///     "step_references":[...],
///     "step_minutes":[[unix, steps, seconds],...],
///     "minutes":[
///     {...},
///     {...}
///     ],
///     "footer":{"minutes":2}
///     }
///
/// The footer's count proves the file was not cut short. Importing is a merge: it never removes
/// anything, and importing the same file twice changes nothing. Days and sleeps are in the file so
/// it is a complete record, but on import they are recalculated from the raw minutes.
public enum PulseBackup {
    /// 2 added `wear_sensor`, 3 added `step_references` and the step goal, 4 added `step_minutes` (the band's step count).
    /// Files of format 1 to 3 still read.
    public static let formatVersion = 4

    public struct Profile: Codable, Sendable, Equatable {
        public var birthYear: Int?
        public var maxHeartRateOverride: Int?
        public var sleepGoalMinutes: Int
        public var sex: BiologicalSex
        public var weightKg: Double?
        public var heightCm: Double?
        /// nil in files from before format 3.
        public var stepGoal: Int?
        public var waistCm: Double?

        public init(birthYear: Int?, maxHeartRateOverride: Int?, sleepGoalMinutes: Int, sex: BiologicalSex,
                    weightKg: Double? = nil, heightCm: Double? = nil, stepGoal: Int? = nil, waistCm: Double? = nil) {
            self.birthYear = birthYear
            self.maxHeartRateOverride = maxHeartRateOverride
            self.sleepGoalMinutes = sleepGoalMinutes
            self.sex = sex
            self.weightKg = weightKg
            self.heightCm = heightCm
            self.stepGoal = stepGoal
            self.waistCm = waistCm
        }
    }

    public struct Header: Codable, Sendable, Equatable {
        public var app = "Pulse"
        public var formatVersion = PulseBackup.formatVersion
        public var exportedAt: Date
        public var appVersion: String
        /// The data cutoff: band data from before this day is the previous owner's.
        public var dataStart: Date?
        public var profile: Profile?

        public init(exportedAt: Date, appVersion: String, dataStart: Date?, profile: Profile?) {
            self.exportedAt = exportedAt
            self.appVersion = appVersion
            self.dataStart = dataStart
            self.profile = profile
        }
    }

    public struct WorkoutEntry: Codable, Sendable, Equatable {
        public var workout: Workout
        public var healthKitID: UUID?
        public var stravaUploadedAt: Date?

        public init(workout: Workout, healthKitID: UUID? = nil, stravaUploadedAt: Date? = nil) {
            self.workout = workout
            self.healthKitID = healthKitID
            self.stravaUploadedAt = stravaUploadedAt
        }
    }

    public struct JournalDay: Codable, Sendable, Equatable {
        public var day: Date
        /// Raw habit names, so a habit added by a later version survives the trip.
        public var habits: [String]

        public init(day: Date, habits: [String]) {
            self.day = day
            self.habits = habits
        }
    }

    /// Everything in the file except the raw minutes.
    public struct Contents: Sendable, Equatable {
        public var header: Header
        public var workouts: [WorkoutEntry]
        public var journal: [JournalDay]
        public var days: [DailySummary]
        public var sleeps: [SleepSession]
        /// Sleeps the user edited or removed.
        public var sleepCorrections: [SleepCorrection]
        /// What the band said about how it sat on the wrist (docs/METRICS.md §13). For checking a night or a workout.
        public var wearSensor: [WearSensor.Observation]
        /// The owner's step tests (and Apple Watch days from earlier versions) (docs/METRICS.md §15).
        public var stepReferences: [Steps.Reference]
        /// The steps the band counted, minute by minute (docs/METRICS.md §15).
        public var stepMinutes: [StepMinute]

        public init(header: Header, workouts: [WorkoutEntry], journal: [JournalDay],
                    days: [DailySummary], sleeps: [SleepSession], sleepCorrections: [SleepCorrection] = [],
                    wearSensor: [WearSensor.Observation] = [], stepReferences: [Steps.Reference] = [],
                    stepMinutes: [StepMinute] = []) {
            self.header = header
            self.workouts = workouts
            self.journal = journal
            self.days = days
            self.sleeps = sleeps
            self.sleepCorrections = sleepCorrections
            self.wearSensor = wearSensor
            self.stepReferences = stepReferences
            self.stepMinutes = stepMinutes
        }
    }

    /// What the import confirmation shows.
    public struct Summary: Sendable, Equatable {
        public var exportedAt: Date
        public var minutes: Int
        public var workouts: Int
        public var journalDays: Int
        public var firstMinute: Date?
        public var lastMinute: Date?
    }

    public enum Failure: Error, Equatable, LocalizedError {
        case notABackup, damaged, newerVersion

        public var errorDescription: String? {
            switch self {
            case .notABackup: "This file isn't a Pulse backup."
            case .damaged: "This backup is incomplete or damaged. Nothing was imported. Export it again."
            case .newerVersion: "This backup comes from a newer version of Pulse. Update Pulse first."
            }
        }
    }

    // MARK: - Import rules

    /// Which cutoff applies after importing: the file's, because its data was kept under it.
    public static func effectiveDataStart(file: Date?, local: Date?) -> Date? { file ?? local }

    /// Simulated data and band data from before the cutoff are never imported.
    public static func accepts(_ minute: MinuteSample, dataStart: Date?) -> Bool {
        minute.source != .simulated && minute.start >= (dataStart ?? .distantPast)
    }

    /// Workouts added by hand are the user's own, so the cutoff does not apply to them.
    public static func accepts(_ workout: Workout, dataStart: Date?) -> Bool {
        guard workout.source != .simulated else { return false }
        return workout.source == .manual || workout.start >= (dataStart ?? .distantPast)
    }

    /// A minute that exists on both sides. What this iPhone already has wins; the file only fills
    /// the seconds it is missing. Beats are not added together, or importing twice would double them.
    public static func merged(existing: MinuteSample, incoming: MinuteSample) -> MinuteSample {
        var out = existing
        for second in 0..<min(existing.heartRate.count, incoming.heartRate.count, existing.activity.count, incoming.activity.count)
        where existing.heartRate[second] == 0 && incoming.heartRate[second] > 0 {
            out.heartRate[second] = incoming.heartRate[second]
            out.activity[second] = incoming.activity[second]
        }
        if incoming.rrIntervalsMs.count > existing.rrIntervalsMs.count { out.rrIntervalsMs = incoming.rrIntervalsMs }
        out.wristAngle = WristAngle.merged(existing: incoming.wristAngle, incoming: existing.wristAngle)
        return out
    }

    // MARK: - Writing

    /// Writes the file piece by piece through `sink`.
    public struct Writer {
        private let sink: (Data) throws -> Void
        private let encoder = PulseBackup.makeEncoder()
        public private(set) var minuteCount = 0

        public init(contents: Contents, sink: @escaping (Data) throws -> Void) throws {
            self.sink = sink
            var start = Data("{\n".utf8)
            start.append(try field("header", contents.header))
            start.append(try field("workouts", contents.workouts))
            start.append(try field("journal", contents.journal))
            start.append(try field("days", contents.days))
            start.append(try field("sleeps", contents.sleeps))
            start.append(try field("sleep_corrections", contents.sleepCorrections))
            start.append(try field("wear_sensor", contents.wearSensor))
            start.append(try field("step_references", contents.stepReferences))
            start.append(try field("step_minutes", contents.stepMinutes))
            start.append(Data("\"minutes\":[\n".utf8))
            try sink(start)
        }

        private func field(_ key: String, _ value: some Encodable) throws -> Data {
            var data = Data("\"\(key)\":".utf8)
            data.append(try encoder.encode(value))
            data.append(Data(",\n".utf8))
            return data
        }

        public mutating func append(_ minutes: [MinuteSample]) throws {
            var data = Data()
            for minute in minutes {
                if minuteCount > 0 { data.append(Data(",\n".utf8)) }
                data.append(try encoder.encode(MinuteRow(minute)))
                minuteCount += 1
            }
            if !data.isEmpty { try sink(data) }
        }

        public func finish() throws {
            try sink(Data("\n],\n\"footer\":{\"minutes\":\(minuteCount)}\n}\n".utf8))
        }
    }

    // MARK: - Reading

    /// Reads a file piece by piece. `chunks` returns the next bytes, or nil at the end.
    public final class Reader {
        public let contents: Contents
        private let lines: LineSource
        private var count = 0
        private var finished = false

        public init(chunks: @escaping () throws -> Data?) throws {
            let lines = LineSource(chunks)
            guard try lines.next() == "{" else { throw Failure.notABackup }
            let header: Header
            do {
                header = try Self.field("header", lines)
            } catch {
                throw Failure.notABackup
            }
            guard header.app == "Pulse" else { throw Failure.notABackup }
            guard header.formatVersion <= formatVersion else { throw Failure.newerVersion }
            var read = Contents(header: header,
                                workouts: try Self.field("workouts", lines),
                                journal: try Self.field("journal", lines),
                                days: try Self.field("days", lines),
                                sleeps: try Self.field("sleeps", lines),
                                sleepCorrections: try Self.field("sleep_corrections", lines))
            var next = try lines.next()
            // Format 2 adds the wear sensor's readings. A format 1 file goes straight on to the minutes.
            if let line = next, line.hasPrefix(Self.wearSensorPrefix) {
                read.wearSensor = try Self.value(line, prefix: Self.wearSensorPrefix)
                next = try lines.next()
            }
            // Format 3 adds the step tests and Apple Watch days.
            if let line = next, line.hasPrefix(Self.stepReferencesPrefix) {
                read.stepReferences = try Self.value(line, prefix: Self.stepReferencesPrefix)
                next = try lines.next()
            }
            // Format 4 adds the band's step count.
            if let line = next, line.hasPrefix(Self.stepMinutesPrefix) {
                read.stepMinutes = try Self.value(line, prefix: Self.stepMinutesPrefix)
                next = try lines.next()
            }
            guard next == "\"minutes\":[" else { throw Failure.damaged }
            contents = read
            self.lines = lines
        }

        private static let wearSensorPrefix = "\"wear_sensor\":"
        private static let stepReferencesPrefix = "\"step_references\":"
        private static let stepMinutesPrefix = "\"step_minutes\":"

        private static func field<T: Decodable>(_ key: String, _ lines: LineSource) throws -> T {
            guard let line = try lines.next() else { throw Failure.damaged }
            return try value(line, prefix: "\"\(key)\":")
        }

        private static func value<T: Decodable>(_ line: String, prefix: String) throws -> T {
            guard line.hasPrefix(prefix), line.hasSuffix(",") else { throw Failure.damaged }
            return try decode(T.self, line.dropFirst(prefix.count).dropLast())
        }

        private static func decode<T: Decodable>(_ type: T.Type, _ text: Substring) throws -> T {
            do {
                return try makeDecoder().decode(type, from: Data(text.utf8))
            } catch {
                throw Failure.damaged
            }
        }

        /// The next raw minute. nil once the end of the file has been reached and checked.
        public func nextMinute() throws -> MinuteSample? {
            guard !finished else { return nil }
            guard var line = try lines.next() else { throw Failure.damaged }
            if line.isEmpty, let next = try lines.next() { line = next }
            if line == "]," {
                try finish()
                return nil
            }
            let text = line.hasSuffix(",") ? line.dropLast() : Substring(line)
            guard let minute = try Self.decode(MinuteRow.self, text).sample else { throw Failure.damaged }
            count += 1
            return minute
        }

        private func finish() throws {
            struct Footer: Decodable { let minutes: Int }
            let prefix = "\"footer\":"
            guard let line = try lines.next(), line.hasPrefix(prefix), try lines.next() == "}" else { throw Failure.damaged }
            guard try Self.decode(Footer.self, line.dropFirst(prefix.count)).minutes == count else { throw Failure.damaged }
            finished = true
        }
    }

    /// Reads the whole file once, so a damaged file is refused before anything is changed.
    public static func summarize(chunks: @escaping () throws -> Data?) throws -> Summary {
        let reader = try Reader(chunks: chunks)
        var summary = Summary(exportedAt: reader.contents.header.exportedAt, minutes: 0,
                              workouts: reader.contents.workouts.count, journalDays: reader.contents.journal.count)
        while let minute = try reader.nextMinute() {
            summary.minutes += 1
            summary.firstMinute = min(summary.firstMinute ?? minute.start, minute.start)
            summary.lastMinute = max(summary.lastMinute ?? minute.start, minute.start)
        }
        return summary
    }

    // MARK: - Details

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    /// One raw minute, compact: the byte arrays are base64.
    struct MinuteRow: Codable {
        let t: Int
        let hr: String
        let rr: String
        let a: String
        let s: DataSource
        /// How far the wrist turned each second. Missing in backups and minutes from before Pulse stored it.
        let w: String?

        init(_ minute: MinuteSample) {
            w = minute.wristAngle.map { Data($0).base64EncodedString() }
            t = Int(minute.start.timeIntervalSince1970)
            hr = Data(minute.heartRate).base64EncodedString()
            rr = BinaryCoding.encode(minute.rrIntervalsMs).base64EncodedString()
            a = Data(minute.activity).base64EncodedString()
            s = minute.source
        }

        /// nil when the row can't be a real minute.
        var sample: MinuteSample? {
            guard let heartRate = Data(base64Encoded: hr), let beats = Data(base64Encoded: rr),
                  let activity = Data(base64Encoded: a), heartRate.count == 60, activity.count == 60,
                  t % 60 == 0 else { return nil }
            var wristAngle: [UInt8]?
            if let w {
                guard let turned = Data(base64Encoded: w), turned.count == 60 else { return nil }
                wristAngle = [UInt8](turned)
            }
            return MinuteSample(start: Date(timeIntervalSince1970: TimeInterval(t)), heartRate: [UInt8](heartRate),
                                rrIntervalsMs: BinaryCoding.decodeUInt16(beats), activity: [UInt8](activity), source: s,
                                wristAngle: wristAngle)
        }
    }

    /// Splits incoming chunks into lines.
    final class LineSource {
        private let chunks: () throws -> Data?
        private var buffer: [UInt8] = []
        private var position = 0
        private var ended = false

        init(_ chunks: @escaping () throws -> Data?) { self.chunks = chunks }

        func next() throws -> String? {
            var searched = position
            while true {
                if let newline = buffer[searched...].firstIndex(of: 0x0A) {
                    defer { position = newline + 1 }
                    return String(decoding: buffer[position..<newline], as: UTF8.self)
                }
                searched = buffer.count
                guard !ended else { break }
                if let chunk = try chunks(), !chunk.isEmpty {
                    buffer.removeFirst(position)
                    searched -= position
                    position = 0
                    buffer.append(contentsOf: chunk)
                } else {
                    ended = true
                }
            }
            guard position < buffer.count else { return nil }
            defer { position = buffer.count }
            return String(decoding: buffer[position...], as: UTF8.self)
        }
    }
}
