import Foundation
import Testing
@testable import PulseCore

// Rules for what may be written to Apple Health (see HealthExport.swift).

private func date(_ minutes: Double) -> Date { Date(timeIntervalSince1970: 1_750_000_020 + minutes * 60) }

private func sleep(_ source: DataSource, start: Double = 0, end: Double = 420) -> SleepSession {
    SleepSession(start: date(start), end: date(end), asleepMinutes: 400, awakeMinutes: 20, disturbances: 2, source: source)
}

private func workout(_ source: DataSource, start: Double) -> Workout {
    Workout(kind: .run, start: date(start), end: date(start + 40), averageHeartRate: 150, maxHeartRate: 170,
            strain: 10, zoneSeconds: [0, 0, 600, 1200, 600], calories: 400, source: source)
}

@Test func simulatedDataIsNeverExportedToAppleHealth() {
    #expect(!HealthExport.isExportable(.simulated))
    #expect(HealthExport.isExportable(.history) && HealthExport.isExportable(.live) && HealthExport.isExportable(.manual))

    let plan = HealthExport.plan(sleeps: [sleep(.simulated), sleep(.history, start: 1500, end: 1900)],
                                 workouts: [workout(.simulated, start: 600), workout(.history, start: 2000)],
                                 days: computed.days)
    #expect(plan.sleeps.count == 1 && plan.sleeps[0].source == .history)
    #expect(plan.workouts.count == 1 && plan.workouts[0].source == .history)
    // The whole demo month is simulated: none of its days may be written.
    #expect(computed.days.allSatisfy { $0.source == .simulated })
    #expect(plan.restingDays.isEmpty)

    let demoOnly = HealthExport.plan(sleeps: dataset.sleeps, workouts: dataset.workouts, days: computed.days)
    #expect(demoOnly.isEmpty)
}

@Test func exportPlanOnlyTakesRecentItemsWhenAsked() {
    let plan = HealthExport.plan(sleeps: [sleep(.history, start: 0, end: 400), sleep(.history, start: 3000, end: 3400)],
                                 workouts: [workout(.history, start: 100), workout(.history, start: 3500)],
                                 days: [], since: date(2000))
    #expect(plan.sleeps.map(\.start) == [date(3000)])
    #expect(plan.workouts.map(\.start) == [date(3500)])
}

private let nightSegments = [
    SleepSegment(start: date(0), end: date(30), phase: .light),
    SleepSegment(start: date(30), end: date(60), phase: .restful),
    SleepSegment(start: date(60), end: date(65), phase: .awake),
    SleepSegment(start: date(65), end: date(100), phase: .light),
]

@Test func byDefaultSleepIsOnlyAsleepAndAwake() {
    let intervals = HealthExport.sleepIntervals(for: sleep(.history, start: 0, end: 100), segments: nightSegments)
    #expect(intervals == [
        HealthExport.SleepInterval(start: date(0), end: date(100), kind: .inBed),
        HealthExport.SleepInterval(start: date(0), end: date(60), kind: .asleep),     // light + restful
        HealthExport.SleepInterval(start: date(60), end: date(65), kind: .awake),
        HealthExport.SleepInterval(start: date(65), end: date(100), kind: .asleep),
    ])
}

@Test func theStagesSettingMapsLightToCoreAndRestfulToDeepAndNeverClaimsREM() {
    let session = sleep(.history, start: 0, end: 100)
    let intervals = HealthExport.sleepIntervals(for: session, segments: nightSegments, writeStages: true)
    #expect(intervals == [
        HealthExport.SleepInterval(start: date(0), end: date(100), kind: .inBed),
        HealthExport.SleepInterval(start: date(0), end: date(30), kind: .core),
        HealthExport.SleepInterval(start: date(30), end: date(60), kind: .deep),
        HealthExport.SleepInterval(start: date(60), end: date(65), kind: .awake),
        HealthExport.SleepInterval(start: date(65), end: date(100), kind: .core),
    ])
}

@Test func sleepIntervalsStayInsideTheSessionAndWorkWithoutATimeline() {
    let session = sleep(.history, start: 10, end: 90)
    let overhanging = [SleepSegment(start: date(0), end: date(120), phase: .restful)]
    #expect(HealthExport.sleepIntervals(for: session, segments: overhanging) == [
        HealthExport.SleepInterval(start: date(10), end: date(90), kind: .inBed),
        HealthExport.SleepInterval(start: date(10), end: date(90), kind: .asleep),
    ])
    // No raw minutes for that night: the session itself is the only fact we have.
    #expect(HealthExport.sleepIntervals(for: session, segments: []) == [
        HealthExport.SleepInterval(start: date(10), end: date(90), kind: .inBed),
        HealthExport.SleepInterval(start: date(10), end: date(90), kind: .asleep),
    ])
}

// MARK: - Data cutoff

@Test func nothingFromBeforeTheDataCutoffIsExportedExceptHandAddedWorkouts() {
    let plan = HealthExport.plan(sleeps: [sleep(.history, start: 0, end: 400), sleep(.history, start: 3000, end: 3400)],
                                 workouts: [workout(.history, start: 100), workout(.manual, start: 200), workout(.history, start: 3500)],
                                 days: [], dataStart: date(2000))
    #expect(plan.sleeps.map(\.start) == [date(3000)])
    #expect(plan.workouts.map(\.start) == [date(200), date(3500)])

    let early = minute(at: 0, bpm: 60), late = minute(at: 3000, bpm: 60)
    #expect(HealthExport.heartRatePoints(minutes: [early, late], dataStart: date(2000)).map(\.start) == [date(3000)])
}

// MARK: - Heart rate

private func minute(at minutes: Double, bpm: UInt8, seconds: Int = 60, rr: [UInt16] = [],
                    source: DataSource = .history) -> MinuteSample {
    var heartRate = [UInt8](repeating: 0, count: 60)
    for second in 0..<seconds { heartRate[second] = bpm }
    return MinuteSample(start: date(minutes), heartRate: heartRate, rrIntervalsMs: rr,
                        activity: [UInt8](repeating: 0, count: 60), source: source)
}

@Test func heartRateUsesOnlyRealReadingsAndSkipsEmptyAndSimulatedMinutes() {
    let points = HealthExport.heartRatePoints(minutes: [
        minute(at: 2, bpm: 70, seconds: 30),
        minute(at: 0, bpm: 60),
        minute(at: 1, bpm: 0, seconds: 0),                  // off the wrist
        minute(at: 3, bpm: 90, source: .simulated),
    ])
    #expect(points.map(\.bpm) == [60, 70])
    #expect(points.map(\.readings) == [60, 30])
    #expect(points[0].end == date(1))
}

@Test func aMinuteKeepsItsSyncIDAndGainsAVersionWhenMoreSecondsArrive() {
    let partial = HealthExport.heartRatePoints(minutes: [minute(at: 0, bpm: 60, seconds: 20)])[0]
    let full = HealthExport.heartRatePoints(minutes: [minute(at: 0, bpm: 62)])[0]
    #expect(partial.syncID == full.syncID)
    #expect(full.readings > partial.readings)
}

// MARK: - HRV (SDNN)

/// A still night of steady minutes whose beats alternate around 1000 ms.
private func beatingMinutes(count: Int, rr: [UInt16]) -> [MinuteSample] {
    (0..<count).map { minute(at: Double($0), bpm: 60, rr: rr) }
}

@Test func sdnnIsTheSampleStandardDeviationOfTheCleanBeats() throws {
    let beats: [Double?] = (0..<200).map { $0 % 2 == 0 ? 980 : 1020 }
    let value = try #require(HRV.sdnn(beats))
    #expect(abs(value - 20.05) < 0.01)
    #expect(HRV.sdnn(Array(beats.prefix(50))) == nil)          // too few beats to mean anything
}

@Test func nightlySDNNComesFromAsleepBeatsOnly() throws {
    let session = sleep(.history, start: 0, end: 30)
    let rr = (0..<60).map { UInt16($0 % 2 == 0 ? 980 : 1020) }
    let asleep = [SleepSegment(start: date(0), end: date(30), phase: .light)]
    let point = try #require(HealthExport.nightlySDNN(for: session, minutes: beatingMinutes(count: 30, rr: rr), segments: asleep))
    #expect(abs(point.sdnnMs - 20) < 0.5)
    #expect(point.start == session.start && point.end == session.end)

    let awake = [SleepSegment(start: date(0), end: date(30), phase: .awake)]
    #expect(HealthExport.nightlySDNN(for: session, minutes: beatingMinutes(count: 30, rr: rr), segments: awake) == nil)
}

@Test func noHRVIsInventedWithoutBeatsOrForNapsAndSimulatedNights() {
    let asleep = [SleepSegment(start: date(0), end: date(30), phase: .light)]
    let rr = (0..<60).map { UInt16($0 % 2 == 0 ? 980 : 1020) }
    let minutes = beatingMinutes(count: 30, rr: rr)
    #expect(HealthExport.nightlySDNN(for: sleep(.history, start: 0, end: 30), minutes: beatingMinutes(count: 30, rr: []), segments: asleep) == nil)
    #expect(HealthExport.nightlySDNN(for: sleep(.simulated, start: 0, end: 30), minutes: minutes, segments: asleep) == nil)
    let nap = SleepSession(start: date(0), end: date(30), asleepMinutes: 30, awakeMinutes: 0, disturbances: 0, isNap: true, source: .history)
    #expect(HealthExport.nightlySDNN(for: nap, minutes: minutes, segments: asleep) == nil)
}

// MARK: - No duplicates

@Test func aWorkoutTheAppleWatchAlreadyRecordedIsNotWrittenAgain() {
    let band = workout(.history, start: 100)                   // 40 minutes
    #expect(HealthExport.isAlreadyRecorded(band, by: [DateInterval(start: date(95), end: date(135))]))
    #expect(HealthExport.isAlreadyRecorded(band, by: [DateInterval(start: date(120), end: date(130))]))     // short one inside
    #expect(!HealthExport.isAlreadyRecorded(band, by: [DateInterval(start: date(135), end: date(180))]))    // 5 min overlap
    #expect(!HealthExport.isAlreadyRecorded(band, by: [DateInterval(start: date(200), end: date(240))]))
    #expect(!HealthExport.isAlreadyRecorded(band, by: []))
}

@Test func theLedgerSkipsWhatDidNotChange() {
    var ledger = HealthLedger()
    #expect(ledger.needsWrite("night", fingerprint: "a"))
    ledger.record("night", fingerprint: "a", at: date(0))
    #expect(!ledger.needsWrite("night", fingerprint: "a"))
    #expect(ledger.needsWrite("night", fingerprint: "b"))      // a late sync changed the night
}

@Test func theLedgerRemembersHowFarHeartRateGotAndSurvivesARestart() throws {
    var ledger = HealthLedger()
    #expect(ledger.heartRateFrom == nil && ledger.recheckFrom == nil)   // first export: everything
    ledger.exportedThrough = date(1000)
    ledger.record("night", fingerprint: "a", at: date(1000))
    #expect(ledger.heartRateFrom == date(985))
    #expect(ledger.recheckFrom == date(1000 - 3 * 1440))

    let restored = try JSONDecoder().decode(HealthLedger.self, from: JSONEncoder().encode(ledger))
    #expect(restored == ledger)
    #expect(!restored.needsWrite("night", fingerprint: "a"))
}

@Test func theLedgerForgetsOnlyOldEntries() {
    var ledger = HealthLedger()
    ledger.record("old", fingerprint: "a", at: date(0))
    ledger.record("new", fingerprint: "a", at: date(50_000))
    ledger.prune(now: date(50_000))
    #expect(ledger.needsWrite("old", fingerprint: "a"))
    #expect(!ledger.needsWrite("new", fingerprint: "a"))
}

@Test func fingerprintsAreStableAndNoticeChanges() {
    #expect(HealthExport.fingerprint("night") == HealthExport.fingerprint("night"))
    #expect(HealthExport.fingerprint("night") != HealthExport.fingerprint("nighT"))
    let a = [HealthExport.SleepInterval(start: date(0), end: date(10), kind: .core)]
    let b = [HealthExport.SleepInterval(start: date(0), end: date(10), kind: .deep)]
    #expect(HealthExport.fingerprint(a) != HealthExport.fingerprint(b))
}
