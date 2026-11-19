import Foundation
import Observation
import SwiftUI
import PulseCore

/// What the band last said about how it sits on the wrist. Kept on this iPhone in a small file.
@MainActor
@Observable
final class WearSensorStore {
    static let shared = WearSensorStore()

    private(set) var observations: [WearSensor.Observation]

    private static var fileURL: URL { URL.applicationSupportDirectory.appending(path: "wear-sensor.json") }

    private init() {
        observations = (try? Data(contentsOf: Self.fileURL)).flatMap { try? JSONDecoder().decode([WearSensor.Observation].self, from: $0) } ?? []
    }

    var status: WearSensor.Status { WearSensor.status(observations, now: .now) }

    /// What the Settings row shows: the current state, or the last reading with its time.
    var rowText: String {
        let current = status
        guard current.label == "--", let last = current.lastReading, let loose = last.isLoose else { return current.label }
        return "\(loose ? "Loose" : "OK") at \(last.time.formatted(date: .omitted, time: .shortened))"
    }

    func quality(from start: Date, to end: Date) -> WearSensor.Quality {
        WearSensor.quality(from: start, to: end, observations: observations)
    }

    func record(_ readings: [WearSensor.Reading], receivedAt now: Date) {
        let updated = readings.reduce(observations) { WearSensor.adding(WearSensor.Observation($1.event, at: $1.time ?? now), to: $0) }
        guard updated != observations else { return }
        observations = updated
        save()
    }

    func clear() {
        observations = []
        try? FileManager.default.removeItem(at: Self.fileURL)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(observations) else { return }
        try? FileManager.default.createDirectory(at: URL.applicationSupportDirectory, withIntermediateDirectories: true)
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}

/// One small line when the band reports a loose strap (DESIGN.md §4b-3).
struct LooseStrapHint: View {
    private var store: WearSensorStore { .shared }

    var body: some View {
        if store.status.isLoose == true {
            Label(WearSensor.looseHint, systemImage: "exclamationmark.triangle")
                .textStyle(.caption)
                .foregroundStyle(DS.Colors.warn)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One small line on a workout or night spent mostly with a loose strap.
struct WearQualityNote: View {
    let start: Date
    let end: Date
    private var store: WearSensorStore { .shared }

    var body: some View {
        if store.quality(from: start, to: end) == .reduced {
            Label(WearSensor.lessCertainNote, systemImage: "exclamationmark.triangle")
                .textStyle(.caption)
                .foregroundStyle(DS.Colors.warn)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
