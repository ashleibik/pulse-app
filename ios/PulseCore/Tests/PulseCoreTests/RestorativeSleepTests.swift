import Foundation
import Testing
@testable import PulseCore

// Restorative sleep (docs/METRICS.md §12): deep + REM, with NOOP's restorative sub-score.

@Test func noopRestorativeScoreMatchesItsFormula() {
    // Half the night restorative and no deep split known: full credit.
    #expect(NoopRestorative.score(restorativeSeconds: 7200, deepSeconds: nil, tstSeconds: 14_400) == 1.0)
    // 5% deep: adequacy 0.05 / 0.13, factor 0.5 + 0.5 × adequacy.
    let factor = 0.5 + 0.5 * (0.05 / 0.13)
    #expect(abs(NoopRestorative.score(restorativeSeconds: 7200, deepSeconds: 720, tstSeconds: 14_400) - factor) < 1e-12)
    // Over the target never earns more than full credit, and nothing asleep earns nothing.
    #expect(NoopRestorative.score(restorativeSeconds: 12_000, deepSeconds: 4000, tstSeconds: 14_400) == 1.0)
    #expect(NoopRestorative.score(restorativeSeconds: 0, deepSeconds: 0, tstSeconds: 0) == 0)
}

@Test func theOwnersNightIsRestorativeAsNoopScoresIt() throws {
    // 2026-11-17/18 after the stage fixes: deep 82, REM 133, light 337.
    let night = try #require(RestorativeSleep.make(deepMinutes: 82, remMinutes: 133, asleepMinutes: 552))
    #expect(night.minutes == 215)
    #expect(abs(night.share - 215.0 / 552) < 1e-12)
    // Deep is 14.9%, past NOOP's 13%, so only the share counts: 38.9% of the 50% target.
    #expect(abs(night.credit - (215.0 / 552) / 0.5) < 1e-12)
    #expect(night.level == .sufficient)
}

@Test func littleDeepSleepLowersTheCredit() throws {
    let noDeep = try #require(RestorativeSleep.make(deepMinutes: 0, remMinutes: 150, asleepMinutes: 400))
    #expect(abs(noDeep.credit - 0.75 * 0.5) < 1e-12)
    #expect(noDeep.level == .poor)
    let full = try #require(RestorativeSleep.make(deepMinutes: 90, remMinutes: 120, asleepMinutes: 420))
    #expect(full.credit == 1.0 && full.level == .optimal)
}

@Test func restorativeSleepComesFromTheStageTotals() throws {
    let night = try #require(RestorativeSleep.make(totals: [.deep: 60, .rem: 100, .light: 240, .awake: 30]))
    #expect(night.minutes == 160)
    #expect(abs(night.share - 0.4) < 1e-12)
    #expect(RestorativeSleep.make(totals: [.awake: 30]) == nil)
}
