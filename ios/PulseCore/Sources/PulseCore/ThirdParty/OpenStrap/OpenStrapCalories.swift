// Ported to Swift from OpenStrap analytics, lib/src/onehz/workout/calories.dart
// (activeHRRFraction, activeGateHr, activeKcalPerS, restingKcalPerS, estimateBoutCalories).
// Source: https://github.com/OpenStrap/analytics at commit e59d63ccc39713a6deb2facfd1c8288a5203398a
// License: MIT, Copyright (c) 2026 OpenStrap. See docs/THIRD_PARTY.md for the full notice.
//
// Changed for Pulse: the bout result is the energy above resting, to compare with a watch's active calories.

import Foundation

/// Heart-rate-flex energy: only heart rates clearly above rest are billed with the Keytel exercise
/// formula, because that formula was fitted on exercise and overstates ordinary daily heart rates.
public enum OpenStrapCalories {
    /// 40% of heart-rate reserve: where moderate exercise begins (ACSM).
    public static let activeReserveShare = 0.40

    /// The heart rate at or above which a minute counts as active. nil when the two anchors can't define it.
    public static func activeGate(maxHeartRate: Double, restingHeartRate: Double) -> Double? {
        guard maxHeartRate.isFinite, restingHeartRate.isFinite, restingHeartRate > 0,
              restingHeartRate < maxHeartRate else { return nil }
        return restingHeartRate + activeReserveShare * (maxHeartRate - restingHeartRate)
    }

    private struct Coefficients {
        var alpha, heartRate, weight, age: Double
        var restAlpha, restWeight, restHeight, restAge: Double
    }

    private static func coefficients(_ sex: BiologicalSex) -> Coefficients {
        switch sex {
        case .male:
            Coefficients(alpha: -55.0969, heartRate: 0.6309, weight: 0.1988, age: 0.2017,
                         restAlpha: 88.362, restWeight: 13.397, restHeight: 479.9, restAge: 5.677)
        case .female:
            Coefficients(alpha: -20.4022, heartRate: 0.4472, weight: -0.1263, age: 0.0740,
                         restAlpha: 447.593, restWeight: 9.247, restHeight: 309.8, restAge: 4.33)
        case .unspecified:
            Coefficients(alpha: -37.74955, heartRate: 0.53905, weight: 0.03625, age: 0.13785,
                         restAlpha: 267.9775, restWeight: 11.322, restHeight: 394.85, restAge: 5.0035)
        }
    }

    /// Keytel 2005, in kcal per second.
    static func activeRate(heartRate: Double, maxHeartRate: Double, body: DailyCalories.Body) -> Double {
        let c = coefficients(body.sex)
        let kilojoules = c.heartRate * min(heartRate, maxHeartRate) + c.weight * body.weightKg + c.age * body.age + c.alpha
        return max(0, kilojoules) / 251.04
    }

    /// Revised Harris-Benedict, in kcal per second.
    static func restingRate(body: DailyCalories.Body) -> Double {
        let c = coefficients(body.sex)
        return max(0, c.restAlpha + c.restWeight * body.weightKg + c.restHeight * body.heightCm / 100 - c.restAge * body.age) / 86_400
    }

    /// Active calories of a workout, from every second the band measured. nil when the gate can't be defined.
    public static func boutActive(minutes: [MinuteSample], body: DailyCalories.Body, maxHeartRate: Double,
                                  restingHeartRate: Double) -> Double? {
        guard let gate = activeGate(maxHeartRate: maxHeartRate, restingHeartRate: restingHeartRate) else { return nil }
        let resting = restingRate(body: body)
        var active = 0.0
        for minute in minutes {
            for rate in minute.heartRate where rate > 0 && Double(rate) >= gate {
                active += max(0, activeRate(heartRate: Double(rate), maxHeartRate: maxHeartRate, body: body) - resting)
            }
        }
        return active
    }
}
