import Foundation
import Testing
@testable import PulseCore

// Workouts, zones and active calories. The owner's workout itself isn't in a backup on this machine yet,
// so these use made-up minutes shaped like it: 45 minutes, average near 120, peaks near 163.

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

private func detect(_ list: [MinuteSample], body: DailyCalories.Body? = owner) -> [Workout] {
    WorkoutDetector.detect(minutes: list, profile: profile, body: body) { _ in 55 }
}

// MARK: - Detection

@Test func strengthTrainingIsFoundFromItsUpAndDownHeartRate() throws {
    let workouts = detect(quiet(0, 30) + strengthSession(30, 75) + quiet(75, 110))
    #expect(workouts.count == 1)
    let workout = try #require(workouts.first)
    #expect(workout.kind == .strength)
    #expect(abs(workout.start.timeIntervalSince(moment(30))) <= 3 * 60)
    #expect(abs(workout.end.timeIntervalSince(moment(75))) <= 3 * 60)
    #expect(workout.maxHeartRate >= 160)
    #expect(workout.isSuggestion == nil)
}

@Test func aShortBurstOfSetsIsNotAStrengthWorkout() {
    #expect(detect(quiet(0, 30) + strengthSession(30, 39) + quiet(39, 80)).filter { $0.kind == .strength }.isEmpty)
}

@Test func longRestsBetweenSetsStayInsideOneStrengthWorkout() throws {
    // Three minutes of rest near 92 bpm after each set is too long for the cardio detector to bridge.
    let session = minutes(30, 75, rate: { second in UInt8(second % 300 < 120 ? 140 : 92) },
                          motion: { $0 % 300 < 120 ? ($0 % 3 == 0 ? 70 : 20) : 3 })
    let workouts = detect(quiet(0, 30) + session + quiet(75, 110)).filter { $0.kind == .strength }
    #expect(workouts.count == 1)
    #expect(try #require(workouts.first).durationMinutes >= 35)
}

@Test func oneLongClimbAndFallIsNotSetsAndRests() {
    // Hurrying somewhere and calming down afterwards: raised and moving, but only once.
    let once = minutes(30, 70, rate: { second in UInt8(90 + 40 * sin(Double(second) / 2400 * .pi)) },
                       motion: { $0 % 3 == 0 ? 50 : 8 })
    #expect(detect(quiet(0, 30) + once + quiet(70, 100)).filter { $0.kind == .strength }.isEmpty)
}

@Test func anUpAndDownHeartRateWithoutMovementIsNotStrength() {
    // Stress or coffee at a desk: the same heart rate pattern with a still wrist.
    let desk = minutes(30, 75, rate: { UInt8($0 % 240 < 84 ? 130 : 96) }, motion: { $0 % 7 == 0 ? 6 : 3 })
    #expect(detect(quiet(0, 30) + desk + quiet(75, 110)).filter { $0.kind == .strength }.isEmpty)
}

@Test func steadyCardioIsFoundAndIsNotStrength() throws {
    let run = minutes(30, 60, rate: { _ in 155 }, motion: { $0 % 2 == 0 ? 90 : 60 })
    let workout = try #require(detect(quiet(0, 30) + run + quiet(60, 90)).first)
    #expect(workout.kind != .strength)
    #expect(workout.durationMinutes >= 25)
}

@Test func tenMinutesOfSteadyMovementWithARaisedHeartRateAsksAboutAWalk() throws {
    let walk = minutes(30, 45, rate: { _ in 88 }, motion: { $0 % 2 == 0 ? 90 : 20 })
    let workout = try #require(detect(quiet(0, 30) + walk + quiet(45, 70)).first)
    #expect(workout.kind == .walk)
    #expect(workout.isSuggestion == true)
}

@Test func movingWithAnOrdinaryHeartRateIsNotAWalk() {
    let chores = minutes(30, 45, rate: { _ in 64 }, motion: { $0 % 2 == 0 ? 90 : 20 })
    #expect(detect(quiet(0, 30) + chores + quiet(45, 70)).isEmpty)
}

@Test func unansweredWalksAreNotSentToAppleHealth() {
    let walk = Workout(kind: .walk, start: start, end: moment(20), averageHeartRate: 90, maxHeartRate: 100, strain: 2,
                       zoneSeconds: [0, 0, 0, 0, 0], calories: 0, source: .history, isSuggestion: true)
    #expect(HealthExport.plan(sleeps: [], workouts: [walk], days: []).workouts.isEmpty)
    var confirmed = walk
    confirmed.isSuggestion = false
    #expect(HealthExport.plan(sleeps: [], workouts: [confirmed], days: []).workouts.count == 1)
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

@Test func aStrengthSessionBurnsAPlausibleAmount() throws {
    let workout = try #require(detect(quiet(0, 30) + strengthSession(30, 75) + quiet(75, 110)).first)
    #expect((150...420).contains(workout.calories), "\(workout.calories) kcal")
}

@Test func noBodyDetailsMeansNoCalories() throws {
    let workout = try #require(detect(quiet(0, 30) + strengthSession(30, 75) + quiet(75, 110), body: nil).first)
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
