import Foundation
import Observation
import SwiftData
import PulseCore

/// Fills the app with 30 days of simulated data until a real band is paired.
/// Shared with all screens through the SwiftUI environment.
@MainActor
@Observable
final class DemoDataLoader {
    enum State: Equatable {
        case idle, generating, ready, failed(String)
    }

    private(set) var state: State = .idle
    /// True once raw minutes are saved (charts that need per-minute HR wait for this).
    private(set) var rawDataReady = false

    func loadIfEmpty(context: ModelContext) async {
        guard state == .idle else { return }
        let existing = (try? context.fetchCount(FetchDescriptor<DaySummaryRecord>())) ?? 0
        if existing > 0 {
            state = .ready
            rawDataReady = true
            return
        }
        await load(seed: 42, context: context)
    }

    /// Settings > "Regenerate demo data": wipe and create a new random month.
    func regenerate(context: ModelContext) async {
        do {
            try PulseStore.deleteAllHealthData(in: context)
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        rawDataReady = false
        await load(seed: UInt64.random(in: 1...UInt64.max), context: context)
    }

    private func load(seed: UInt64, context: ModelContext) async {
        state = .generating
        let config = FakeDataConfig(days: 30, seed: seed)
        // ~1 second of number crunching: do it off the main thread.
        let data = await Task.detached(priority: .userInitiated) {
            FakeDataGenerator.generate(config)
        }.value
        do {
            try PulseStore.insertSummaries(data, into: context)
            state = .ready
            try await MinuteImporter(modelContainer: context.container).insert(data.minutes)
            rawDataReady = true
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
