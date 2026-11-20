import Foundation
import Testing
@testable import PulseCore

// NOOP's own tests for the parts Pulse ports (SleepAwareStepCounterTests.swift and StepsEstimateEngineTests.swift at
// commit 2a1de7609843b095505274ad6fc811757210be80), with the same inputs and expected values.

private func sample(_ ts: Int, _ counter: Int, _ cls: Int? = 1) -> NoopSteps.StepSample {
    NoopSteps.StepSample(ts: ts, counter: counter, activityClass: cls)
}

private func sleep(wake: [Range<Int>] = []) -> NoopSteps.SleepSession {
    NoopSteps.SleepSession(start: 0, end: 100, wake: wake)
}

@Test func noopIsolatedBedMotionIsRejected() {
    #expect(NoopSteps.stepsInWindow([sample(0, 0), sample(1, 1), sample(20, 2)], sleepSessions: [sleep()]) == nil)
}

@Test func noopCoherentNightWalkCounts() {
    #expect(NoopSteps.stepsInWindow([sample(0, 0), sample(1, 2), sample(2, 4), sample(3, 6), sample(4, 8), sample(5, 10)],
                                    sleepSessions: [sleep()]) == 10)
}

@Test func noopExplicitWakeGapCountsImmediately() {
    #expect(NoopSteps.stepsInWindow([sample(9, 0), sample(10, 2)], sleepSessions: [sleep(wake: [10..<20])]) == 2)
}

@Test func noopDiagnosticRejectionReasonsAreSeparated() {
    let count = NoopSteps.count([sample(0, 100, 0), sample(1, 102, 1), sample(2, 110, 1), sample(4, 117, 2), sample(5, 120, 0)],
                                sleepSessions: [])
    #expect(count.totalTicks == 9)
    #expect(count.rejectedActivityClassTicks == 3)
    #expect(count.rejectedImplausibleTicks == 8)
}

@Test func noopCounterWrapsAtSixteenBits() {
    #expect(NoopSteps.stepsInWindow([sample(0, 65_534), sample(1, 1)], sleepSessions: []) == 3)
}

private func points(_ pairs: [(Double, Double)]) -> [NoopSteps.CalibrationPoint] {
    pairs.map { NoopSteps.CalibrationPoint(motion: $0.0, steps: $0.1) }
}

@Test func noopCalibrateFitsMedianRatio() throws {
    let cal = try #require(NoopSteps.calibrate(points([(10, 1000), (20, 2000), (10, 1100), (10, 900), (10, 1000)])))
    #expect(abs(cal.coefficient - 100) < 1e-9)
    #expect(!cal.manual)
    #expect(cal.sampleDays == 5)
    #expect(cal.confidence > 0)
}

@Test func noopCalibrateNilBelowMinDays() {
    #expect(NoopSteps.calibrate(points([(10, 1000), (10, 1000)])) == nil)
}

@Test func noopCalibrateSkipsNearStillAndZeroStepDays() throws {
    let cal = try #require(NoopSteps.calibrate(points([(0.2, 5000), (10, 0), (10, 1000), (20, 2000), (15, 1500)])))
    #expect(abs(cal.coefficient - 100) < 1e-9)
    #expect(cal.sampleDays == 3)
}

@Test func noopCalibrateMotionWeightedHighActivityDayDrivesFit() throws {
    let cal = try #require(NoopSteps.calibrate(points([(1, 50), (1, 50), (1, 50), (100, 10_000)])))
    #expect(abs(cal.coefficient - 100) < 1e-9)
    #expect(cal.sampleDays == 4)
}

@Test func noopWeightedMedian() {
    #expect(abs(NoopSteps.weightedMedian([90, 100, 110, 130], weights: [5, 5, 5, 5]) - 105) < 1e-9)
    #expect(abs(NoopSteps.weightedMedian([3, 1, 2], weights: [7, 7, 7]) - 2) < 1e-9)
    #expect(abs(NoopSteps.weightedMedian([1, 2, 3], weights: []) - 2) < 1e-9)
    #expect(abs(NoopSteps.weightedMedian([1, 2, 3], weights: [0, 0, 0]) - 2) < 1e-9)
    #expect(NoopSteps.weightedMedian([], weights: []) == 0)
}

@Test func noopManualOverrideWins() throws {
    let cal = try #require(NoopSteps.calibrate([], manualOverride: 123))
    #expect(cal.coefficient == 123 && cal.manual && cal.confidence == 1.0)
}

@Test func noopTightFitMoreConfidentThanScattered() throws {
    let tight = try #require(NoopSteps.calibrate(points((0..<14).map { _ in (10, 1000) })))
    let scattered = try #require(NoopSteps.calibrate(points((0..<14).map { (10, Double(500 + ($0 % 2) * 1500)) })))
    #expect(tight.confidence > scattered.confidence)
    #expect(abs(tight.confidence - 1.0) < 1e-9)
}

@Test func noopEstimateAppliesClampsAndFloors() {
    let cal = NoopSteps.Calibration(coefficient: 100, sampleDays: 5, confidence: 1, manual: false)
    #expect(NoopSteps.estimate(motion: 87, calibration: cal) == 8700)
    #expect(NoopSteps.estimate(motion: 0.5, calibration: cal) == nil)
    let huge = NoopSteps.Calibration(coefficient: 1_000, sampleDays: 5, confidence: 1, manual: false)
    #expect(NoopSteps.estimate(motion: 100, calibration: huge) == NoopSteps.maxDailySteps)
}

@Test func noopConfidenceTierThresholds() {
    #expect(NoopSteps.ConfidenceTier.from(0.0) == .low)
    #expect(NoopSteps.ConfidenceTier.from(0.33) == .low)
    #expect(NoopSteps.ConfidenceTier.from(0.34) == .medium)
    #expect(NoopSteps.ConfidenceTier.from(0.66) == .medium)
    #expect(NoopSteps.ConfidenceTier.from(0.67) == .high)
    #expect(NoopSteps.ConfidenceTier.from(1.0) == .high)
}
