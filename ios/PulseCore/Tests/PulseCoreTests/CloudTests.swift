import Foundation
import Testing
@testable import PulseCore

// What leaves the phone: the Strava upload file (Phase 7) and the cloud rows (Phase 8).

private let workoutStart = Date(timeIntervalSince1970: 1_750_000_020)     // a whole minute, 15:07:00 UTC

private func sampleWorkout(_ source: DataSource = .history, kind: WorkoutKind = .run) -> Workout {
    Workout(id: UUID(uuidString: "11111111-2222-4333-8444-555555555555")!, kind: kind, start: workoutStart,
            end: workoutStart.addingTimeInterval(120), averageHeartRate: 150, maxHeartRate: 171,
            strain: 9.44, zoneSeconds: [0, 0, 60, 60, 0], calories: 30, source: source)
}

private func minute(_ index: Int, hr: UInt8) -> MinuteSample {
    MinuteSample(start: workoutStart.addingTimeInterval(Double(index) * 60), heartRate: [UInt8](repeating: hr, count: 60),
                 rrIntervalsMs: [], activity: [UInt8](repeating: 60, count: 60), source: .history)
}

@Test func simulatedWorkoutsAreNeverUploadedToStrava() {
    #expect(!StravaExport.canUpload(sampleWorkout(.simulated)))
    #expect(StravaExport.canUpload(sampleWorkout(.history)))
    #expect(dataset.workouts.allSatisfy { !StravaExport.canUpload($0) })
}

@Test func tcxHasTheWorkoutAndOnlyItsHeartRate() {
    var gap = minute(1, hr: 160)
    gap.heartRate[5] = 0                                         // one second without a reading
    // Minute -1 and minute 2 are outside the workout and must not appear.
    let tcx = StravaExport.tcx(for: sampleWorkout(), minutes: [minute(2, hr: 99), gap, minute(0, hr: 140), minute(-1, hr: 98)])

    #expect(tcx.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<TrainingCenterDatabase"))
    #expect(tcx.contains("<Activity Sport=\"Running\">"))
    #expect(tcx.contains("<Id>2025-06-15T15:07:00Z</Id>"))
    #expect(tcx.contains("<TotalTimeSeconds>120</TotalTimeSeconds>"))
    #expect(tcx.contains("<MaximumHeartRateBpm><Value>171</Value></MaximumHeartRateBpm>"))
    #expect(tcx.contains("<Calories>0</Calories>"))               // our calorie guess is not sent
    #expect(tcx.contains("Strain 9.4 of 21."))

    let points = tcx.components(separatedBy: "<Trackpoint>").count - 1
    #expect(points == 23)                                         // 2 minutes, one point per 5 s, minus the gap
    #expect(!tcx.contains("<Value>99</Value>") && !tcx.contains("<Value>98</Value>") && !tcx.contains("<Value>0</Value>"))
    #expect(tcx.contains("<Time>2025-06-15T15:07:00Z</Time><HeartRateBpm><Value>140</Value>"))
    #expect(tcx.contains("<Time>2025-06-15T15:08:55Z</Time><HeartRateBpm><Value>160</Value>"))
}

@Test func stravaNamesAndIDs() {
    #expect(StravaExport.externalID(for: sampleWorkout()) == "pulse-11111111-2222-4333-8444-555555555555")
    #expect(StravaExport.name(for: sampleWorkout(), calendar: utcCalendar) == "Afternoon run")
    #expect(StravaExport.tcxSport(.ride) == "Biking" && StravaExport.tcxSport(.strength) == "Other")
    #expect(StravaExport.escape("a < b & c") == "a &lt; b &amp; c")
}

@Test func cloudRowsUseTheDatabaseColumnNamesAndCarryTheSource() throws {
    let day = try #require(computed.days.last)
    let row = CloudRows.day(day, calendar: utcCalendar)
    #expect(row.source == "simulated")                            // the server tells Claude it is demo data
    #expect(row.day.count == 10 && row.day.contains("-"))
    #expect(row.algorithm_version == MetricsEngine.algorithmVersion)
    if let recovery = row.recovery_pct {
        #expect(recovery == (recovery * 10).rounded() / 10)       // one decimal, no noise
        #expect(row.recovery_word != nil)
    }

    let json = try #require(String(data: JSONEncoder().encode(row), encoding: .utf8))
    for key in ["\"day\"", "\"day_strain\"", "\"sleep_need_minutes\"", "\"source\"", "\"algorithm_version\""] {
        #expect(json.contains(key), "missing \(key)")
    }
    #expect(!json.contains("user_id"))                            // filled in by the database, never by the app

    let workout = CloudRows.workout(sampleWorkout())
    #expect(workout.start_at == "2025-06-15T15:07:00Z" && workout.strain == 9.4 && workout.kind == "run")
}

@Test func cloudSleepRowsKeepTheSameIDAcrossRecalculations() {
    let end = Date(timeIntervalSince1970: 1_750_030_020)
    let first = SleepSession(start: end.addingTimeInterval(-25_000), end: end, asleepMinutes: 400, awakeMinutes: 16,
                             disturbances: 3, source: .history)
    let again = SleepSession(start: end.addingTimeInterval(-25_300), end: end, asleepMinutes: 404, awakeMinutes: 17,
                             disturbances: 3, source: .history)
    #expect(first.id != again.id)                                 // the engine hands out new ids each run
    #expect(CloudRows.sleep(first).id == CloudRows.sleep(again).id)
}
