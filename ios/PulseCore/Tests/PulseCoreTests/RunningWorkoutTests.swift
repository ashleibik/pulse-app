import Foundation
import Testing
@testable import PulseCore

// A workout started in the app and not finished yet (DESIGN.md §4b-4, docs/METRICS.md §10).

private let started = Date(timeIntervalSince1970: 1_795_000_000)

@Test func aRunningWorkoutSurvivesBeingStored() throws {
    let workout = RunningWorkout(start: started, kind: .strength)
    let data = try #require(workout.encoded())
    #expect(RunningWorkout(data: data) == workout)
}

@Test func anUnreadableStoredWorkoutMeansNoneIsRunning() {
    #expect(RunningWorkout(data: Data()) == nil)
    #expect(RunningWorkout(data: Data("{\"start\":1}".utf8)) == nil)
    #expect(RunningWorkout(data: Data("{\"start\":0,\"kind\":\"yoga\"}".utf8)) == nil)
}

@Test func changingTheTypeKeepsTheStart() throws {
    var workout = RunningWorkout(start: started, kind: .run)
    workout.kind = .ride
    let data = try #require(workout.encoded())
    let stored = try #require(RunningWorkout(data: data))
    #expect(stored.kind == .ride)
    #expect(stored.start == started)
}

@Test func foundWorkoutsAreLeftOutFromTheRunningWorkoutsStart() {
    let workout = RunningWorkout(start: started, kind: .run)
    // Ended before it started: kept.
    #expect(!workout.overlaps(start: started.addingTimeInterval(-3600), end: started.addingTimeInterval(-60)))
    #expect(!workout.overlaps(start: started.addingTimeInterval(-3600), end: started))
    // Runs into it, lies inside it, or starts later: it has no end yet, so all are left out.
    #expect(workout.overlaps(start: started.addingTimeInterval(-600), end: started.addingTimeInterval(60)))
    #expect(workout.overlaps(start: started.addingTimeInterval(600), end: started.addingTimeInterval(1200)))
    #expect(workout.overlaps(start: started.addingTimeInterval(86_400), end: started.addingTimeInterval(90_000)))
}

@Test func theRunningTimeReadsHoursMinutesSeconds() {
    let workout = RunningWorkout(start: started, kind: .run)
    #expect(workout.elapsedText(at: started) == "0:00:00")
    #expect(workout.elapsedText(at: started.addingTimeInterval(59)) == "0:00:59")
    #expect(workout.elapsedText(at: started.addingTimeInterval(754)) == "0:12:34")
    #expect(workout.elapsedText(at: started.addingTimeInterval(3 * 3600 + 5 * 60 + 9)) == "3:05:09")
    // A phone clock set back never shows a negative time.
    #expect(workout.elapsedText(at: started.addingTimeInterval(-30)) == "0:00:00")
}
