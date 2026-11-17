import Foundation
import Observation
import SwiftData
import PulseCore

/// Tells the screens when the stored data changed, and re-runs the metrics engine when the
/// profile changes. Shared with all screens through the SwiftUI environment.
///
/// There is no demo data anymore: every number comes from the band. (The fake data generator
/// only exists in PulseCore's unit tests.)
@MainActor
@Observable
final class DataLoader {
    enum State: Equatable {
        case idle, recalculating, ready, failed(String)
    }

    private(set) var state: State = .idle
    /// True once the app has checked its database (charts that read raw minutes wait for this).
    private(set) var rawDataReady = false
    /// Goes up whenever the stored data changes (band synced, data deleted). Screens that read
    /// raw minutes use it to know when to read again.
    private(set) var revision = 0

    /// Set once the simulated data of older versions has been removed from this iPhone.
    private static let simulatedRemovedKey = "simulatedDataRemoved.v1"

    /// Call after a band sync (or a delete) changed the stored data.
    func dataChanged() {
        rawDataReady = true
        state = .ready
        revision += 1
    }

    var isBusy: Bool { state == .recalculating }

    /// On launch. The first time this version runs, it deletes everything older versions
    /// simulated (the demo month, simulated-band syncs), keeping real band data and the journal.
    func prepare(context: ModelContext) async {
        guard state == .idle else { return }
        let defaults = UserDefaults.standard
        var removedFromBandData = false
        if !defaults.bool(forKey: Self.simulatedRemovedKey) {
            removedFromBandData = (try? PulseStore.removeSimulatedData(in: context)) ?? false
            defaults.set(true, forKey: Self.simulatedRemovedKey)
            defaults.removeObject(forKey: "dataSource")
            defaults.removeObject(forKey: "demoRawImportComplete")
        }
        // Used band: before this version the pairing day wasn't stored. Pick a safe one.
        if BandManager.pairedBand(in: context) != nil { BandDataCutoff.setForExistingInstall() }
        let removedOldOwner = BandDataCutoff.date.map {
            (try? PulseStore.deleteBandData(before: $0, in: context)) ?? false
        } ?? false
        state = .ready
        rawDataReady = true
        revision += 1
        // Rows were deleted: recalculate from what's left.
        if removedFromBandData || removedOldOwner { await recompute(context: context, detectWorkouts: removedOldOwner) }
    }

    /// Settings > "Your data starts": deletes everything before the new day, then recalculates.
    func setDataStart(_ day: Date, context: ModelContext) async {
        BandDataCutoff.set(day)
        guard let cutoff = BandDataCutoff.date else { return }
        _ = try? PulseStore.deleteBandData(before: cutoff, in: context)
        await recompute(context: context, detectWorkouts: true)
    }

    /// Settings > "Recalculate": same raw data, fresh numbers (e.g. after changing birth year).
    func recompute(context: ModelContext, detectWorkouts: Bool = false) async {
        guard rawDataReady, !isBusy else { return }
        state = .recalculating
        let profile = ProfileStore.current(in: context).metricsProfile
        do {
            let output = try await MetricsRecomputer(modelContainer: context.container)
                .run(profile: profile, calendar: .current, now: .now, detectWorkouts: detectWorkouts)
            try PulseStore.apply(output, to: context)
            state = .ready
            revision += 1
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
