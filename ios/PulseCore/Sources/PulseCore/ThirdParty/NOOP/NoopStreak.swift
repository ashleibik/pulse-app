// Ported to Swift from NOOP, Packages/StrandAnalytics/Sources/StrandAnalytics/StreakCalculator.swift (`StreakCalculator.streaks`)
// and Baselines.swift (`isoEpochDay`).
// Source: https://github.com/ryanbr/noop at commit 2a1de7609843b095505274ad6fc811757210be80
// License: PolyForm Noncommercial License 1.0.0. Required Notice: Copyright 2026 NoopApp. See docs/THIRD_PARTY.md.
//
// Unchanged for Pulse. Which days qualify is decided by the caller (`Streak.days`, docs/METRICS.md §17).

import Foundation

/// NOOP's "days in a row": the current and longest runs of consecutive calendar days that qualify.
enum NoopStreak {
    struct Streaks: Equatable, Sendable {
        /// The unbroken run of qualifying days ending at `today`, or at `today - 1` when today has not been scored yet (a day's
        /// score only lands after that night's sleep, so the streak must not read 0 all day). A missed day ends it.
        let current: Int
        /// The longest unbroken run anywhere in the history.
        let longest: Int
    }

    /// `dayKeys` are `yyyy-MM-dd`, paired with `qualified`. Duplicate or unparseable keys are ignored; if the arrays differ in
    /// length the excess is ignored. (0, 0) when nothing qualifies.
    static func streaks(dayKeys: [String], qualified: [Bool], today: String) -> Streaks {
        var days = Set<Int>()
        for i in 0..<Swift.min(dayKeys.count, qualified.count) where qualified[i] {
            if let e = isoEpochDay(dayKeys[i]) { days.insert(e) }
        }
        guard !days.isEmpty else { return Streaks(current: 0, longest: 0) }

        // Longest run: start at each day whose predecessor is absent, then count forward.
        var longest = 0
        for d in days where !days.contains(d - 1) {
            var len = 1
            while days.contains(d + len) { len += 1 }
            if len > longest { longest = len }
        }

        // Current run: anchored at today, or yesterday when today is not yet scored.
        var current = 0
        if let t = isoEpochDay(today) {
            let anchor: Int? = days.contains(t) ? t : (days.contains(t - 1) ? t - 1 : nil)
            if let a = anchor {
                current = 1
                while days.contains(a - current) { current += 1 }
            }
        }
        return Streaks(current: current, longest: longest)
    }

    /// Days from the civil epoch (proleptic Gregorian) for an ISO `yyyy-MM-dd`, or nil if unparseable. Time-zone free (Howard
    /// Hinnant's algorithm).
    static func isoEpochDay(_ iso: String) -> Int? {
        let p = iso.split(separator: "-")
        guard p.count == 3, let y = Int(p[0]), let m = Int(p[1]), let d = Int(p[2]), m >= 1, m <= 12 else { return nil }
        let yy = m <= 2 ? y - 1 : y
        let era = (yy >= 0 ? yy : yy - 399) / 400
        let yoe = yy - era * 400
        let doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }
}
