import Foundation
import SwiftData
import PulseCore

/// Writes and reads the backup file (Settings > Your data) on a background thread, a page of raw
/// minutes at a time. The format and its rules are in PulseCore's `PulseBackup` (tested).
@ModelActor
actor BackupStore {
    private static let pageSize = 1000

    struct ImportResult: Sendable {
        var minutesAdded = 0
        var minutesMerged = 0
        var workoutsAdded = 0
        var journalDays = 0
    }

    // MARK: - Export

    /// Writes everything to a new file in the temporary folder and returns its address.
    func export(header: PulseBackup.Header, wearSensor: [WearSensor.Observation]) throws -> URL {
        let name = "pulse-backup-\(header.exportedAt.formatted(.iso8601.year().month().day())).json"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        // Health data: encrypted on disk while the phone is locked.
        guard FileManager.default.createFile(atPath: url.path, contents: nil,
                                             attributes: [.protectionKey: FileProtectionType.complete]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        let workouts = try modelContext.fetch(FetchDescriptor<WorkoutRecord>(sortBy: [SortDescriptor(\.start)])).map {
            PulseBackup.WorkoutEntry(workout: $0.value, healthKitID: $0.healthKitID, stravaUploadedAt: $0.stravaUploadedAt)
        }
        let journal = try modelContext.fetch(FetchDescriptor<JournalRecord>(sortBy: [SortDescriptor(\.day)])).map {
            PulseBackup.JournalDay(day: $0.day, habits: $0.habitsRaw.sorted())
        }
        let days = try modelContext.fetch(FetchDescriptor<DaySummaryRecord>(sortBy: [SortDescriptor(\.date)])).map(\.value)
        let sleeps = try modelContext.fetch(FetchDescriptor<SleepRecord>(sortBy: [SortDescriptor(\.start)])).map(\.value)
        let corrections = try modelContext.fetch(FetchDescriptor<SleepCorrectionRecord>()).map(\.value)
        let stepReferences = try modelContext.fetch(FetchDescriptor<StepReferenceRecord>(sortBy: [SortDescriptor(\.start)])).map(\.value)
        let stepMinutes = try modelContext.fetch(FetchDescriptor<StepMinuteRecord>(sortBy: [SortDescriptor(\.start)])).map(\.value)
        let contents = PulseBackup.Contents(header: header, workouts: workouts, journal: journal, days: days, sleeps: sleeps,
                                            sleepCorrections: corrections, wearSensor: wearSensor, stepReferences: stepReferences,
                                            stepMinutes: stepMinutes)

        var writer = try PulseBackup.Writer(contents: contents) { try handle.write(contentsOf: $0) }
        var after = Date.distantPast
        while true {
            let cursor = after
            var page = FetchDescriptor<MinuteRecord>(predicate: #Predicate<MinuteRecord> { $0.start > cursor },
                                                     sortBy: [SortDescriptor(\.start)])
            page.fetchLimit = Self.pageSize
            let minutes = try modelContext.fetch(page).map(\.value)
            guard let last = minutes.last else { break }
            try writer.append(minutes)
            after = last.start
        }
        try writer.finish()
        return url
    }

    // MARK: - Import

    /// Merges the file into the database. Call `BackupFile.summary` first: it refuses a damaged
    /// file before anything is changed.
    func importFile(at url: URL, dataStart: Date?) throws -> ImportResult {
        let file = try BackupFile(url: url)
        defer { file.close() }
        let reader = try PulseBackup.Reader(chunks: file.nextChunk)
        var result = ImportResult()

        let workouts = try modelContext.fetch(FetchDescriptor<WorkoutRecord>())
        var workoutsByID = Dictionary(uniqueKeysWithValues: workouts.map { ($0.id, $0) })
        for entry in reader.contents.workouts where PulseBackup.accepts(entry.workout, dataStart: dataStart) {
            if let existing = workoutsByID[entry.workout.id] {
                existing.healthKitID = existing.healthKitID ?? entry.healthKitID
                existing.stravaUploadedAt = existing.stravaUploadedAt ?? entry.stravaUploadedAt
            } else {
                let record = WorkoutRecord(entry.workout)
                record.healthKitID = entry.healthKitID
                record.stravaUploadedAt = entry.stravaUploadedAt
                modelContext.insert(record)
                workoutsByID[entry.workout.id] = record
                result.workoutsAdded += 1
            }
        }

        let journal = try modelContext.fetch(FetchDescriptor<JournalRecord>())
        var journalByDay = Dictionary(uniqueKeysWithValues: journal.map { ($0.day, $0) })
        for entry in reader.contents.journal {
            if let existing = journalByDay[entry.day] {
                existing.habitsRaw = Array(Set(existing.habitsRaw).union(entry.habits)).sorted()
            } else {
                let record = JournalRecord(day: entry.day, habits: [])
                record.habitsRaw = entry.habits
                modelContext.insert(record)
                journalByDay[entry.day] = record
            }
            result.journalDays += 1
        }

        let knownCorrections = Set(try modelContext.fetch(FetchDescriptor<SleepCorrectionRecord>()).map(\.id))
        for correction in reader.contents.sleepCorrections where !knownCorrections.contains(correction.id) {
            modelContext.insert(SleepCorrectionRecord(correction))
        }
        let knownReferences = Set(try modelContext.fetch(FetchDescriptor<StepReferenceRecord>()).map(\.id))
        for reference in reader.contents.stepReferences where !knownReferences.contains(reference.id) {
            modelContext.insert(StepReferenceRecord(reference))
        }
        // The band's step count: a minute this iPhone already has stays as it is.
        let knownStepMinutes = Set(try modelContext.fetch(FetchDescriptor<StepMinuteRecord>()).map(\.start))
        for minute in reader.contents.stepMinutes
        where !knownStepMinutes.contains(minute.start) && minute.start >= (dataStart ?? .distantPast) {
            modelContext.insert(StepMinuteRecord(minute))
        }
        try modelContext.save()

        var page: [MinuteSample] = []
        while let minute = try reader.nextMinute() {
            guard PulseBackup.accepts(minute, dataStart: dataStart) else { continue }
            page.append(minute)
            if page.count == Self.pageSize {
                try save(page, into: &result)
                page.removeAll(keepingCapacity: true)
            }
        }
        try save(page, into: &result)
        return result
    }

    private func save(_ minutes: [MinuteSample], into result: inout ImportResult) throws {
        guard let first = minutes.map(\.start).min(), let last = minutes.map(\.start).max() else { return }
        let stored = try modelContext.fetch(FetchDescriptor<MinuteRecord>(
            predicate: #Predicate<MinuteRecord> { $0.start >= first && $0.start <= last }))
        let byStart = Dictionary(uniqueKeysWithValues: stored.map { ($0.start, $0) })
        for minute in minutes {
            if let existing = byStart[minute.start] {
                existing.replace(with: PulseBackup.merged(existing: existing.value, incoming: minute))
                result.minutesMerged += 1
            } else {
                modelContext.insert(MinuteRecord(minute))
                result.minutesAdded += 1
            }
        }
        try modelContext.save()
    }
}

/// A backup file on disk, handed to `PulseBackup.Reader` a piece at a time.
final class BackupFile {
    private let handle: FileHandle

    init(url: URL) throws { handle = try FileHandle(forReadingFrom: url) }

    func nextChunk() throws -> Data? { try handle.read(upToCount: 256 * 1024) }

    func close() { try? handle.close() }

    /// Reads the whole file and checks it. Throws `PulseBackup.Failure` if it can't be imported.
    static func summary(of url: URL) throws -> PulseBackup.Summary {
        let file = try BackupFile(url: url)
        defer { file.close() }
        return try PulseBackup.summarize(chunks: file.nextChunk)
    }

    /// The cutoff and profile stored in the file.
    static func header(of url: URL) throws -> PulseBackup.Header {
        let file = try BackupFile(url: url)
        defer { file.close() }
        return try PulseBackup.Reader(chunks: file.nextChunk).contents.header
    }
}

extension MinuteRecord {
    /// Overwrites this minute with an already merged value.
    func replace(with sample: MinuteSample) {
        heartRate = Data(sample.heartRate)
        rrIntervals = BinaryCoding.encode(sample.rrIntervalsMs)
        activity = Data(sample.activity)
        wristAngle = sample.wristAngle.map { Data($0) }
        sourceRaw = sample.source.rawValue
    }
}

extension ProfileRecord {
    /// The profile as it goes into a backup.
    var backup: PulseBackup.Profile {
        PulseBackup.Profile(birthYear: birthYear, maxHeartRateOverride: maxHeartRateOverride,
                            sleepGoalMinutes: sleepGoalMinutes, sex: sex, weightKg: weightKg, heightCm: heightCm, stepGoal: stepGoal,
                            waistCm: waistCm)
    }

    func restore(_ profile: PulseBackup.Profile) {
        birthYear = profile.birthYear
        maxHeartRateOverride = profile.maxHeartRateOverride
        sleepGoalMinutes = profile.sleepGoalMinutes
        sex = profile.sex
        weightKg = profile.weightKg
        heightCm = profile.heightCm
        if let goal = profile.stepGoal { stepGoal = goal }
        if let waist = profile.waistCm { waistCm = waist }
    }
}
