import Foundation
import Observation
import SwiftData
import PulseCore

/// Fills the app with 30 days of simulated data until a real band is paired, and re-runs the
/// metrics engine when the profile changes. Shared with all screens through the SwiftUI environment.
@MainActor
@Observable
final class DemoDataLoader {
    enum State: Equatable {
        case idle, generating, recalculating, ready, failed(String)
    }

    private(set) var state: State = .idle
    /// True once raw minutes are saved (charts that need per-minute data wait for this).
    private(set) var rawDataReady = false

    var isBusy: Bool { state == .generating || state == .recalculating }

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

    /// Settings > "Generate a new month": wipe and create a new random month.
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

    /// Settings > "Recalculate": same raw data, fresh numbers (e.g. after changing birth year).
    func recompute(context: ModelContext) async {
        guard rawDataReady, !isBusy else { return }
        state = .recalculating
        let profile = ProfileStore.current(in: context).metricsProfile
        do {
            let output = try await MetricsRecomputer(modelContainer: context.container)
                .run(profile: profile, calendar: .current, now: .now)
            try PulseStore.apply(output, to: context)
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func load(seed: UInt64, context: ModelContext) async {
        state = .generating
        let config = FakeDataConfig(days: 30, seed: seed)
        let profile = ProfileStore.current(in: context).metricsProfile
        // Simulated raw heartbeats + motion, then the REAL metrics engine computes every summary.
        // A couple of seconds of number crunching: do it off the main thread.
        let data = await Task.detached(priority: .userInitiated) {
            DemoData.make(config: config, profile: profile, calendar: .current)
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
