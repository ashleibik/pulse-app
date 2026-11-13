import Foundation
import HealthKit
import Observation
import SwiftData
import PulseCore

/// Writes Pulse's results to Apple Health: sleep, resting heart rate and workouts.
///
/// WHAT is written is decided by PulseCore's `HealthExport` (tested): never simulated data, no
/// HRV, no calories. This class only carries that plan out.
///
/// Privacy: Pulse asks for WRITE access only. It never reads anything from Apple Health.
///
/// Writing the same night twice must not create duplicates, so before saving, Pulse deletes what
/// it wrote earlier for the same time span (an app may delete its own samples).
///
/// ⚠ Never run on a real iPhone yet. HealthKit also needs the HealthKit capability in the signed
/// app (Pulse.entitlements), which the unsigned simulator builds in CI don't exercise.
@MainActor
@Observable
final class HealthExporter {

    enum Status: Equatable {
        case idle
        case working
        case done(String)
        case failed(String)
    }

    private(set) var status: Status = .idle
    /// The user's choice, remembered between launches (a setting, not health data).
    private(set) var isEnabled = UserDefaults.standard.bool(forKey: HealthExporter.enabledKey)

    private static let enabledKey = "healthExportEnabled"
    private let store = HKHealthStore()

    /// False on devices without the Health app (some iPads).
    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private var sleepType: HKCategoryType { HKCategoryType(.sleepAnalysis) }
    private var restingType: HKQuantityType { HKQuantityType(.restingHeartRate) }
    private var writeTypes: Set<HKSampleType> { [sleepType, restingType, HKObjectType.workoutType()] }

    // MARK: - Turning it on and off

    /// Shows Apple's permission sheet (write access only), then exports once.
    func enable(context: ModelContext) async {
        guard isAvailable else {
            status = .failed("Apple Health isn't available on this device.")
            return
        }
        do {
            try await store.requestAuthorization(toShare: writeTypes, read: [])
            setEnabled(true)
            await export(context: context, everything: true)
        } catch {
            status = .failed("Apple Health did not open: \(error.localizedDescription)")
        }
    }

    /// Stops future exports. What was already written stays in Apple Health (the user can delete
    /// it there: Health > Profile > Apps > Pulse).
    func disable() {
        setEnabled(false)
        status = .idle
    }

    private func setEnabled(_ value: Bool) {
        isEnabled = value
        UserDefaults.standard.set(value, forKey: Self.enabledKey)
    }

    // MARK: - Exporting

    /// - Parameter everything: `false` (after each sync) writes only the last 3 days again;
    ///   `true` writes all stored history.
    func export(context: ModelContext, everything: Bool = false) async {
        guard isEnabled, isAvailable, status != .working else { return }
        status = .working
        let since = everything ? nil : Date.now.addingTimeInterval(-3 * 86_400)
        do {
            let sleeps = try context.fetch(FetchDescriptor<SleepRecord>())
            let workouts = try context.fetch(FetchDescriptor<WorkoutRecord>())
            let days = try context.fetch(FetchDescriptor<DaySummaryRecord>())
            let plan = HealthExport.plan(sleeps: sleeps.map(\.value), workouts: workouts.map(\.value),
                                         days: days.map(\.value), since: since)
            guard !plan.isEmpty else {
                status = .done("Nothing to export yet. Demo data is never written to Apple Health.")
                return
            }
            for session in plan.sleeps { try await write(session, context: context) }
            for day in plan.restingDays { try await writeRestingHeartRate(day) }
            for workout in plan.workouts {
                try await write(workout)
                workouts.first { $0.id == workout.id }?.healthKitID = workout.id
            }
            try context.save()
            status = .done("Exported \(plan.sleeps.count) nights, \(plan.workouts.count) workouts and \(plan.restingDays.count) resting heart rates.")
        } catch {
            status = .failed("Apple Health export failed: \(error.localizedDescription)")
        }
    }

    private func write(_ session: SleepSession, context: ModelContext) async throws {
        let minutes = PulseStore.minutes(from: session.start, to: session.end, in: context)
        let segments = SleepTimeline.build(minutes: minutes, from: session.start, to: session.end)
        let samples = HealthExport.sleepIntervals(for: session, segments: segments).map { interval in
            HKCategorySample(type: sleepType, value: Self.value(for: interval.kind).rawValue,
                             start: interval.start, end: interval.end)
        }
        try await deleteOwnSamples(of: sleepType, from: session.start, to: session.end)
        try await store.save(samples)
    }

    private func writeRestingHeartRate(_ day: DailySummary) async throws {
        guard let bpm = day.restingHeartRate else { return }
        let end = min(day.date.addingTimeInterval(86_400), .now)
        guard end > day.date else { return }
        let unit = HKUnit.count().unitDivided(by: .minute())
        let sample = HKQuantitySample(type: restingType, quantity: HKQuantity(unit: unit, doubleValue: bpm.rounded()),
                                      start: day.date, end: end)
        try await deleteOwnSamples(of: restingType, from: day.date, to: end)
        try await store.save(sample)
    }

    private func write(_ workout: Workout) async throws {
        try await deleteOwnSamples(of: HKObjectType.workoutType(), from: workout.start, to: workout.end)
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = Self.activityType(for: workout.kind)
        let builder = HKWorkoutBuilder(healthStore: store, configuration: configuration, device: nil)
        try await builder.beginCollection(at: workout.start)
        try await builder.endCollection(at: workout.end)
        _ = try await builder.finishWorkout()
    }

    /// Deletes what Pulse itself wrote earlier in this time span. Samples from other apps and
    /// devices are never touched (the predicate is limited to this app as the source).
    private func deleteOwnSamples(of type: HKObjectType, from start: Date, to end: Date) async throws {
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForObjects(from: HKSource.default()),
            HKQuery.predicateForSamples(withStart: start, end: end, options: []),
        ])
        do {
            _ = try await store.deleteObjects(of: type, predicate: predicate)
        } catch let error as HKError where error.code == .errorNoData {
            // Nothing to delete: fine.
        }
    }

    private static func value(for kind: HealthExport.SleepKind) -> HKCategoryValueSleepAnalysis {
        switch kind {
        case .inBed: .inBed
        case .asleep: .asleepUnspecified
        case .awake: .awake
        }
    }

    private static func activityType(for kind: WorkoutKind) -> HKWorkoutActivityType {
        switch kind {
        case .run: .running
        case .ride: .cycling
        case .strength: .traditionalStrengthTraining
        case .walk: .walking
        case .hiit: .highIntensityIntervalTraining
        case .other: .other
        }
    }
}
