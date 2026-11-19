import Foundation
import Testing
@testable import PulseCore

// Sleep consistency, bedtime, respiratory rate, stress, energy, journal, reports, export, live HR.

private let base = Date(timeIntervalSince1970: 1_750_032_000)      // 2025-06-16 00:00 UTC

/// A night that starts `bed` minutes after midnight UTC on day `d` and lasts `length` minutes.
private func night(_ d: Int, bed: Double, length: Double = 450, source: DataSource = .history) -> SleepSession {
    let start = base.addingTimeInterval(Double(d) * 86_400 + bed * 60)
    return SleepSession(start: start, end: start.addingTimeInterval(length * 60), asleepMinutes: Int(length * 0.9),
                        awakeMinutes: Int(length * 0.1), disturbances: 2, source: source)
}

@Test func sleepConsistencyRewardsRegularTimes() {
    let regular = (0..<7).map { night($0, bed: -60) }                       // 23:00 every night
    let irregular = [-180.0, 60, -60, 120, -240, 30, -120].enumerated().map { night($0.offset, bed: $0.element) }
    let steady = SleepConsistency.score(regular, calendar: utcCalendar) ?? 0
    let messy = SleepConsistency.score(irregular, calendar: utcCalendar) ?? 100
    #expect(steady == 100)
    #expect(messy < 60)
    #expect(SleepConsistency.score(Array(regular.prefix(2)), calendar: utcCalendar) == nil)   // too few nights
    // Clock times wrap around midnight: 23:50 and 00:10 are 20 minutes apart, and average to 00:00.
    #expect(SleepConsistency.clockDistance(1430, 10) == 20)
    #expect(abs(SleepConsistency.typicalTime([1430, 10]) - 0) < 0.001 || abs(SleepConsistency.typicalTime([1430, 10]) - 1440) < 0.001)
}

@Test func bedtimeIsUsualWakeMinusNeed() throws {
    // In bed 23:00 -> 06:30 every night, 90% asleep. Need 8h tonight.
    let nights = (0..<5).map { night($0, bed: -60) }
    let now = base.addingTimeInterval(5 * 86_400 + 20 * 3600)                 // 20:00 on day 5
    let bedtime = try #require(Bedtime.recommended(sleeps: nights, needMinutes: 480, now: now, calendar: utcCalendar))
    // Usual wake 06:30 next day; 480 min asleep at 90% efficiency = 533 min in bed -> about 21:37.
    let wake = base.addingTimeInterval(6 * 86_400 + 6.5 * 3600)
    #expect(abs(bedtime.timeIntervalSince(wake) + 480 / 0.9 * 60) < 61)
    #expect(Bedtime.recommended(sleeps: Array(nights.prefix(2)), needMinutes: 480, now: now, calendar: utcCalendar) == nil)
}

/// One hour of beats about a second apart. `wave` gives the change in ms at a time in seconds.
private func beatMinutes(hours: Double = 1, wave: (Double) -> Double) -> [MinuteSample] {
    let origin = Date(timeIntervalSince1970: 1_790_000_040)
    var out: [MinuteSample] = []
    var t = 0.0
    for index in 0..<Int(hours * 60) {
        var rr: [UInt16] = []
        while t < Double(index + 1) * 60 {
            let interval = 1000 + wave(t)
            rr.append(UInt16(interval.rounded()))
            t += interval / 1000
        }
        out.append(MinuteSample(start: origin.addingTimeInterval(Double(index) * 60), heartRate: [UInt8](repeating: 60, count: 60),
                                rrIntervalsMs: rr, activity: [UInt8](repeating: 1, count: 60), source: .history))
    }
    return out
}

@Test func breathingIsReadFromTheRhythmOfTheBeats() throws {
    for breaths in [12.0, 15.0, 18.0] {
        let rate = try #require(RespiratoryRate.night(minutes: beatMinutes { 45 * sin(2 * .pi * breaths / 60 * $0) }))
        #expect(abs(rate - breaths) < 1, "\(breaths) breaths read as \(rate)")
    }
}

@Test func breathingIsWithheldWhenThereIsNoStableRhythm() {
    var random = SeededRandom(seed: 7)
    let noise = beatMinutes { _ in Double(random.next() % 90) - 45 }
    #expect(RespiratoryRate.night(minutes: noise) == nil)
    #expect(RespiratoryRate.night(minutes: beatMinutes(hours: 2.0 / 60) { 45 * sin(2 * .pi * 15 / 60 * $0) }) == nil)   // too little data
}

@Test func theBandsFillerBeatsDontChangeTheBreathingRate() throws {
    var minutes = beatMinutes { 45 * sin(2 * .pi * 15 / 60 * $0) }
    for index in minutes.indices { minutes[index].rrIntervalsMs[index % 40 + 5] = 500 }
    let rate = try #require(RespiratoryRate.night(minutes: minutes))
    #expect(abs(rate - 15) < 1)
}

private func minute(_ index: Int, hr: UInt8, activity: UInt8, source: DataSource = .history) -> MinuteSample {
    MinuteSample(start: base.addingTimeInterval(Double(index) * 60), heartRate: [UInt8](repeating: hr, count: 60),
                 rrIntervalsMs: [], activity: [UInt8](repeating: activity, count: 60), source: source)
}

@Test func stressOnlyCountsStillMinutesAwake() {
    // Resting 60, max 190: 10% of reserve = 73 bpm, 20% = 86 bpm.
    #expect(StressMonitor.level(for: minute(0, hr: 65, activity: 2), restingHR: 60, maxHR: 190) == .calm)
    #expect(StressMonitor.level(for: minute(0, hr: 80, activity: 2), restingHR: 60, maxHR: 190) == .medium)
    #expect(StressMonitor.level(for: minute(0, hr: 100, activity: 2), restingHR: 60, maxHR: 190) == .high)
    #expect(StressMonitor.level(for: minute(0, hr: 130, activity: 80), restingHR: 60, maxHR: 190) == nil)   // moving
    #expect(StressMonitor.level(for: minute(0, hr: 0, activity: 0), restingHR: 60, maxHR: 190) == nil)      // band off

    // 60 min asleep (skipped), 30 calm, 20 walking (skipped), 20 high and still.
    var minutes: [MinuteSample] = []
    for i in 0..<60 { minutes.append(minute(i, hr: 55, activity: 1)) }
    for i in 60..<90 { minutes.append(minute(i, hr: 66, activity: 3)) }
    for i in 90..<110 { minutes.append(minute(i, hr: 110, activity: 70)) }
    for i in 110..<130 { minutes.append(minute(i, hr: 105, activity: 4)) }
    let asleep = SleepSession(start: base, end: base.addingTimeInterval(3600), asleepMinutes: 60, awakeMinutes: 0,
                              disturbances: 0, source: .history)
    let day = StressMonitor.day(minutes: minutes, sleeps: [asleep], restingHR: 60, maxHR: 190,
                                now: base.addingTimeInterval(130 * 60), calendar: utcCalendar)
    #expect(day.calmMinutes == 30 && day.mediumMinutes == 0 && day.highMinutes == 20)
    #expect(day.current == .high)
    #expect(day.hours.count == 2)          // hour 1 (calm) and hour 2 (high); the sleeping hour has nothing
}

@Test func journalComparesTheMorningAfter() {
    // 8 logged days. Alcohol on 4 of them, each followed by a low recovery; the others by a high one.
    var entries: [Date: Set<Habit>] = [:]
    var days: [DailySummary] = []
    for d in 0..<9 {
        let date = base.addingTimeInterval(Double(d) * 86_400)
        let drank = d % 2 == 0 && d < 8
        if d < 8 { entries[date] = drank ? [.alcohol] : [.hydrated] }
        // Day d's recovery reflects what happened on day d-1.
        let previousDrank = d > 0 && (d - 1) % 2 == 0
        days.append(DailySummary(date: date, recoveryScore: d == 0 ? 50 : (previousDrank ? 30 : 70), strain: 10,
                                 sleepMinutes: 420, sleepNeedMinutes: 480, restingHeartRate: 55, hrvRMSSD: 60,
                                 baselineRestingHeartRate: 55, baselineHRV: 60, explanation: "", source: .history))
    }
    let impacts = JournalInsights.impacts(entries: entries, days: days, calendar: utcCalendar)
    let alcohol = impacts.first { $0.habit == .alcohol }
    #expect(alcohol?.daysWith == 4)
    #expect(alcohol?.delta == -40)
    #expect(alcohol?.sentence == "Recovery is 40 points lower the morning after (4 days).")
    // "Late meal" was never logged: nothing to say about it.
    #expect(!impacts.contains { $0.habit == .lateMeal })
    // Too few days: stay quiet instead of drawing a conclusion from two nights.
    let few = entries.filter { $0.key < base.addingTimeInterval(3 * 86_400) }
    #expect(JournalInsights.impacts(entries: few, days: days, calendar: utcCalendar).isEmpty)
}

@Test func periodReportSummarizesTheDemoMonth() {
    let report = PeriodReport.make(days: computed.days, sleeps: computed.sleeps, workouts: dataset.workouts,
                                   period: 7, calendar: utcCalendar)
    let labels = report.lines.map(\.label)
    for expected in ["Recovery", "Best day", "Toughest day", "Sleep per night", "Strain per day", "Workouts"] {
        #expect(labels.contains(expected), "missing \(expected)")
    }
    #expect(report.lines.allSatisfy { !$0.value.isEmpty })
    #expect(PeriodReport.make(days: [], sleeps: [], workouts: [], period: 7, calendar: utcCalendar).lines.isEmpty)
}

@Test func exportIsValidJSONWithoutRawHeartbeats() throws {
    let data = try DataExport.json(days: computed.days, sleeps: computed.sleeps, workouts: dataset.workouts,
                                   journal: [base: [.alcohol, .lateMeal]], calendar: utcCalendar, now: base)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["app"] as? String == "Pulse")
    #expect((object["days"] as? [Any])?.count == computed.days.count)
    let journal = try #require(object["journal"] as? [[String: Any]])
    #expect(journal.first?["day"] as? String == "2025-06-16")
    #expect(journal.first?["habits"] as? [String] == ["alcohol", "lateMeal"])
    let text = String(decoding: data, as: UTF8.self)
    #expect(!text.contains("heartRate") && !text.contains("rrIntervals"))     // summaries only
}

@Test func simulatedBandStreamsLiveHeartRate() {
    var band = SimulatedBand(samples: [])
    #expect(!band.realtimeOn)
    var session = BandSession()
    var effects = session.setLive(true)
    guard case .write(let bytes, let description) = effects.last else { Issue.record("expected a write"); return }
    #expect(description == "TOGGLE_REALTIME_HR")
    _ = band.receive(write: bytes)
    #expect(band.realtimeOn)

    // A live packet from the band becomes a heart-rate reading in the session.
    let frame = SimulatedBand.realtimeFrame(timestamp: 1_750_000_000, heartRate: 132)
    effects = session.receive(characteristic: Whoop.dataUUID, bytes: frame, now: 1_750_000_000)
    #expect(effects.contains(.liveHeartRate(132)))

    guard case .write(let off, _) = session.setLive(false).last else { Issue.record("expected a write"); return }
    _ = band.receive(write: off)
    #expect(!band.realtimeOn)
}
