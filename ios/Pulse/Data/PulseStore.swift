import Foundation
import SwiftData
import PulseCore

/// Creates the app's database. Everything is stored on the device (offline first).
enum PulseStore {
    static let schema = Schema([
        MinuteRecord.self, SleepRecord.self, WorkoutRecord.self, DaySummaryRecord.self,
        BandRecord.self, ProfileRecord.self, PacketRecord.self,
    ])

    static func makeContainer(inMemory: Bool = false) -> ModelContainer {
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            // Without a database the app can't work at all. Phase 10 adds schema migrations so
            // this can't happen after an app update.
            fatalError("Could not open the Pulse database: \(error)")
        }
    }

    /// Small summary records: inserted on the caller's context so @Query views update right away.
    @MainActor
    static func insertSummaries(_ data: FakeDataset, into context: ModelContext) throws {
        for day in data.days { context.insert(DaySummaryRecord(day)) }
        for sleep in data.sleeps { context.insert(SleepRecord(sleep)) }
        for workout in data.workouts { context.insert(WorkoutRecord(workout)) }
        try context.save()
    }

    /// Deletes everything (used by "Regenerate demo data" in Settings).
    @MainActor
    static func deleteAllHealthData(in context: ModelContext) throws {
        try context.delete(model: MinuteRecord.self)
        try context.delete(model: SleepRecord.self)
        try context.delete(model: WorkoutRecord.self)
        try context.delete(model: DaySummaryRecord.self)
        try context.save()
    }

    /// In-memory database full of demo data, for SwiftUI previews.
    @MainActor
    static let previewContainer: ModelContainer = {
        let container = makeContainer(inMemory: true)
        let data = FakeDataGenerator.generate(FakeDataConfig(days: 30, seed: 42))
        try? insertSummaries(data, into: container.mainContext)
        // Only the last ~36 hours of raw minutes: enough for last night's charts, fast to insert.
        let cutoff = Date.now.addingTimeInterval(-36 * 3600)
        for minute in data.minutes where minute.start >= cutoff {
            container.mainContext.insert(MinuteRecord(minute))
        }
        try? container.mainContext.save()
        return container
    }()
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
