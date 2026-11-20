// Ported to Swift for Pulse from NOOP, Packages/StrandAnalytics/Sources/StrandAnalytics/AnalyticsEngine.swift
// (enum Rest: restorativeTarget, deepShareTarget, deepFloorFactor and the restorative sub-score of `score`).
// Source: https://github.com/ryanbr/noop at commit 2a1de7609843b095505274ad6fc811757210be80
// License: PolyForm Noncommercial License 1.0.0 <https://polyformproject.org/licenses/noncommercial/1.0.0>
// Required Notice: Copyright 2026 NoopApp
//
// Noncommercial use only. Changed for Pulse: only the restorative sub-score is ported, not the whole Rest composite.

import Foundation

enum NoopRestorative {
    /// "Full marks" restorative (deep + REM) share of asleep time.
    static let restorativeTarget = 0.50
    /// Deep share of asleep time that earns full restorative credit.
    static let deepShareTarget = 0.13
    /// The most the restorative credit is scaled down by when deep is about absent: half, never zero.
    static let deepFloorFactor = 0.5

    private static func clamp01(_ x: Double) -> Double { max(0, min(1, x)) }

    /// 0...1. (deep + REM) / asleep against `restorativeTarget`, scaled by how close deep comes to `deepShareTarget`.
    /// - Parameter deepSeconds: nil when only the pooled total is known (no deep adjustment).
    static func score(restorativeSeconds: Double, deepSeconds: Double?, tstSeconds: Double) -> Double {
        let deepFactor: Double = {
            guard let deep = deepSeconds, tstSeconds > 0, deepShareTarget > 0 else { return 1.0 }
            let adequacy = clamp01((deep / tstSeconds) / deepShareTarget)
            return deepFloorFactor + (1.0 - deepFloorFactor) * adequacy
        }()
        return tstSeconds > 0 ? clamp01((restorativeSeconds / tstSeconds) / restorativeTarget) * deepFactor : 0.0
    }
}
