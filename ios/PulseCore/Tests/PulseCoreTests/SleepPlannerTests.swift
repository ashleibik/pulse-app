import Foundation
import Testing
@testable import PulseCore

// Sleep planner (docs/METRICS.md §6): when to go to bed for a wake-up time and a goal.

private let base = Date(timeIntervalSince1970: 1_750_032_000)      // 2025-06-16 00:00 UTC

private var calendar: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(secondsFromGMT: 0)!
    return c
}

/// In bed 23:00 to 06:30 before day `d`, 90% of it asleep.
private func night(_ d: Int) -> SleepSession {
    let start = base.addingTimeInterval(Double(d) * 86_400 - 3600)
    return SleepSession(start: start, end: start.addingTimeInterval(450 * 60), asleepMinutes: 405, awakeMinutes: 45,
                        disturbances: 2, source: .history)
}

/// 20:00 on day 5.
private let evening = base.addingTimeInterval(5 * 86_400 + 20 * 3600)

@Test func eachGoalAimsForItsShareOfTheNeed() throws {
    let nights = (0..<5).map(night)
    let wake = base.addingTimeInterval(6 * 86_400 + 6.5 * 3600)    // the usual 06:30, tomorrow
    for goal in SleepPlanner.Goal.allCases {
        let plan = try #require(SleepPlanner.plan(needMinutes: 480, goal: goal, wakeMinuteOfDay: nil, sleeps: nights,
                                                  now: evening, calendar: calendar))
        #expect(plan.wake == wake)
        #expect(plan.sleepMinutes == Int((480 * goal.share).rounded()))
        // 90% asleep in bed, so the time in bed is the sleep ÷ 0.9.
        #expect(plan.inBedMinutes == Int((Double(plan.sleepMinutes) / 0.9).rounded()))
        #expect(plan.bedtime == wake.addingTimeInterval(-Double(plan.inBedMinutes) * 60))
    }
    #expect(SleepPlanner.Goal.peak.share == 1 && SleepPlanner.Goal.perform.share == 0.85 && SleepPlanner.Goal.getBy.share == 0.70)
}

@Test func aChosenWakeTimeWins() throws {
    let plan = try #require(SleepPlanner.plan(needMinutes: 450, goal: .peak, wakeMinuteOfDay: 5 * 60 + 45, sleeps: (0..<5).map(night),
                                              now: evening, calendar: calendar))
    #expect(plan.wake == base.addingTimeInterval(6 * 86_400 + 5.75 * 3600))
    #expect(plan.bedtime == plan.wake.addingTimeInterval(-500 * 60))   // 450 ÷ 0.9
}

@Test func aWakeTimeLaterTodayIsTodays() throws {
    // At 03:00 a 06:30 wake-up is this morning, not tomorrow.
    let night3 = base.addingTimeInterval(5 * 86_400 + 3 * 3600)
    let plan = try #require(SleepPlanner.plan(needMinutes: 480, goal: .getBy, wakeMinuteOfDay: 390, sleeps: [], now: night3,
                                              calendar: calendar))
    #expect(plan.wake == base.addingTimeInterval(5 * 86_400 + 6.5 * 3600))
}

@Test func withoutNightsThePlanNeedsAWakeTimeAndCountsBedAsSleep() throws {
    #expect(SleepPlanner.plan(needMinutes: 480, goal: .peak, wakeMinuteOfDay: nil, sleeps: [], now: evening, calendar: calendar) == nil)
    let plan = try #require(SleepPlanner.plan(needMinutes: 480, goal: .peak, wakeMinuteOfDay: 420, sleeps: [], now: evening,
                                              calendar: calendar))
    #expect(plan.efficiency == nil && plan.inBedMinutes == 480)
}

@Test func theUsualWakeTimeNeedsThreeNightsAndNapsDontCount() {
    #expect(SleepPlanner.usualWake(sleeps: (0..<2).map(night), calendar: calendar) == nil)
    let nap = SleepSession(start: base.addingTimeInterval(4 * 86_400 + 14 * 3600), end: base.addingTimeInterval(4 * 86_400 + 15 * 3600),
                           asleepMinutes: 50, awakeMinutes: 10, disturbances: 0, isNap: true, source: .history)
    #expect(SleepPlanner.usualWake(sleeps: (0..<3).map(night) + [nap], calendar: calendar) == 390)
}

@Test func theBedtimeRecommendationIsThePeakPlan() throws {
    let nights = (0..<5).map(night)
    let plan = try #require(SleepPlanner.plan(needMinutes: 480, goal: .peak, wakeMinuteOfDay: nil, sleeps: nights, now: evening,
                                              calendar: calendar))
    let bedtime = try #require(Bedtime.recommended(sleeps: nights, needMinutes: 480, now: evening, calendar: calendar))
    #expect(abs(plan.bedtime.timeIntervalSince(bedtime)) <= 60)
}
