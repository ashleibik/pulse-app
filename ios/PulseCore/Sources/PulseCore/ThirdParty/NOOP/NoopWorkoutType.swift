// Ported to Swift for Pulse from NOOP, Packages/StrandAnalytics/Sources/StrandAnalytics/WorkoutTypeClassifier.swift
// (rampUp, rampDown, plateau, runScore, walkScore, strengthScore, cycleScore, classify).
// Source: https://github.com/ryanbr/noop at commit 2a1de7609843b095505274ad6fc811757210be80
// License: PolyForm Noncommercial License 1.0.0 <https://polyformproject.org/licenses/noncommercial/1.0.0>
// Required Notice: Copyright 2026 NoopApp
//
// Noncommercial use only. Changed for Pulse: the ski class and the band's activity-class ticks are left
// out, because the WHOOP 4.0 doesn't report those ticks.

import Foundation

/// What kind of workout a stretch of heart rate and motion looks like. A broad guess: at one reading a
/// second the band can't see the rhythm of steps, only how steady or bursty the movement is.
enum NoopWorkoutType {
    struct Features: Equatable {
        /// Average share of heart-rate reserve, 0...100.
        var meanReservePercent: Double
        /// Heart-rate standard deviation ÷ mean. High = up and down, like sets and rests.
        var heartRateVariation: Double
        /// Variance of the second-by-second movement, in g².
        var motionVariance: Double
        var kcalPerMinute: Double?
    }

    static let minimumScore = 0.40
    static let minimumMargin = 0.05
    /// Without activity-class ticks the absence of a gait is unknown, which scores neutral.
    private static let noGait = 0.5

    static func rampUp(_ x: Double, _ low: Double, _ high: Double) -> Double {
        guard high > low else { return x >= high ? 1 : 0 }
        return min(1, max(0, (x - low) / (high - low)))
    }

    static func rampDown(_ x: Double, _ low: Double, _ high: Double) -> Double { 1 - rampUp(x, low, high) }

    static func plateau(_ x: Double, _ a: Double, _ b: Double, _ c: Double, _ d: Double) -> Double {
        min(rampUp(x, a, b), rampDown(x, c, d))
    }

    static func runScore(_ f: Features) -> Double {
        0.45 * rampUp(f.meanReservePercent, 45, 75) + 0.35 * plateau(f.motionVariance, 0.05, 0.10, 0.35, 0.60)
            + 0.20 * rampDown(f.heartRateVariation, 0.05, 0.12)
    }

    static func walkScore(_ f: Features) -> Double {
        0.55 * plateau(f.meanReservePercent, 5, 15, 35, 55) + 0.45 * plateau(f.motionVariance, 0.005, 0.02, 0.07, 0.12)
    }

    static func strengthScore(_ f: Features) -> Double {
        0.45 * rampUp(f.heartRateVariation, 0.06, 0.16) + 0.20 * noGait + 0.20 * rampDown(f.motionVariance, 0.05, 0.15)
            + 0.10 * plateau(f.meanReservePercent, 15, 30, 80, 100) + 0.05 * rampDown(f.kcalPerMinute ?? 6, 6, 11)
    }

    static func cycleScore(_ f: Features) -> Double {
        0.30 * noGait + 0.30 * rampDown(f.heartRateVariation, 0.04, 0.10) + 0.25 * rampUp(f.meanReservePercent, 35, 65)
            + 0.15 * rampDown(f.motionVariance, 0.02, 0.08)
    }

    /// The best match, or `.other` when nothing is clearly ahead.
    static func classify(_ f: Features) -> WorkoutKind {
        let ranked: [(kind: WorkoutKind, score: Double)] = [
            (.walk, walkScore(f)), (.run, runScore(f)), (.strength, strengthScore(f)), (.ride, cycleScore(f)),
        ].sorted { $0.score > $1.score }
        guard ranked[0].score >= minimumScore, ranked[0].score - ranked[1].score >= minimumMargin else { return .other }
        return ranked[0].kind
    }
}
