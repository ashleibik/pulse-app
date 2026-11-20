// Ported to Swift for Pulse from NOOP, Packages/StrandAnalytics/Sources/StrandAnalytics/FitnessAgeEngine.swift
// (the Nes 2011 coefficients, estimateVO2max, physicalActivityIndex, minCoverageDays) and docs/FITNESS_AGE.md
// (rolling 7-day median resting heart rate, at least 4 of 7 nights). The Uth fallback is NoopCalories.vo2max.
// Source: https://github.com/ryanbr/noop at commit 2a1de7609843b095505274ad6fc811757210be80
// License: PolyForm Noncommercial License 1.0.0 <https://polyformproject.org/licenses/noncommercial/1.0.0>
// Required Notice: Copyright 2026 NoopApp
//
// Noncommercial use only. Changed for Pulse: sex is Pulse's `BiologicalSex` (unspecified uses the men's
// coefficients, as NOOP does for non-binary), and the Fitness Age half of the engine is left out.

import Foundation

enum NoopFitness {
    // Nes 2011 HUNT non-exercise model, waist-circumference variant:
    // VO2max = intercept − ageC·age + paiC·PA − wcC·waist − rhrC·RHR
    static let menIntercept = 100.27, menAge = 0.296, menWC = 0.369, menRHR = 0.155, menPAI = 0.226
    static let womenIntercept = 74.74, womenAge = 0.247, womenWC = 0.259, womenRHR = 0.114, womenPAI = 0.198
    /// The model's standard error of estimate, ml/kg/min.
    static let seeMen = 5.70, seeWomen = 5.14
    /// Nights of resting heart rate in the last 7 before a number is given.
    static let minCoverageDays = 4

    private static func coeffs(_ sex: BiologicalSex) -> (Double, Double, Double, Double, Double) {
        sex == .female
            ? (womenIntercept, womenAge, womenWC, womenRHR, womenPAI)
            : (menIntercept, menAge, menWC, menRHR, menPAI)
    }

    static func standardError(_ sex: BiologicalSex) -> Double { sex == .female ? seeWomen : seeMen }

    /// Nes 2011 waist-variant VO2max (ml/kg/min).
    static func estimateVO2max(age: Double, sex: BiologicalSex, waistCm: Double, restingHR: Double, paIndex: Double) -> Double {
        let (intercept, ageC, wcC, rhrC, paiC) = coeffs(sex)
        return intercept - ageC * age + paiC * paIndex - wcC * waistCm - rhrC * restingHR
    }

    /// The HUNT physical-activity index (0-15 = frequency × intensity × duration) rebuilt from a measured week.
    static func physicalActivityIndex(activeDaysPerWeek: Int, avgActiveMinutesPerDay: Double, highIntensityFraction: Double) -> Double {
        let frequency: Double
        switch activeDaysPerWeek {
        case ..<1: frequency = 0.0
        case 1: frequency = 0.5
        case 2: frequency = 1.0
        case 3...4: frequency = 2.5
        default: frequency = 5.0
        }
        let intensity: Double
        switch highIntensityFraction {
        case ..<0.15: intensity = 1.0
        case ..<0.5: intensity = 2.0
        default: intensity = 3.0
        }
        let duration: Double
        switch avgActiveMinutesPerDay {
        case ..<15: duration = 0.10
        case ..<30: duration = 0.38
        case ..<60: duration = 0.75
        default: duration = 1.0
        }
        if frequency == 0 { return 0 }
        return frequency * intensity * duration
    }
}
