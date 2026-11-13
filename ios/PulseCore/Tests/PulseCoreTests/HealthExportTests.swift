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

@Test func sleepIntervalsMergeRestfulAndLightIntoAsleep() {
    let session = sleep(.history, start: 0, end: 100)
    let segments = [
        SleepSegment(start: date(0), end: date(30), phase: .light),
        SleepSegment(start: date(30), end: date(60), phase: .restful),
        SleepSegment(start: date(60), end: date(65), phase: .awake),
        SleepSegment(start: date(65), end: date(100), phase: .light),
    ]
    let intervals = HealthExport.sleepIntervals(for: session, segments: segments)
    #expect(intervals == [
        HealthExport.SleepInterval(start: date(0), end: date(100), kind: .inBed),
        HealthExport.SleepInterval(start: date(0), end: date(60), kind: .asleep),     // light + restful
        HealthExport.SleepInterval(start: date(60), end: date(65), kind: .awake),
        HealthExport.SleepInterval(start: date(65), end: date(100), kind: .asleep),
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
