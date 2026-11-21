import Foundation
import Testing
@testable import PulseCore

// NOOP's StreakCalculatorTests, ported (commit 2a1de76), then Pulse's choice of which days count (docs/METRICS.md §17).

private let noopToday = "2026-07-24"

private func expect(_ dayKeys: [String], _ qualified: [Bool], current: Int, longest: Int, today: String = noopToday,
                    sourceLocation: SourceLocation = #_sourceLocation) {
    let got = NoopStreak.streaks(dayKeys: dayKeys, qualified: qualified, today: today)
    #expect(got == NoopStreak.Streaks(current: current, longest: longest), sourceLocation: sourceLocation)
}

@Test func noopStreakEmptyHistory() { expect([], [], current: 0, longest: 0) }

@Test func noopStreakSingleDayToday() { expect(["2026-07-24"], [true], current: 1, longest: 1) }

@Test func noopStreakUnbrokenRunEndingToday() {
    expect(["2026-07-20", "2026-07-21", "2026-07-22", "2026-07-23", "2026-07-24"], [true, true, true, true, true],
           current: 5, longest: 5)
}

@Test func noopStreakGapResetsCurrentButKeepsLongest() {
    expect(["2026-07-10", "2026-07-11", "2026-07-12", "2026-07-23", "2026-07-24"], [true, true, true, true, true],
           current: 2, longest: 3)
}

@Test func noopStreakTodayNotYetScoredGrace() {
    expect(["2026-07-21", "2026-07-22", "2026-07-23"], [true, true, true], current: 3, longest: 3)
}

@Test func noopStreakMissedYesterdayAndTodayBreaksCurrent() {
    expect(["2026-07-20", "2026-07-21", "2026-07-22"], [true, true, true], current: 0, longest: 3)
}

@Test func noopStreakDuplicateDayKeysDeduped() { expect(["2026-07-24", "2026-07-24"], [true, true], current: 1, longest: 1) }

@Test func noopStreakLongestRunInTheMiddleOfHistory() {
    expect(["2026-07-01", "2026-07-02", "2026-07-03", "2026-07-04", "2026-07-05", "2026-07-23", "2026-07-24"],
           Array(repeating: true, count: 7), current: 2, longest: 5)
}

@Test func noopStreakUnqualifiedDayBreaksTheRun() {
    expect(["2026-07-22", "2026-07-23", "2026-07-24"], [true, false, true], current: 1, longest: 1)
}

@Test func noopStreakMismatchedArrayLengthsUseThePairedPrefix() {
    expect(["2026-07-24", "2026-07-23"], [true], current: 1, longest: 1)
}

@Test func noopStreakUnparseableTodayYieldsNoCurrentButKeepsLongest() {
    expect(["2026-07-23", "2026-07-24"], [true, true], current: 0, longest: 2, today: "not-a-date")
}

// MARK: - Pulse: days with a recorded night

private var local: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: -6 * 3600)!
    return calendar
}

private func day(_ dayOfMonth: Int, night: Int?, recovery: Double? = nil) -> DailySummary {
    DailySummary(date: local.date(from: DateComponents(year: 2026, month: 11, day: dayOfMonth))!, recoveryScore: recovery,
                 strain: 5, sleepMinutes: night, sleepNeedMinutes: 480, restingHeartRate: nil, hrvRMSSD: nil,
                 baselineRestingHeartRate: nil, baselineHRV: nil, explanation: "", source: .history)
}

private func noon(_ dayOfMonth: Int) -> Date {
    local.date(from: DateComponents(year: 2026, month: 11, day: dayOfMonth, hour: 12))!
}

@Test func aNightCountsBeforePulseKnowsYourRecovery() {
    // The owner's first nights: recorded, recovery still being learned.
    let days = [day(18, night: 553), day(19, night: 392), day(20, night: 362), day(21, night: 464)]
    let streak = Streak.days(days, today: noon(21), calendar: local)
    #expect(streak.current == 4 && streak.longest == 4)
    #expect(streak.lastWeek == [false, false, false, true, true, true, true])
}

@Test func todayKeepsTheStreakUntilItsNightIsIn() {
    // The morning before last night has synced: today's row has no night yet.
    let days = [day(19, night: 392), day(20, night: 362), day(21, night: nil)]
    let streak = Streak.days(days, today: noon(21), calendar: local)
    #expect(streak.current == 2)
    #expect(streak.lastWeek.suffix(3) == [true, true, false])
}

@Test func aDayWithoutANightBreaksTheStreak() {
    let days = [day(17, night: 400), day(18, night: 400), day(19, night: nil), day(20, night: 300), day(21, night: 420)]
    let streak = Streak.days(days, today: noon(21), calendar: local)
    #expect(streak.current == 2 && streak.longest == 2)
}

@Test func noDaysMeansNoStreak() {
    let streak = Streak.days([], today: noon(21), calendar: local)
    #expect(streak.current == 0 && streak.longest == 0 && streak.lastWeek == Array(repeating: false, count: 7))
}
