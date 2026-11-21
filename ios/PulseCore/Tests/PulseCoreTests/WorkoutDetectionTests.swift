import Foundation
import Testing
@testable import PulseCore

// Workouts found by themselves (docs/METRICS.md §10), zones and active calories. Made-up minutes: a hard session at 155 bpm,
// an easy walk at 95 bpm, and the band's step count for walks and runs.

private let start = Date(timeIntervalSince1970: 1_790_000_040)
private let owner = DailyCalories.Body(weightKg: 80, heightCm: 180, age: 30, sex: .male)
private let profile = MetricsProfile(maxHeartRate: 190)

private func moment(_ minute: Double) -> Date { start.addingTimeInterval(minute * 60) }

private func minutes(_ from: Int, _ to: Int, rate: (Int) -> UInt8, motion: (Int) -> UInt8) -> [MinuteSample] {
    (from..<to).map { index in
        MinuteSample(start: moment(Double(index)), heartRate: (0..<60).map { rate(index * 60 + $0) }, rrIntervalsMs: [],
                     activity: (0..<60).map { motion(index * 60 + $0) }, source: .history)
    }
}

private func quiet(_ from: Int, _ to: Int) -> [MinuteSample] {
    minutes(from, to, rate: { 62 + UInt8($0 / 60 % 5) }, motion: { $0 % 7 == 0 ? 6 : 3 })
}

/// Sets and rests: heart rate climbs to about 163 during a set and falls back to about 95 between them.
private func strengthSession(_ from: Int, _ to: Int) -> [MinuteSample] {
    minutes(from, to, rate: { second in
        let phase = Double(second % 240) / 240
        return UInt8(phase < 0.35 ? 95 + 68 * (phase / 0.35) : 163 - 68 * ((phase - 0.35) / 0.65))
    }, motion: { $0 % 240 < 80 ? ($0 % 3 == 0 ? 70 : 20) : 3 })
}

/// A hard session: 155 bpm (zone 2 and up for resting 55 and max 190) with strong arm movement (over NOOP's 0.20 g).
private func hardSession(_ from: Int, _ to: Int) -> [MinuteSample] {
    minutes(from, to, rate: { _ in 155 }, motion: { $0 % 2 == 0 ? 150 : 110 })
}

/// An easy walk: 95 bpm with the same movement. NOOP calls it no workout; the band's steps can.
private func easyWalk(_ from: Int, _ to: Int) -> [MinuteSample] {
    minutes(from, to, rate: { _ in 95 }, motion: { $0 % 2 == 0 ? 150 : 110 })
}

/// The band's count: `perMinute` steps in each minute from `from` to `to`.
private func steps(_ from: Int, _ to: Int, _ perMinute: Int) -> [StepMinute] {
    (from..<to).map { StepMinute(start: moment(Double($0)), steps: perMinute, seconds: 60) }
}

private func detect(_ list: [MinuteSample], steps: [StepMinute] = [], body: DailyCalories.Body? = owner) -> [Workout] {
    WorkoutDetector.detect(minutes: list, steps: steps, profile: profile, body: body) { _ in 55 }
}

// MARK: - Detection

@Test func aHardSessionIsRecordedWithoutAsking() throws {
    let workouts = detect(quiet(0, 30) + hardSession(30, 60) + quiet(60, 90))
    #expect(workouts.count == 1)
    let workout = try #require(workouts.first)
    #expect(abs(workout.start.timeIntervalSince(moment(30))) <= 60)
    #expect(abs(workout.end.timeIntervalSince(moment(60))) <= 60)
    #expect(workout.isSuggestion == nil)
    #expect(workout.source == .history)
    #expect(workout.averageHeartRate == 155)
}

@Test func anEasyWalkByHeartRateAloneIsNotAWorkout() {
    // Without the band's steps, 95 bpm with moving arms could be housework: NOOP needs zone 2 and up.
    #expect(detect(quiet(0, 30) + easyWalk(30, 60) + quiet(60, 90)).isEmpty)
}

@Test func aStillWristIsNeverAWorkout() {
    let desk = minutes(30, 60, rate: { _ in 155 }, motion: { _ in 4 })
    #expect(detect(quiet(0, 30) + desk + quiet(60, 90)).isEmpty)
}

@Test func aWalkIsRecordedFromTheBandsSteps() throws {
    let workouts = detect(quiet(0, 30) + easyWalk(30, 50) + quiet(50, 80), steps: steps(30, 50, 105))
    #expect(workouts.count == 1)
    let walk = try #require(workouts.first)
    #expect(walk.kind == .walk && walk.isSuggestion == nil)
    #expect(walk.start == moment(30) && walk.end == moment(50))
    // At least the ACSM cost of 2,100 steps: 0.0005 × 2,100 × 0.747 m × 80 kg = 62.7 kcal.
    #expect(walk.calories >= 62)
}

@Test func aRunIsTypedFromTheBandsCadence() throws {
    let workouts = detect(quiet(0, 30) + hardSession(30, 55) + quiet(55, 80), steps: steps(30, 55, 165))
    #expect(workouts.count == 1, "the run and its steps are one workout")
    #expect(try #require(workouts.first).kind == .run)
}

@Test func aHardSessionWithoutStepsIsTypedByNoopsClassifier() throws {
    let workout = try #require(detect(quiet(0, 30) + hardSession(30, 60) + quiet(60, 90), steps: steps(30, 60, 5)).first)
    #expect(workout.kind != .walk && workout.kind != .run)
}

@Test func aShortWalkIsNotAWorkout() {
    #expect(detect(quiet(0, 30) + easyWalk(30, 38) + quiet(38, 60), steps: steps(30, 38, 105)).isEmpty)
}

@Test func pausesOfUpToTwoMinutesStayInsideOneWalk() throws {
    let list = quiet(0, 30) + easyWalk(30, 50) + quiet(50, 80)
    let withPause = steps(30, 36, 105) + steps(38, 44, 105)
    let walk = try #require(detect(list, steps: withPause).first)
    #expect(walk.start == moment(30) && walk.end == moment(44))
    // A three-minute pause splits it into two walks of 6 minutes: too short.
    #expect(detect(list, steps: steps(30, 36, 105) + steps(39, 45, 105)).isEmpty)
}

@Test func aStepRunIsARunAtRunningCadence() throws {
    // Running with the heart rate still low (the first minutes): found from the steps alone.
    let list = quiet(0, 30) + easyWalk(30, 45) + quiet(45, 70)
    let run = try #require(detect(list, steps: steps(30, 45, 160)).first)
    #expect(run.kind == .run)
}

// MARK: - Zones

@Test func zonesUseHeartRateReserveAndMyRestingHeartRate() throws {
    let zones = try #require(OpenStrapZones.reserve(restingHistory: [55], maxHeartRate: 190))
    #expect(zones.lowerLimits == [122.5, 136, 149.5, 163, 176.5])
    #expect(zones.zone(for: 122) == nil)
    #expect(zones.zone(for: 130) == 0)
    #expect(zones.zone(for: 150) == 2)
    #expect(zones.zone(for: 200) == 4)
}

@Test func theRestingHeartRateIsTheMedianOfRecentNights() throws {
    let zones = try #require(OpenStrapZones.reserve(restingHistory: [50, 55, 90], maxHeartRate: 190))
    #expect(zones.lowerLimits[0] == 122.5)
    #expect(OpenStrapZones.reserve(restingHistory: [], maxHeartRate: 190) == nil)
    #expect(OpenStrapZones.reserve(restingHistory: [200], maxHeartRate: 190) == nil)
}

@Test func withoutARestingHeartRateZonesFallBackToAShareOfMax() {
    let zones = OpenStrapZones.zones(restingHistory: [], maxHeartRate: 200)
    #expect(zones.lowerLimits == [100, 120, 140, 160, 180] && !zones.usesReserve)
}

@Test func shortPeaksAreCountedInTheirZone() throws {
    // A minute averaging 120 that holds 150 for 20 seconds. Minute averages would lose the peak.
    let minute = minutes(0, 1, rate: { $0 < 20 ? 150 : 105 }, motion: { _ in 3 })
    let zones = try #require(OpenStrapZones.reserve(restingHistory: [55], maxHeartRate: 190))
    #expect(OpenStrapZones.secondsInZones(minute, zones: zones) == [0, 0, 20, 0, 0])
}

// MARK: - Calories

@Test func onlyClearlyRaisedHeartRatesCountAsActive() throws {
    let gate = try #require(OpenStrapCalories.activeGate(maxHeartRate: 190, restingHeartRate: 55))
    #expect(gate == 109)
    #expect(OpenStrapCalories.activeGate(maxHeartRate: 50, restingHeartRate: 55) == nil)
    let easy = minutes(0, 60, rate: { _ in 105 }, motion: { _ in 3 })
    #expect(OpenStrapCalories.boutActive(minutes: easy, body: owner, maxHeartRate: 190, restingHeartRate: 55) == 0)
}

@Test func aHardSessionBurnsAPlausibleAmount() throws {
    let workout = try #require(detect(quiet(0, 30) + hardSession(30, 60) + quiet(60, 90)).first)
    // 30 minutes at 155 bpm for 80 kg: about 7 to 20 kcal a minute above rest.
    #expect((200...600).contains(workout.calories), "\(workout.calories) kcal")
}

@Test func noBodyDetailsMeansNoCalories() throws {
    let workout = try #require(detect(quiet(0, 30) + hardSession(30, 60) + quiet(60, 90), body: nil).first)
    #expect(workout.calories == 0)
}

// MARK: - Finishing and adding workouts

@Test func aWorkoutUnderAMinuteIsTooShortToSave() {
    #expect(WorkoutDetector.isTooShort(start: start, end: start.addingTimeInterval(1)))
    #expect(WorkoutDetector.isTooShort(start: start, end: start.addingTimeInterval(59)))
    #expect(!WorkoutDetector.isTooShort(start: start, end: start.addingTimeInterval(60)))
}

@Test func aPastWorkoutIsCalculatedFromSavedBandData() throws {
    let saved = quiet(0, 30) + strengthSession(30, 75) + quiet(75, 110)
    let workout = WorkoutDetector.manual(kind: .strength, start: moment(30), end: moment(75), minutes: saved, profile: profile,
                                         body: owner, restingHeartRate: 55)
    #expect(workout.kind == .strength && workout.source == .manual && workout.durationMinutes == 45)
    #expect((115...135).contains(workout.averageHeartRate))
    #expect(workout.maxHeartRate >= 160)
    #expect(workout.strain > 0 && workout.calories > 0)
    #expect(workout.zoneSeconds.reduce(0, +) > 0)
}

@Test func theWorkoutTypesAreTheOnesInThePicker() {
    #expect(WorkoutKind.allCases.map(\.displayName) == ["Run", "Cycle", "Strength", "Walk", "HIIT", "Other"])
    #expect(WorkoutKind(rawValue: "ride") == .ride)         // saved workouts keep working
}
