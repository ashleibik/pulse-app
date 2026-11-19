// Ported to Swift for Pulse from NOOP, Packages/StrandAnalytics/Sources/StrandAnalytics/WorkoutDetector.swift
// (enum Calories: the coefficients, restingKcalPerS, vo2maxFor, activeKcalPerS and estimateDayEnergy).
// Source: https://github.com/ryanbr/noop at commit 2a1de7609843b095505274ad6fc811757210be80
// License: PolyForm Noncommercial License 1.0.0 <https://polyformproject.org/licenses/noncommercial/1.0.0>
// Required Notice: Copyright 2026 NoopApp
//
// Noncommercial use only. Changed for Pulse: a resting heart rate is required, so NOOP's fallback to a default
// resting heart rate and the fitness-blind Keytel formula are left out. No value is guessed.

import Foundation

/// A whole day's energy from heart rate. An estimate, not a lab measurement.
enum NoopCalories {
    /// Only heart rates at or above this share of heart-rate reserve count as active over a whole day.
    static let dayActiveReserveShare = 0.50
    /// The longest gap one reading can carry resting energy across.
    static let longestRestingGap = 60.0
    static let longestDay = 86_400.0
    /// 60 seconds a minute x 4.184 kJ per kcal.
    static let kilojoulesPerMinuteToKcalPerSecond = 251.04

    struct DayEnergy: Sendable, Equatable {
        var restingKcal: Double
        var activeKcal: Double
        var observedSeconds: Double
    }

    private struct Coefficients {
        var restAlpha, restWeight, restHeightMetres, restAge: Double
        var heartRate, vo2max, weight, age, alpha: Double
    }

    private static func coefficients(_ sex: BiologicalSex) -> Coefficients {
        switch sex {
        case .male:
            Coefficients(restAlpha: 88.362, restWeight: 13.397, restHeightMetres: 479.9, restAge: 5.677,
                         heartRate: 0.634, vo2max: 0.404, weight: 0.394, age: 0.271, alpha: -95.7735)
        case .female:
            Coefficients(restAlpha: 447.593, restWeight: 9.247, restHeightMetres: 309.8, restAge: 4.33,
                         heartRate: 0.450, vo2max: 0.380, weight: 0.103, age: 0.274, alpha: -59.3954)
        case .unspecified:
            Coefficients(restAlpha: 267.9775, restWeight: 11.322, restHeightMetres: 394.85, restAge: 5.0035,
                         heartRate: 0.542, vo2max: 0.392, weight: 0.2485, age: 0.2725, alpha: -77.58445)
        }
    }

    /// Revised Harris-Benedict, in kcal per second.
    static func restingRate(body: DailyCalories.Body) -> Double {
        let c = coefficients(body.sex)
        return max(0, c.restAlpha + c.restWeight * body.weightKg + c.restHeightMetres * body.heightCm / 100 - c.restAge * body.age) / 86_400
    }

    /// Uth 2004, in ml/kg/min.
    static func vo2max(maxHeartRate: Double, restingHeartRate: Double) -> Double {
        15.3 * maxHeartRate / restingHeartRate
    }

    /// Keytel 2005 with fitness, in kcal per second.
    static func activeRate(heartRate: Double, maxHeartRate: Double, vo2max: Double, body: DailyCalories.Body) -> Double {
        let c = coefficients(body.sex)
        let kilojoules = c.heartRate * min(heartRate, maxHeartRate) + c.vo2max * vo2max + c.weight * body.weightKg + c.age * body.age + c.alpha
        return max(0, kilojoules) / kilojoulesPerMinuteToKcalPerSecond
    }

    /// - Parameter minutes: the day's worn minutes, in any order.
    /// - Returns: nil when the two heart-rate anchors can't define the active gate.
    static func dayEnergy(minutes: [MinuteSample], body: DailyCalories.Body, maxHeartRate: Double,
                          restingHeartRate: Double) -> DayEnergy? {
        guard maxHeartRate.isFinite, restingHeartRate.isFinite, restingHeartRate > 0, restingHeartRate < maxHeartRate else { return nil }

        var samples: [(time: Int, bpm: Int)] = []
        samples.reserveCapacity(minutes.count * 60)
        for minute in minutes {
            let start = Int(minute.start.timeIntervalSince1970)
            for (second, bpm) in minute.heartRate.enumerated() where bpm > 0 {
                samples.append((start + second, Int(bpm)))
            }
        }
        guard !samples.isEmpty else { return DayEnergy(restingKcal: 0, activeKcal: 0, observedSeconds: 0) }
        // On a tie the interval goes to the lower reading, as in NOOP.
        let ordered = samples.sorted { $0.time != $1.time ? $0.time < $1.time : $0.bpm > $1.bpm }

        let gaps = zip(ordered, ordered.dropFirst()).map { Double($1.time - $0.time) }.filter { $0 > 0 }.sorted()
        var spacing = 1.0
        if !gaps.isEmpty {
            let middle = gaps.count / 2
            let median = gaps.count.isMultiple(of: 2) ? (gaps[middle - 1] + gaps[middle]) / 2 : gaps[middle]
            spacing = min(median, longestRestingGap)
        }
        let observed = min(longestDay, gaps.reduce(spacing) { $0 + min($1, longestRestingGap) })

        let resting = restingRate(body: body)
        let gate = restingHeartRate + dayActiveReserveShare * (maxHeartRate - restingHeartRate)
        let fitness = vo2max(maxHeartRate: maxHeartRate, restingHeartRate: restingHeartRate)
        var active = 0.0
        for index in ordered.indices where Double(ordered[index].bpm) >= gate {
            let duration: Double
            if index < ordered.count - 1 {
                let gap = Double(ordered[index + 1].time - ordered[index].time)
                duration = gap > 0 ? min(gap, spacing) : 0
            } else {
                duration = spacing
            }
            let gross = activeRate(heartRate: Double(ordered[index].bpm), maxHeartRate: maxHeartRate, vo2max: fitness, body: body)
            active += max(0, gross - resting) * duration
        }
        return DayEnergy(restingKcal: resting * observed, activeKcal: active, observedSeconds: observed)
    }
}
