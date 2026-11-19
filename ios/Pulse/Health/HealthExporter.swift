import Foundation
import HealthKit
import Observation
import SwiftData
import PulseCore

/// Backs Pulse's results up to Apple Health: sleep (asleep + awake), heart rate, resting heart rate,
/// HRV (SDNN) and workouts. Steps and active energy are never written: the Apple Watch owns those.
/// Estimated sleep stages are written only if the user turns that setting on.
///
/// WHAT is written is decided by PulseCore's `HealthExport` (tested). This class only carries it out.
///
/// No duplicates, in four layers:
/// 1. Every sample has a stable sync identifier, so Apple Health replaces instead of adding.
/// 2. `HealthLedger` remembers what was written, so unchanged items are skipped.
/// 3. A night that changed replaces what Pulse wrote for it (only Pulse's own samples are deleted).
/// 4. Pulse reads back only to avoid doubling: samples an earlier install of Pulse wrote (re-signing
///    can make it a different source), and workouts another app such as the Apple Watch recorded.
///
/// HealthKit also needs the HealthKit capability in the signed app. `signing` reads whether the tool
/// that signed this install kept it, and every step leaves a HEALTHKIT line in `traceLines`.
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
    /// "Write sleep stages to Apple Health (estimated)". Off until the stages have been validated.
    private(set) var writesSleepStages = UserDefaults.standard.bool(forKey: HealthExporter.stagesKey)
    /// Whether the signing tool gave this install access to Apple Health.
    let signing = HealthAccess.signing(embeddedProfile: Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")
        .flatMap { try? Data(contentsOf: $0) })
    private(set) var lastWrittenAt = UserDefaults.standard.object(forKey: HealthExporter.lastWrittenAtKey) as? Date
    private(set) var lastWrittenSamples = UserDefaults.standard.integer(forKey: HealthExporter.lastWrittenSamplesKey)
    /// The newest HEALTHKIT log lines, oldest first.
    private(set) var traceLines = UserDefaults.standard.stringArray(forKey: HealthExporter.traceKey) ?? []

    private static let enabledKey = "healthExportEnabled"
    private static let stagesKey = "healthExportSleepStages"
    private static let ledgerKey = "healthExportLedger.v1"
    private static let lastWrittenAtKey = "healthExportLastWrittenAt"
    private static let lastWrittenSamplesKey = "healthExportLastWrittenSamples"
    private static let traceKey = "healthExportTrace"
    private static let traceLimit = 200
    /// Marks a sample as written by Pulse, whichever install wrote it.
    private static let exportIDKey = "PulseExportID"
    private static let saveChunk = 500

    private let store = HKHealthStore()
    @ObservationIgnored private var ledger = HealthExporter.loadLedger()
    /// The user changed a sleep older than the usual re-check window: look back this far once.
    @ObservationIgnored private var recheckOverride: Date?
    /// Samples saved to Apple Health by the export that is running.
    @ObservationIgnored private var samplesThisExport = 0

    /// False on devices without the Health app (some iPads).
    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() && signing != .missing }

    private var sleepType: HKCategoryType { HKCategoryType(.sleepAnalysis) }
    private var heartRateType: HKQuantityType { HKQuantityType(.heartRate) }
    private var restingType: HKQuantityType { HKQuantityType(.restingHeartRate) }
    private var hrvType: HKQuantityType { HKQuantityType(.heartRateVariabilitySDNN) }
    private var workoutType: HKWorkoutType { HKObjectType.workoutType() }
    private var writeTypes: Set<HKSampleType> { [sleepType, heartRateType, restingType, hrvType, workoutType] }
    private var readTypes: Set<HKObjectType> { Set(writeTypes.map { $0 as HKObjectType }) }
    private var bpm: HKUnit { HKUnit.count().unitDivided(by: .minute()) }

    // MARK: - Turning it on and off

    /// Shows Apple's permission sheet, then exports once.
    func enable(context: ModelContext) async {
        trace("turn on tapped, signing \(signing.rawValue), health data available \(HKHealthStore.isHealthDataAvailable())")
        guard signing != .missing else {
            status = .failed(HealthAccess.missingMessage)
            return
        }
        guard isAvailable else {
            status = .failed("Apple Health isn't available on this device.")
            return
        }
        do {
            try await store.requestAuthorization(toShare: writeTypes, read: readTypes)
            trace("permission sheet finished, \(authorizationSummary)")
            setEnabled(true)
            await export(context: context, everything: true)
        } catch {
            traceFailure("permission request", error)
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

    /// Changes how sleep is written, and rewrites the nights already in Apple Health to match.
    func setWritesSleepStages(_ value: Bool, context: ModelContext) async {
        guard value != writesSleepStages else { return }
        writesSleepStages = value
        UserDefaults.standard.set(value, forKey: Self.stagesKey)
        await export(context: context, everything: true)
    }

    /// The user edited or removed a sleep: what Pulse wrote for that time goes, and the current
    /// version of the night is written again.
    func sleepChanged(from start: Date, to end: Date, context: ModelContext) async {
        guard isEnabled, isAvailable else { return }
        try? await deleteOwnSamples(of: sleepType, from: start, to: end)
        try? await deleteOwnSamples(of: hrvType, from: start, to: end)
        ledger.forget(prefix: "pulse.sleep.")
        ledger.forget(prefix: "pulse.hrv.")
        recheckOverride = start.addingTimeInterval(-86_400)
        await export(context: context)
    }

    // MARK: - Exporting

    /// - Parameter everything: `false` (after each sync, and when the app opens) writes what is new
    ///   or changed; `true` (Settings > Export all) goes through all stored history again.
    func export(context: ModelContext, everything: Bool = false) async {
        guard isEnabled, isAvailable, status != .working else { return }
        status = .working
        samplesThisExport = 0
        trace(everything ? "export started, all history" : "export started, new data")
        if everything { ledger = HealthLedger() }
        defer { saveLedger() }
        do {
            guard try await isAuthorized(askIfNeeded: everything) else {
                status = .failed("Apple Health needs your permission for the new data. Tap Export all.")
                return
            }
            let dataStart = BandDataCutoff.date
            let reader = HealthMinuteReader(modelContainer: context.container)
            let workoutRecords = try context.fetch(FetchDescriptor<WorkoutRecord>())
            let since = ledger.recheckFrom.map { min($0, recheckOverride ?? $0) }
            recheckOverride = nil
            let plan = HealthExport.plan(
                sleeps: try context.fetch(FetchDescriptor<SleepRecord>()).map(\.value),
                workouts: workoutRecords.map(\.value),
                days: try context.fetch(FetchDescriptor<DaySummaryRecord>()).map(\.value),
                since: since, dataStart: dataStart)

            try await removeNightsNoLongerDetected(keeping: plan.sleeps, since: since)
            let sleep = try await writeSleep(plan.sleeps, reader: reader)
            let resting = try await writeRestingHeartRates(plan.restingDays)
            let workouts = try await writeWorkouts(plan.workouts, records: workoutRecords)
            try context.save()
            let minutes = try await writeHeartRate(reader: reader, dataStart: dataStart)
            ledger.prune(now: .now)

            let total = sleep.nights + sleep.hrv + resting + workouts + minutes
            recordWritten()
            trace("export finished, \(samplesThisExport) samples: \(sleep.nights) nights, \(minutes) heart rate, "
                + "\(sleep.hrv) HRV, \(resting) resting, \(workouts) workouts")
            status = total == 0 && !everything ? .idle
                : .done("Saved \(sleep.nights) nights, \(minutes) heart rate minutes, \(sleep.hrv) HRV readings, \(resting) resting heart rates and \(workouts) workouts.")
        } catch let error as HKError where error.code == .errorDatabaseInaccessible {
            trace("export paused, the iPhone is locked")
            status = .idle      // the iPhone is locked: the next export picks this up
        } catch is CancellationError {
            status = .idle
        } catch {
            traceFailure("export", error)
            recordWritten()
            status = .failed("Apple Health export failed: \(error.localizedDescription)")
        }
    }

    // MARK: - What happened

    private var authorizationSummary: String {
        [("sleep", sleepType), ("heart rate", heartRateType), ("resting", restingType), ("HRV", hrvType), ("workouts", workoutType)]
            .map { name, type in "\(name) \(store.authorizationStatus(for: type) == .sharingAuthorized ? "allowed" : "not allowed")" }
            .joined(separator: ", ")
    }

    private func recordWritten() {
        guard samplesThisExport > 0 else { return }
        lastWrittenAt = .now
        lastWrittenSamples = samplesThisExport
        UserDefaults.standard.set(lastWrittenAt, forKey: Self.lastWrittenAtKey)
        UserDefaults.standard.set(lastWrittenSamples, forKey: Self.lastWrittenSamplesKey)
    }

    private func traceFailure(_ step: String, _ error: Error) {
        let details = error as NSError
        trace("\(step) failed, \(details.domain) code \(details.code): \(details.localizedDescription)")
    }

    private func trace(_ message: String) {
        traceLines.append("HEALTHKIT \(Date.now.formatted(date: .numeric, time: .standard)) \(message)")
        if traceLines.count > Self.traceLimit { traceLines.removeFirst(traceLines.count - Self.traceLimit) }
        UserDefaults.standard.set(traceLines, forKey: Self.traceKey)
    }

    /// False when an older version was allowed fewer kinds of data and the user isn't here to be asked.
    private func isAuthorized(askIfNeeded: Bool) async throws -> Bool {
        let request = try await store.statusForAuthorizationRequest(toShare: writeTypes, read: readTypes)
        guard request == .shouldRequest else { return true }
        guard askIfNeeded else { return false }
        try await store.requestAuthorization(toShare: writeTypes, read: readTypes)
        return true
    }

    /// The user can allow some kinds of data and not others: the allowed ones still go through.
    private func canWrite(_ type: HKSampleType) -> Bool {
        store.authorizationStatus(for: type) == .sharingAuthorized
    }

    // MARK: - Sleep and HRV

    private struct Night {
        let session: SleepSession
        let id: String
        let fingerprint: String
        let intervals: [HealthExport.SleepInterval]
        let hrv: HealthExport.HRVPoint?
    }

    /// A sleep Pulse wrote earlier and no longer believes in (better detection) leaves Apple Health too.
    private func removeNightsNoLongerDetected(keeping sessions: [SleepSession], since: Date?) async throws {
        guard canWrite(sleepType) else { return }
        let tagged = HKQuery.predicateForObjects(withMetadataKey: Self.exportIDKey)
        let stale = await samples(of: sleepType, from: since ?? .distantPast, to: .now, matching: tagged).filter { sample in
            !Self.isFromAnotherApp(sample)
                && !sessions.contains { $0.start < sample.endDate && sample.startDate < $0.end }
        }
        if !stale.isEmpty { try await store.delete(stale) }
    }

    private func writeSleep(_ sessions: [SleepSession], reader: HealthMinuteReader) async throws -> (nights: Int, hrv: Int) {
        var nights: [Night] = []
        for session in sessions {
            let minutes = try await reader.minutes(from: session.start, to: session.end)
            let segments = SleepTimeline.build(minutes: minutes, from: session.start, to: session.end, findRestful: writesSleepStages)
            let intervals = HealthExport.sleepIntervals(for: session, segments: segments, writeStages: writesSleepStages)
            nights.append(Night(session: session, id: HealthExport.sleepID(session),
                                fingerprint: HealthExport.fingerprint(intervals), intervals: intervals,
                                hrv: HealthExport.nightlySDNN(for: session, minutes: minutes, segments: segments)))
        }
        return (try await writeNights(nights), try await writeHRV(nights))
    }

    /// A late sync can move a night's edges, so everything Pulse wrote around the changed nights is
    /// replaced together. Otherwise a sliver of the old version would stay behind.
    private func writeNights(_ nights: [Night]) async throws -> Int {
        let changed = nights.filter { ledger.needsWrite($0.id, fingerprint: $0.fingerprint) }
        guard canWrite(sleepType), let first = changed.map(\.session.start).min(),
              let last = changed.map(\.session.end).max() else { return 0 }
        let from = first.addingTimeInterval(-3600)
        let to = last.addingTimeInterval(3600)
        let earlierInstall = await idsFromEarlierInstalls(of: sleepType, from: from, to: to)
        try await deleteOwnSamples(of: sleepType, from: from, to: to)

        var written = 0
        for night in nights where night.session.end > from && night.session.start < to {
            let prefix = night.id + "."
            if !earlierInstall.contains(where: { $0.hasPrefix(prefix) }) {
                let version = Int(Date.now.timeIntervalSince1970)
                let samples = night.intervals.enumerated().map { index, interval in
                    HKCategorySample(type: sleepType, value: Self.value(for: interval.kind).rawValue,
                                     start: interval.start, end: interval.end,
                                     metadata: Self.metadata(id: prefix + String(index), version: version))
                }
                try await store.save(samples)
                samplesThisExport += samples.count
                if changed.contains(where: { $0.id == night.id }) { written += 1 }
            }
            ledger.record(night.id, fingerprint: night.fingerprint, at: .now)
        }
        return written
    }

    private func writeHRV(_ nights: [Night]) async throws -> Int {
        guard canWrite(hrvType) else { return 0 }
        var written = 0
        for point in nights.compactMap(\.hrv) {
            let fingerprint = String(format: "%.1f", point.sdnnMs)
            guard ledger.needsWrite(point.syncID, fingerprint: fingerprint) else { continue }
            let earlierInstall = await idsFromEarlierInstalls(of: hrvType, from: point.start, to: point.end)
            if !earlierInstall.contains(point.syncID) {
                try await deleteOwnSamples(of: hrvType, from: point.start, to: point.end)
                let quantity = HKQuantity(unit: .secondUnit(with: .milli), doubleValue: point.sdnnMs)
                try await store.save(HKQuantitySample(type: hrvType, quantity: quantity, start: point.start, end: point.end,
                                                      metadata: Self.metadata(id: point.syncID)))
                samplesThisExport += 1
                written += 1
            }
            ledger.record(point.syncID, fingerprint: fingerprint, at: .now)
        }
        return written
    }

    // MARK: - Resting heart rate

    private func writeRestingHeartRates(_ days: [DailySummary]) async throws -> Int {
        guard canWrite(restingType) else { return 0 }
        var written = 0
        for day in days {
            guard let value = day.restingHeartRate?.rounded() else { continue }
            let end = min(day.date.addingTimeInterval(86_400), .now)
            let id = HealthExport.restingID(day)
            let fingerprint = String(Int(value))
            guard end > day.date, ledger.needsWrite(id, fingerprint: fingerprint) else { continue }
            let earlierInstall = await idsFromEarlierInstalls(of: restingType, from: day.date, to: end)
            if !earlierInstall.contains(id) {
                try await deleteOwnSamples(of: restingType, from: day.date, to: end)
                try await store.save(HKQuantitySample(type: restingType, quantity: HKQuantity(unit: bpm, doubleValue: value),
                                                      start: day.date, end: end, metadata: Self.metadata(id: id)))
                samplesThisExport += 1
                written += 1
            }
            ledger.record(id, fingerprint: fingerprint, at: .now)
        }
        return written
    }

    // MARK: - Workouts

    private func writeWorkouts(_ workouts: [Workout], records: [WorkoutRecord]) async throws -> Int {
        guard canWrite(workoutType) else { return 0 }
        var written = 0
        for workout in workouts where workout.end > workout.start {
            let id = HealthExport.workoutID(workout)
            let fingerprint = HealthExport.fingerprint(workout)
            guard ledger.needsWrite(id, fingerprint: fingerprint) else { continue }
            try await deleteOwnSamples(of: workoutType, from: workout.start, to: workout.end)
            let others = await samples(of: workoutType, from: workout.start, to: workout.end)
                .filter(Self.isFromAnotherApp)
                .map { DateInterval(start: $0.startDate, end: $0.endDate) }
            if !HealthExport.isAlreadyRecorded(workout, by: others) {
                try await write(workout, id: id)
                samplesThisExport += 1
                records.first { $0.id == workout.id }?.healthKitID = workout.id
                written += 1
            }
            ledger.record(id, fingerprint: fingerprint, at: .now)
        }
        return written
    }

    /// Type, start and end only. No energy is added, so a workout never writes active energy.
    private func write(_ workout: Workout, id: String) async throws {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = Self.activityType(for: workout.kind)
        let builder = HKWorkoutBuilder(healthStore: store, configuration: configuration, device: nil)
        try await builder.beginCollection(at: workout.start)
        try await builder.addMetadata(Self.metadata(id: id))
        try await builder.endCollection(at: workout.end)
        _ = try await builder.finishWorkout()
    }

    // MARK: - Heart rate

    /// One sample per worn minute, a day at a time. Picks up where the last export stopped.
    private func writeHeartRate(reader: HealthMinuteReader, dataStart: Date?) async throws -> Int {
        guard canWrite(heartRateType) else {
            ledger.exportedThrough = .now
            return 0
        }
        let lower = [ledger.heartRateFrom, dataStart].compactMap { $0 }.max() ?? .distantPast
        guard let range = try await reader.range(from: lower) else { return 0 }
        let isFirstExport = ledger.exportedThrough == nil
        var written = 0
        var from = range.first
        while from <= range.last {
            try Task.checkCancellation()
            let to = from.addingTimeInterval(86_400)
            var points = HealthExport.heartRatePoints(minutes: try await reader.minutes(from: from, to: to),
                                                      dataStart: dataStart)
            if isFirstExport, !points.isEmpty {
                let earlierInstall = await idsFromEarlierInstalls(of: heartRateType, from: from, to: to)
                points.removeAll { earlierInstall.contains($0.syncID) }
            }
            let samples = points.map { point in
                HKQuantitySample(type: heartRateType, quantity: HKQuantity(unit: bpm, doubleValue: Double(point.bpm)),
                                 start: point.start, end: point.end,
                                 metadata: Self.metadata(id: point.syncID, version: point.readings))
            }
            for index in stride(from: 0, to: samples.count, by: Self.saveChunk) {
                try await store.save(Array(samples[index..<min(index + Self.saveChunk, samples.count)]))
                samplesThisExport += min(Self.saveChunk, samples.count - index)
            }
            written += samples.count
            ledger.exportedThrough = min(to, range.last)
            saveLedger()
            from = to
        }
        return written
    }

    // MARK: - Reading back (only to avoid duplicates)

    private func samples(of type: HKSampleType, from start: Date, to end: Date,
                         matching extra: NSPredicate? = nil) async -> [HKSample] {
        var parts = [HKQuery.predicateForSamples(withStart: start, end: end, options: [])]
        if let extra { parts.append(extra) }
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: parts)
        let query = HKSampleQueryDescriptor<HKSample>(predicates: [.sample(type: type, predicate: predicate)],
                                                      sortDescriptors: [])
        // Without read permission this is empty, and Pulse's own sync identifiers still apply.
        return (try? await query.result(for: store)) ?? []
    }

    /// Export IDs of samples an earlier install of Pulse wrote (a different source to Apple Health).
    private func idsFromEarlierInstalls(of type: HKSampleType, from start: Date, to end: Date) async -> Set<String> {
        let tagged = HKQuery.predicateForObjects(withMetadataKey: Self.exportIDKey)
        let found = await samples(of: type, from: start, to: end, matching: tagged)
        return Set(found.filter(Self.isFromAnotherApp).compactMap { $0.metadata?[Self.exportIDKey] as? String })
    }

    private static func isFromAnotherApp(_ sample: HKSample) -> Bool {
        sample.sourceRevision.source.bundleIdentifier != HKSource.default().bundleIdentifier
    }

    /// Deletes what this install of Pulse wrote earlier in this time span. Samples from other apps
    /// and devices are never touched (the predicate is limited to this app as the source).
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

    // MARK: - Small helpers

    /// - Parameter version: Apple Health keeps the sample with the highest version for a sync
    ///   identifier. By default the time of writing, so the newest calculation wins.
    private static func metadata(id: String, version: Int = Int(Date.now.timeIntervalSince1970)) -> [String: Any] {
        [HKMetadataKeySyncIdentifier: id, HKMetadataKeySyncVersion: NSNumber(value: version), exportIDKey: id]
    }

    private static func loadLedger() -> HealthLedger {
        guard let data = UserDefaults.standard.data(forKey: ledgerKey),
              let ledger = try? JSONDecoder().decode(HealthLedger.self, from: data) else { return HealthLedger() }
        return ledger
    }

    private func saveLedger() {
        guard let data = try? JSONEncoder().encode(ledger) else { return }
        UserDefaults.standard.set(data, forKey: Self.ledgerKey)
    }

    private static func value(for kind: HealthExport.SleepKind) -> HKCategoryValueSleepAnalysis {
        switch kind {
        case .inBed: .inBed
        case .awake: .awake
        case .core: .asleepCore
        case .deep: .asleepDeep
        case .asleep: .asleepUnspecified
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

/// Reads raw minutes off the main thread, so a long export never freezes the screen.
@ModelActor
actor HealthMinuteReader {
    func minutes(from start: Date, to end: Date) throws -> [MinuteSample] {
        let descriptor = FetchDescriptor<MinuteRecord>(
            predicate: #Predicate<MinuteRecord> { $0.start >= start && $0.start < end },
            sortBy: [SortDescriptor(\.start)])
        return try modelContext.fetch(descriptor).map(\.value)
    }

    /// The first and last stored minute at or after `lower`. nil when there are none.
    func range(from lower: Date) throws -> (first: Date, last: Date)? {
        var oldest = FetchDescriptor<MinuteRecord>(predicate: #Predicate<MinuteRecord> { $0.start >= lower },
                                                   sortBy: [SortDescriptor(\.start)])
        oldest.fetchLimit = 1
        var newest = FetchDescriptor<MinuteRecord>(predicate: #Predicate<MinuteRecord> { $0.start >= lower },
                                                   sortBy: [SortDescriptor(\.start, order: .reverse)])
        newest.fetchLimit = 1
        guard let first = try modelContext.fetch(oldest).first?.start,
              let last = try modelContext.fetch(newest).first?.start else { return nil }
        return (first, last)
    }
}
