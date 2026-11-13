import Foundation
import Testing
@testable import PulseCore

// MARK: - Hand-checked examples (same as re-toolkit/tests/test_metrics.py)

@Test func rmssdByHand() {
    // diffs 10, -20, 10 -> sqrt((100 + 400 + 100) / 3) = sqrt(200)
    #expect(abs(HRV.rmssd([800, 810, 790, 800], minPairs: 1)! - 200.0.squareRoot()) < 1e-12)
    #expect(HRV.rmssd([800, 810, 790, 800]) == nil)
    #expect(HRV.rmssd([900, nil, 950, 950], minPairs: 1) == 0)   // never pairs across a gap
}

@Test func cleanRRRejectsMissedAndImpossibleBeats() {
    var rr = [Double](repeating: 900, count: 21)
    rr[10] = 1800
    rr[15] = 2600
    let out = HRV.cleanRR(rr)
    #expect(out[10] == nil && out[15] == nil)
    #expect(out.filter { $0 == nil }.count == 2)
}

@Test func restlessPatchStaysInsideTheNight() {
    // Found by the truth tests: five wake-ups in 45 minutes used to split a night in two.
    let restless = Array(([[Bool]](repeating: Array(repeating: true, count: 5) + Array(repeating: false, count: 4),
                                   count: 5)).joined())
    let flags = Array(repeating: true, count: 60) + restless + Array(repeating: true, count: 60)
    let s = SleepDetector.sessions(flags)
    #expect(s.count == 1 && s.first?.span == flags.count && s.first?.disturbances == 5)
    let awakeGap = Array(repeating: true, count: 60) + Array(repeating: false, count: 45) + Array(repeating: true, count: 60)
    #expect(SleepDetector.sessions(awakeGap).count == 2)
}

@Test func strainCalibration() {
    #expect(Strain.trimp([Double?](repeating: 60, count: 600), resting: 55, maximum: 190) == 0)
    let run = Strain.trimp([Double?](repeating: 55 + 0.8 * 135, count: 60), resting: 55, maximum: 190)
    #expect(abs(Strain.fromTRIMP(run) - 14) < 0.5)
    #expect(Strain.estimatedMaxHeartRate(age: 30) == 187)
}

@Test func recoveryAtBaselineIsAboutFifty() {
    let score = Recovery.score(hrv: 60, rhr: 54, sleepMinutes: 432, need: 480,
                               baselineHRV: [60, 62, 58, 61, 59], baselineRHR: [54, 55, 53, 54, 54])
    #expect(abs(score! - 50) < 1.5)
    #expect(Recovery.score(hrv: 60, rhr: 54, sleepMinutes: 432, need: 480,
                           baselineHRV: [60, 62, 58], baselineRHR: [54, 55, 53]) == nil)
}

@Test func learningExplanation() {
    #expect(PulseFormat.learningExplanation(nightsSoFar: 2, needed: 4, sleepMinutes: 460, sleepNeedMinutes: 480)
            == "Pulse is still learning your normal (2 of 4 nights). You got 7h 40m of sleep.")
}

// MARK: - Does the engine recover the simulation's truth?
// `dataset`, `config30`, `fixedEnd` and `utc` come from FakeDataGeneratorTests.swift.

var utcCalendar: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = utc
    return c
}

let computed = MetricsEngine.run(minutes: dataset.minutes, profile: MetricsProfile(maxHeartRate: 190),
                                 calendar: utcCalendar, now: fixedEnd)

@Test func engineProducesOneSummaryPerDay() {
    #expect(computed.days.map(\.date) == dataset.days.map(\.date))
    #expect(computed.days.allSatisfy { $0.source == .simulated })
}

@Test func engineFindsEveryNight() {
    let mains = computed.sleeps.filter { !$0.isNap }
    #expect(mains.count == dataset.sleeps.count)
    #expect(computed.sleeps.filter(\.isNap).isEmpty)     // the simulation has no naps
    for truth in dataset.sleeps {
        guard let found = mains.first(where: { $0.start < truth.end && truth.start < $0.end }) else {
            Issue.record("no session found for night starting \(truth.start)")
            continue
        }
        #expect(abs(found.start.timeIntervalSince(truth.start)) <= 10 * 60, "onset \(found.start) vs \(truth.start)")
        #expect(abs(found.end.timeIntervalSince(truth.end)) <= 10 * 60, "wake \(found.end) vs \(truth.end)")
        // Known limitation (docs/METRICS.md §8): Cole-Kripke also scores the ~3-4 minutes after each
        // wake-up as awake, so asleep time reads low on restless nights. Allowed: 5% + 4 min per wake-up.
        let errorMinutes = abs(found.asleepMinutes - truth.asleepMinutes)
        let allowed = Int(0.05 * Double(truth.asleepMinutes)) + 4 * truth.disturbances
        #expect(errorMinutes <= allowed, "asleep \(found.asleepMinutes) vs truth \(truth.asleepMinutes), allowed ±\(allowed)")
        #expect(found.disturbances >= truth.disturbances - 2)
    }
}

@Test func engineRecoversRestingHRAndHRV() {
    for (got, truth) in zip(computed.days, dataset.days) {
        guard let rhr = got.restingHeartRate, let hrv = got.hrvRMSSD,
              let trueRHR = truth.restingHeartRate, let trueHRV = truth.hrvRMSSD else {
            Issue.record("missing night metrics on \(got.date)")
            continue
        }
        #expect(abs(rhr - trueRHR) <= 1.5, "RHR \(rhr) vs truth \(trueRHR) on \(got.date)")
        #expect(abs(hrv - trueHRV) / trueHRV <= 0.12, "HRV \(hrv) vs truth \(trueHRV) on \(got.date)")
    }
}

@Test func recoveryNeedsABaselineThenTracksTheTruth() {
    // First 4 days: still learning.
    #expect(computed.days.prefix(4).allSatisfy { $0.recoveryScore == nil })
    #expect(computed.days[0].explanation.hasPrefix("Pulse is still learning your normal (0 of 4 nights)"))
    #expect(computed.days.dropFirst(4).allSatisfy { $0.recoveryScore != nil })

    // Afterwards, computed recovery should rise and fall with the simulation's hidden readiness.
    var xs: [Double] = [], ys: [Double] = []
    for (got, truth) in zip(computed.days, dataset.days) {
        if let a = got.recoveryScore, let b = truth.recoveryScore { xs.append(a); ys.append(b) }
    }
    #expect(pearson(xs, ys) > 0.6, "correlation \(pearson(xs, ys))")
}

@Test func trainingDaysHaveMoreStrain() {
    let cal = utcCalendar
    let trainingDays = Set(dataset.workouts.filter { $0.kind != .walk }.map { cal.startOfDay(for: $0.start) })
    let training = computed.days.filter { trainingDays.contains($0.date) }.map(\.strain)
    let rest = computed.days.filter { !trainingDays.contains($0.date) }.map(\.strain)
    #expect(!training.isEmpty && !rest.isEmpty)
    #expect(mean(training) > mean(rest) + 3, "training \(mean(training)) vs rest \(mean(rest))")
    #expect(computed.days.allSatisfy { (0...21).contains($0.strain) })
}

@Test func demoDataUsesComputedNumbers() {
    let small = FakeDataConfig(days: 6, seed: 3, endDate: fixedEnd, timeZone: utc)
    let demo = DemoData.make(config: small, calendar: utcCalendar)
    #expect(demo.days.count == 6)
    #expect(demo.days.prefix(4).allSatisfy { $0.recoveryScore == nil })   // honest: no baseline yet
    #expect(demo.workouts.allSatisfy { (0...21).contains($0.strain) })
    let runs = demo.workouts.filter { $0.kind == .run || $0.kind == .hiit }.map(\.strain)
    let walks = demo.workouts.filter { $0.kind == .walk }.map(\.strain)
    if !runs.isEmpty && !walks.isEmpty { #expect(mean(runs) > mean(walks)) }
}

func pearson(_ xs: [Double], _ ys: [Double]) -> Double {
    let mx = mean(xs), my = mean(ys)
    var sxy = 0.0, sxx = 0.0, syy = 0.0
    for (x, y) in zip(xs, ys) {
        sxy += (x - mx) * (y - my)
        sxx += (x - mx) * (x - mx)
        syy += (y - my) * (y - my)
    }
    return sxy / (sxx * syy).squareRoot()
}
