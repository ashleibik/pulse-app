import Foundation
import SwiftData
import PulseCore

/// Creates the app's database. Everything is stored on the device (offline first).
enum PulseStore {
    static let schema = Schema([
        MinuteRecord.self, SleepRecord.self, WorkoutRecord.self, DaySummaryRecord.self,
        BandRecord.self, ProfileRecord.self, PacketRecord.self, JournalRecord.self,
    ])

    static func makeContainer(inMemory: Bool = false) -> ModelContainer {
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        do {
            let container = try ModelContainer(for: schema, configurations: [configuration])
            if !inMemory { protectStoreFiles(at: configuration.url) }
            return container
        } catch {
            // Without a database the app can't work at all. Phase 10 adds schema migrations so
            // this can't happen after an app update.
            fatalError("Could not open the Pulse database: \(error)")
        }
    }

    /// Health data on disk stays encrypted while the phone is locked, except for files the app
    /// already has open (so a sync can finish in the background). iOS's default is weaker:
    /// readable any time after the first unlock since restart.
    private static func protectStoreFiles(at url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            let path = url.path + suffix
            guard FileManager.default.fileExists(atPath: path) else { continue }
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUnlessOpen],
                                                   ofItemAtPath: path)
        }
    }

    /// Deletes all health data (Settings > "Delete all band data"). The journal and profile stay.
    @MainActor
    static func deleteAllHealthData(in context: ModelContext) throws {
        try context.delete(model: MinuteRecord.self)
        try context.delete(model: SleepRecord.self)
        try context.delete(model: WorkoutRecord.self)
        try context.delete(model: DaySummaryRecord.self)
        try context.save()
    }

    /// Removes what older versions simulated: the demo month and simulated-band syncs.
    /// Returns true when real band data was there too (so the numbers must be recalculated).
    @MainActor
    @discardableResult
    static func removeSimulatedData(in context: ModelContext) throws -> Bool {
        let simulatedBand = UUID(uuidString: "00000000-0000-4000-8000-0000000051AB")!
        try context.delete(model: BandRecord.self, where: #Predicate { $0.peripheralID == simulatedBand })
        // Older versions remembered whether a real band had replaced the demo month.
        guard UserDefaults.standard.string(forKey: "dataSource") == "band" else {
            try deleteAllHealthData(in: context)        // demo month only: nothing real to keep
            return false
        }
        let simulated = DataSource.simulated.rawValue
        try context.delete(model: MinuteRecord.self, where: #Predicate { $0.sourceRaw == simulated })
        try context.delete(model: SleepRecord.self, where: #Predicate { $0.sourceRaw == simulated })
        try context.delete(model: WorkoutRecord.self, where: #Predicate { $0.sourceRaw == simulated })
        try context.delete(model: DaySummaryRecord.self, where: #Predicate { $0.sourceRaw == simulated })
        try context.save()
        return true
    }

    /// Empty in-memory database for SwiftUI previews (there is no fake data in the app).
    @MainActor
    static let previewContainer: ModelContainer = makeContainer(inMemory: true)
}

/// Results of re-running the metrics engine, passed from the background actor to the main thread.
struct RecomputeOutput: Sendable {
    let days: [DailySummary]
    let sleeps: [SleepSession]
    let workoutStrain: [UUID: Double]
    /// Workouts found in the raw data (only after a band sync; `nil` = leave workouts alone).
    var detectedWorkouts: [Workout]? = nil
    /// Fresh numbers for workouts the user added by hand (their band data may arrive later).
    var manualWorkouts: [UUID: Workout] = [:]
}

/// Re-runs the metrics engine over every stored raw minute, in the background.
/// Used after profile changes, and in Phase 5 after each band sync.
@ModelActor
actor MetricsRecomputer {
    /// - Parameter detectWorkouts: also look for workouts in the raw data (used after a band sync;
    ///   the demo month brings its own workouts).
    func run(profile: MetricsProfile, calendar: Calendar, now: Date,
             detectWorkouts: Bool = false) throws -> RecomputeOutput {
        var descriptor = FetchDescriptor<MinuteRecord>(sortBy: [SortDescriptor(\.start)])
        // Never compute from the previous owner's data, even if some is still stored.
        if let cutoff = BandDataCutoff.date { descriptor.predicate = #Predicate { $0.start >= cutoff } }
        let records = try modelContext.fetch(descriptor)
        let minutes = records.map(\.value)
        let result = MetricsEngine.run(minutes: minutes, profile: profile, calendar: calendar, now: now)
        var strain: [UUID: Double] = [:]
        var manual: [UUID: Workout] = [:]
        for workout in try modelContext.fetch(FetchDescriptor<WorkoutRecord>()) {
            let rest = result.days.first { calendar.isDate($0.date, inSameDayAs: workout.start) }?.restingHeartRate ?? 55
            strain[workout.id] = MetricsEngine.strain(of: minutes, from: workout.start, to: workout.end,
                                                      restingHR: rest, profile: profile)
            if workout.sourceRaw == DataSource.manual.rawValue {
                manual[workout.id] = WorkoutDetector.manual(kind: workout.kind, start: workout.start, end: workout.end,
                                                            minutes: minutes, profile: profile, restingHeartRate: rest)
            }
        }
        var output = RecomputeOutput(days: result.days, sleeps: result.sleeps, workoutStrain: strain)
        output.manualWorkouts = manual
        if detectWorkouts {
            output.detectedWorkouts = WorkoutDetector.detect(minutes: minutes, profile: profile) { date in
                result.days.first { calendar.isDate($0.date, inSameDayAs: date) }?.restingHeartRate
            }
        }
        return output
    }
}

/// Saves history downloaded from the band, on a background thread (its own ModelContext).
@ModelActor
actor BandImporter {
    /// Turns ~1 Hz records into minutes and stores them. When this returns, the data is on disk,
    /// and only then may the batch be acknowledged to the band.
    func save(_ records: [Whoop.HistoryRecord], source: DataSource) throws {
        // The sync already drops the previous owner's records; this is the second lock on the door.
        let kept = BandDataCutoff.unix.map { cutoff in records.filter { $0.timestamp >= cutoff } } ?? records
        let minutes = MinuteBuilder.minutes(from: kept, source: source)
        guard let first = minutes.first?.start, let last = minutes.last?.start else { return }
        let end = last.addingTimeInterval(60)
        let stored = try modelContext.fetch(FetchDescriptor<MinuteRecord>(
            predicate: #Predicate<MinuteRecord> { record in record.start >= first && record.start < end }))
        var byStart: [Date: MinuteRecord] = [:]
        for record in stored { byStart[record.start] = record }
        for minute in minutes {
            if let existing = byStart[minute.start] {
                existing.merge(minute)
            } else {
                modelContext.insert(MinuteRecord(minute))
            }
        }
        try modelContext.save()
    }
}

extension PulseStore {
    /// Writes recomputed results on the MAIN context, so every @Query on screen updates immediately.
    @MainActor
    static func apply(_ output: RecomputeOutput, to context: ModelContext) throws {
        try context.delete(model: DaySummaryRecord.self)
        try context.delete(model: SleepRecord.self)
        for day in output.days {
            context.insert(DaySummaryRecord(day, algorithmVersion: MetricsEngine.algorithmVersion))
        }
        for sleep in output.sleeps { context.insert(SleepRecord(sleep)) }
        let workouts = try context.fetch(FetchDescriptor<WorkoutRecord>())
        for workout in workouts {
            if let strain = output.workoutStrain[workout.id] { workout.strain = strain }
            // A workout started in the app is saved before its band data is synced: fill it in now.
            if let fresh = output.manualWorkouts[workout.id], fresh.averageHeartRate > 0 {
                workout.averageHeartRate = fresh.averageHeartRate
                workout.maxHeartRate = fresh.maxHeartRate
                workout.zoneSeconds = fresh.zoneSeconds
                workout.calories = fresh.calories
                workout.strain = fresh.strain
            }
        }
        if let detected = output.detectedWorkouts {
            // Planned demo workouts are kept as they are. Detected ones are added, updated, or
            // removed if the detector no longer finds them. IDs are stable (WorkoutDetector.stableID),
            // so a workout keeps its Apple Health / Strava marks across syncs.
            // "kept" = demo workouts and ones the user added by hand: detection never touches them.
            let demo = workouts.filter { $0.sourceRaw != DataSource.history.rawValue }
            var fromBand: [UUID: WorkoutRecord] = [:]
            for workout in workouts where workout.sourceRaw == DataSource.history.rawValue {
                fromBand[workout.id] = workout
            }
            for found in detected {
                if demo.contains(where: { $0.start < found.end && $0.end > found.start }) { continue }
                if let existing = fromBand.removeValue(forKey: found.id) {
                    existing.end = found.end
                    existing.averageHeartRate = found.averageHeartRate
                    existing.maxHeartRate = found.maxHeartRate
                    existing.strain = found.strain
                    existing.zoneSeconds = found.zoneSeconds
                    existing.calories = found.calories
                } else {
                    context.insert(WorkoutRecord(found))
                }
            }
            for stale in fromBand.values { context.delete(stale) }
        }
        try context.save()
    }

    /// Raw minutes in [from, to), as plain values (for charts and the sleep timeline).
    /// Call with the view's (main) context from the main thread.
    static func minutes(from start: Date, to end: Date, in context: ModelContext) -> [MinuteSample] {
        let descriptor = FetchDescriptor<MinuteRecord>(
            predicate: #Predicate<MinuteRecord> { record in record.start >= start && record.start < end },
            sortBy: [SortDescriptor(\.start)]
        )
        return ((try? context.fetch(descriptor)) ?? []).map(\.value)
    }
}

/// Inserts raw minutes on a background thread. @ModelActor gives this actor its own ModelContext,
/// so the ~43,000 inserts don't freeze the UI.
@ModelActor
actor MinuteImporter {
    func insert(_ minutes: [MinuteSample]) throws {
        for (index, minute) in minutes.enumerated() {
            modelContext.insert(MinuteRecord(minute))
            if index % 2000 == 1999 { try modelContext.save() }   // save in batches to keep memory low
        }
        try modelContext.save()
    }
}
