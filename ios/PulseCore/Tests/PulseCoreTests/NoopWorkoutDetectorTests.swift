import Foundation
import Testing
@testable import PulseCore

// NOOP's own tests for its exercise detector (Packages/StrandAnalytics/Tests/StrandAnalyticsTests/WorkoutDetectorTests.swift at
// 2a1de76), run on the port with the same fixtures. NOOP's `age: 30` gives Tanaka's 187 as the maximum heart rate, and without a
// resting heart rate it derives its 10th percentile, as here.

private let maxHR = 208 - 0.7 * 30

private struct Series {
    var hr: [Int: Double] = [:]
    var gravity: [(ts: Int, x: Double, y: Double, z: Double)] = []
}

private func detect(_ series: Series, restingHR: Double? = nil) -> [NoopWorkoutDetector.Bout] {
    let rest = restingHR ?? NoopWorkoutDetector.deriveRestingHR(Array(series.hr.values))
    return NoopWorkoutDetector.detect(motion: NoopWorkoutDetector.activitySeries(series.gravity),
                                      heartRateAt: { series.hr[$0] }, restingHR: { _ in rest }, maxHR: maxHR)
}

/// High heart rate and sustained motion for `duration` seconds, inside a resting day.
private func workoutDay(start: Int, duration: Int, rate: Double = 165) -> Series {
    var series = Series()
    for t in (start - 30 * 60)..<(start + duration + 30 * 60) {
        let inWorkout = t >= start && t < start + duration
        series.hr[t] = inWorkout ? rate : 55
        series.gravity.append((t, inWorkout ? Double((t - start) % 2) * 0.5 : 0, 0, 1))
    }
    return series
}

@Test func noopActivitySeriesStartsAtZero() {
    let series = NoopWorkoutDetector.activitySeries([(0, 0, 0, 1), (1, 0.3, 0, 1), (2, 0.3, 0, 1)])
    #expect(series.map(\.intensity).count == 3)
    #expect(abs(series[0].intensity) < 1e-9 && abs(series[1].intensity - 0.3) < 1e-9 && abs(series[2].intensity) < 1e-9)
}

@Test func noopDetectFindsWorkout() throws {
    let bouts = detect(workoutDay(start: 5_000_000, duration: 20 * 60))
    #expect(bouts.count == 1)
    let bout = try #require(bouts.first)
    #expect(bout.end - bout.start > 15 * 60)
}

@Test func noopDetectRejectsShortBout() {
    #expect(detect(workoutDay(start: 7_000_000, duration: 3 * 60)).isEmpty)
}

@Test func noopDetectEmptyStreams() {
    #expect(detect(Series()).isEmpty)
    var noHeartRate = Series()
    noHeartRate.gravity = [(0, 0, 0, 1)]
    #expect(detect(noHeartRate).isEmpty)
}

@Test func noopDetectRejectsLowIntensityBlip() {
    // Moving with HR 75: over the floor of 70 (resting 55 + 15), but in zone 0.
    #expect(detect(workoutDay(start: 8_000_000, duration: 20 * 60, rate: 75)).isEmpty)
}

@Test func noopLongRideWithBriefDipsIsOneWorkout() throws {
    // 3 h 52 m with a 3-minute coasting dip every 8 minutes; the heart rate stays at 150.
    let start = 9_000_000, duration = 232 * 60, cycle = 8 * 60, dip = 180
    var series = Series()
    for t in (start - 30 * 60)..<(start + duration + 30 * 60) {
        let inRide = t >= start && t < start + duration
        let coasting = inRide && (t - start) % cycle >= cycle - dip
        series.hr[t] = inRide ? 150 : 52
        series.gravity.append((t, inRide && !coasting ? Double((t - start) % 2) * 0.5 : 0, 0, 1))
    }
    let bouts = detect(series)
    #expect(bouts.count == 1, "fragmented into \(bouts.count)")
    let bout = try #require(bouts.first)
    #expect(Double(bout.end - bout.start) > Double(duration) * 0.9)
}

@Test func noopGenuinelySeparateWorkoutsStaySeparate() {
    let startA = 10_000_000, duration = 20 * 60, rest = 25 * 60
    let startB = startA + duration + rest
    var series = Series()
    for t in (startA - 30 * 60)..<(startB + duration + 30 * 60) {
        let active = (t >= startA && t < startA + duration) || (t >= startB && t < startB + duration)
        series.hr[t] = active ? 160 : 52
        series.gravity.append((t, active ? Double(t % 2) * 0.5 : 0, 0, 1))
    }
    #expect(detect(series).count == 2)
}

@Test func noopWarmupBeforeHeartRateRisesBackdatesStartToMotionOnset() throws {
    let motionStart = 12_000_000, warmup = 10 * 60, core = 20 * 60
    var series = Series()
    for t in (motionStart - 30 * 60)..<(motionStart + warmup + core + 30 * 60) {
        let inWarm = t >= motionStart && t < motionStart + warmup
        let inCore = t >= motionStart + warmup && t < motionStart + warmup + core
        series.hr[t] = inCore ? 150 : (inWarm ? 60 : 52)
        series.gravity.append((t, inWarm || inCore ? Double(t % 2) * 0.5 : 0, 0, 1))
    }
    let bouts = detect(series, restingHR: 52)
    #expect(bouts.count == 1)
    let bout = try #require(bouts.first)
    #expect(bout.start <= motionStart + 120, "start \(bout.start) not back-dated to \(motionStart)")
    #expect(Double(bout.end - bout.start) >= Double(warmup + core) * 0.9)
}

@Test func noopBackdateDoesNotCrossPreviousWorkoutContinuousMotion() throws {
    let startA = 13_000_000, durationA = 15 * 60, lull = 6 * 60, durationB = 15 * 60
    let moveEnd = startA + durationA + lull + durationB
    var series = Series()
    for t in (startA - 30 * 60)..<(moveEnd + 30 * 60) {
        let inA = t >= startA && t < startA + durationA
        let inB = t >= startA + durationA + lull && t < moveEnd
        series.hr[t] = inA || inB ? 155 : 52
        series.gravity.append((t, t >= startA && t < moveEnd ? Double(t % 2) * 0.5 : 0, 0, 1))
    }
    let bouts = detect(series, restingHR: 52)
    #expect(bouts.count == 2, "the lull didn't split the efforts")
    let second = try #require(bouts.last), first = try #require(bouts.first)
    #expect(second.start > first.end)
}

@Test func noopNearestReadingPrefersTheLaterOneOnATie() {
    let readings: [Int: Double] = [98: 70, 102: 90]
    #expect(NoopWorkoutDetector.nearest(100, tolerance: 5) { readings[$0] } == 90)
    #expect(NoopWorkoutDetector.nearest(99, tolerance: 5) { readings[$0] } == 70)
    #expect(NoopWorkoutDetector.nearest(100, tolerance: 1) { readings[$0] } == nil)
}
