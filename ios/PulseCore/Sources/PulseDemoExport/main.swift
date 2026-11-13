import Foundation
import PulseCore

// Prints the demo month as JSON: simulated raw data -> real MetricsEngine -> real Insights.
// Everything a screen shows comes from the same PulseCore functions the iOS app calls.

struct Export: Encodable {
    struct Day: Encodable {
        let date: String
        let recovery: Double?
        let zone: String?
        let word: String?          // "Ready" / "Steady" / "Rest"
        let strain: Double
        let sleepMinutes: Int?
        let sleepNeedMinutes: Int
        let restingHR: Double?
        let hrv: Double?
        let baselineRHR: Double?
        let baselineHRV: Double?
        let explanation: String
    }
    struct Factor: Encodable { let title: String; let detail: String; let points: Double }
    struct Segment: Encodable { let start: String; let end: String; let phase: String }
    struct Point: Encodable { let t: String; let bpm: Double }
    struct WorkoutOut: Encodable {
        let kind: String; let name: String; let start: String; let minutes: Int
        let avgHR: Int; let maxHR: Int; let strain: Double; let calories: Int; let zoneMinutes: [Int]
    }
    struct Night: Encodable {
        let start: String; let end: String; let asleep: Int; let awake: Int; let disturbances: Int
        let efficiency: Double; let segments: [Segment]; let totals: [String: Int]; let heartRate: [Point]
        let needGoal: Double; let needStrain: Double; let needDebt: Double; let needTotal: Double
    }
    struct InsightOut: Encodable { let title: String; let detail: String; let tone: String; let symbol: String }
    /// `caption` is the change in words ("▲ 3 better"), from TrendInsights.changeCaption.
    struct Comparison: Encodable { let current: Double?; let delta: Double?; let caption: String }

    let generatedAt: String
    let algorithmVersion: Int
    let maxHR: Double
    let days: [Day]
    let factors: [Factor]
    let reason: String             // the one line under the recovery word on Today
    let strainTarget: [Double]
    let strainAdvice: String
    let tonightNeed: Int
    let lastNight: Night?
    let workouts: [WorkoutOut]
    let todayZoneMinutes: [Int]
    let insights: [InsightOut]
    let week: [String: Comparison]     // last 7 days vs the 7 before
    let month: [String: Comparison]    // last 30 days vs the 30 before
}

let calendar = Calendar.current
let now = Date()
let profile = MetricsProfile(maxHeartRate: 190)
let config = FakeDataConfig(days: 30, seed: 42, endDate: now)
let data = DemoData.make(config: config, profile: profile, calendar: calendar)

let iso = ISO8601DateFormatter()
iso.formatOptions = [.withInternetDateTime]
iso.timeZone = TimeZone.current
@MainActor func s(_ d: Date) -> String { iso.string(from: d) }

let days = data.days
guard let today = days.last else { fatalError("no days") }

// Recovery factors + strain guidance (same calls as RecoveryDetailView / TodayView)
let breakdown = RecoveryExplainer.breakdown(for: today, history: days)
let target = StrainGuidance.targetRange(recovery: today.recoveryScore)
let tonight = Recovery.sleepNeed(goal: profile.sleepGoalMinutes, previousStrain: today.strain,
                                 previousNeed: Double(today.sleepNeedMinutes),
                                 previousAsleep: today.sleepMinutes.map { Double($0) })

// Last night (same calls as SleepView)
var night: Export.Night?
if let sleep = data.sleeps.filter({ !$0.isNap }).max(by: { $0.end < $1.end }) {
    let minutes = data.minutes.filter { $0.start >= sleep.start && $0.start < sleep.end }
    let segments = SleepTimeline.build(minutes: minutes, from: sleep.start, to: sleep.end)
    let totals = SleepTimeline.totals(segments)
    let hr = stride(from: 0, to: minutes.count, by: 5).compactMap { i -> Export.Point? in
        let chunk = minutes[i..<min(i + 5, minutes.count)].compactMap(\.averageHeartRate)
        guard !chunk.isEmpty else { return nil }
        return Export.Point(t: s(minutes[i].start), bpm: (chunk.reduce(0, +) / Double(chunk.count) * 10).rounded() / 10)
    }
    let previous = days.count >= 2 ? days[days.count - 2] : nil
    let need = SleepNeedBreakdown(goal: profile.sleepGoalMinutes, previousStrain: previous?.strain,
                                  previousNeed: previous.map { Double($0.sleepNeedMinutes) },
                                  previousAsleep: previous?.sleepMinutes.map { Double($0) })
    night = Export.Night(start: s(sleep.start), end: s(sleep.end), asleep: sleep.asleepMinutes, awake: sleep.awakeMinutes,
                         disturbances: sleep.disturbances, efficiency: sleep.efficiency,
                         segments: segments.map { Export.Segment(start: s($0.start), end: s($0.end), phase: $0.phase.rawValue) },
                         totals: Dictionary(uniqueKeysWithValues: totals.map { ($0.key.rawValue, $0.value) }),
                         heartRate: hr, needGoal: need.goal, needStrain: need.strainExtra, needDebt: need.debtExtra,
                         needTotal: need.total)
}

// Workouts (last 14 days) and today's zones (same calls as ActivityView)
let cutoff = calendar.date(byAdding: .day, value: -14, to: now)!
let workouts = data.workouts.filter { $0.start >= cutoff }.sorted { $0.start > $1.start }.map { w in
    Export.WorkoutOut(kind: w.kind.rawValue, name: w.kind.displayName, start: s(w.start), minutes: w.durationMinutes,
                      avgHR: w.averageHeartRate, maxHR: w.maxHeartRate, strain: (w.strain * 10).rounded() / 10,
                      calories: w.calories, zoneMinutes: w.zoneSeconds.map { $0 / 60 })
}
let startOfToday = calendar.startOfDay(for: now)
let todayZones = HeartRateZones.minutesPerZone(data.minutes.filter { $0.start >= startOfToday }.map(\.averageHeartRate),
                                               maxHeartRate: profile.maxHeartRate)

// Trends (same calls as TrendsView)
let insights = TrendInsights.insights(days).map {
    Export.InsightOut(title: $0.title, detail: $0.detail, tone: $0.tone.rawValue, symbol: $0.symbolName)
}
let wholeNumber: (Double) -> String = { String(format: "%.0f", $0) }
let asDuration: (Double) -> String = { PulseFormat.duration(minutes: Int($0.rounded())) }
@MainActor func cmp(_ period: Int, higherIsBetter: Bool = true, format: (Double) -> String,
         _ f: (DailySummary) -> Double?) -> Export.Comparison {
    let c = TrendInsights.compare(days, period: period, f)
    return Export.Comparison(current: c.current, delta: c.delta,
                             caption: TrendInsights.changeCaption(c.delta, higherIsBetter: higherIsBetter, format: format))
}
@MainActor func comparisons(_ period: Int) -> [String: Export.Comparison] {
    ["recovery": cmp(period, format: wholeNumber) { $0.recoveryScore },
     "hrv": cmp(period, format: wholeNumber) { $0.hrvRMSSD },
     "restingHR": cmp(period, higherIsBetter: false, format: wholeNumber) { $0.restingHeartRate },
     "sleep": cmp(period, format: asDuration) { $0.sleepMinutes.map { Double($0) } }]
}

let export = Export(
    generatedAt: s(now),
    algorithmVersion: MetricsEngine.algorithmVersion,
    maxHR: profile.maxHeartRate,
    days: days.map { d in
        Export.Day(date: s(d.date), recovery: d.recoveryScore, zone: d.recoveryZone?.rawValue,
                   word: d.recoveryZone?.word, strain: d.strain,
                   sleepMinutes: d.sleepMinutes, sleepNeedMinutes: d.sleepNeedMinutes, restingHR: d.restingHeartRate,
                   hrv: d.hrvRMSSD, baselineRHR: d.baselineRestingHeartRate, baselineHRV: d.baselineHRV,
                   explanation: d.explanation)
    },
    factors: breakdown?.factors.map { Export.Factor(title: $0.title, detail: $0.detail, points: $0.points) } ?? [],
    reason: RecoveryExplainer.oneLine(breakdown),
    strainTarget: [target.lowerBound, target.upperBound],
    strainAdvice: StrainGuidance.advice(strain: today.strain, recovery: today.recoveryScore),
    tonightNeed: Int(tonight.rounded()),
    lastNight: night,
    workouts: workouts,
    todayZoneMinutes: todayZones,
    insights: insights,
    week: comparisons(7),
    month: comparisons(30)
)

let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
FileHandle.standardOutput.write(try encoder.encode(export))
