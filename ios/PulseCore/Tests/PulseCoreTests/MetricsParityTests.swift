import Foundation
import Testing
@testable import PulseCore

/// Swift must reproduce the Python reference (re-toolkit/metrics) on shared/test-vectors/metrics_v1.json.
/// If a test here fails, either the two implementations drifted apart or the vectors are stale
/// (regenerate with `python -m tools.make_metric_vectors` in re-toolkit/).

struct Vectors: Decodable {
    struct RRClean: Decodable { let input: [Double]; let expected: [Double?] }
    struct RMSSD: Decodable { let input: [Double?]; let minPairs: Int; let expected: Double? }
    struct Overnight: Decodable { let minuteRr: [[Double]]; let asleep: [Bool]; let expected: Double? }
    struct Resting: Decodable { let minuteHr: [Double?]; let window: Int; let expected: Double? }
    struct ColeKripke: Decodable { let activity: [Double?]; let expected: [Double] }
    struct SleepCase: Decodable {
        struct S: Decodable { let start, end, asleep, awake, disturbances: Int; let isNap: Bool }
        let hr: [Double?]; let activity: [Double?]; let blocks: [Int]?
        let expectedAsleep: [Bool]; let expectedSessions: [S]
    }
    struct StrainCase: Decodable {
        let name: String; let minuteHr: [Double?]; let resting, maximum: Double; let sex: String
        let expectedTrimp, expectedStrain: Double
    }
    struct NeedCase: Decodable {
        let goal: Double; let previousStrain, previousNeed, previousAsleep: Double?; let expected: Double
    }
    struct RecoveryCase: Decodable {
        let name: String; let hrv, rhr, sleepMinutes: Double?; let need: Double
        let baselineHrv, baselineRhr: [Double]; let expected: Double?
    }

    let algorithmVersion: Int
    let tolerance: Double
    let rrClean: [RRClean]
    let rmssd: [RMSSD]
    let overnightRmssd: [Overnight]
    let restingHr: [Resting]
    let coleKripke: [ColeKripke]
    let sleep: [SleepCase]
    let strain: [StrainCase]
    let sleepNeed: [NeedCase]
    let recovery: [RecoveryCase]

    static func load() throws -> Vectors {
        // This file: <repo>/ios/PulseCore/Tests/PulseCoreTests/MetricsParityTests.swift
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = repo.appendingPathComponent("shared/test-vectors/metrics_v1.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Vectors.self, from: Data(contentsOf: url))
    }
}

let vectors: Vectors = try! Vectors.load()

func close(_ a: Double?, _ b: Double?, _ tol: Double = vectors.tolerance) -> Bool {
    switch (a, b) {
    case (nil, nil): return true
    case let (x?, y?): return abs(x - y) <= tol * max(1, abs(y))
    default: return false
    }
}

@Test func vectorsMatchThisAlgorithmVersion() {
    #expect(vectors.algorithmVersion == MetricsEngine.sharedFormulaVersion)
}

@Test func parityRRClean() {
    for c in vectors.rrClean {
        let got = HRV.cleanRR(c.input)
        #expect(got.count == c.expected.count)
        #expect(zip(got, c.expected).allSatisfy { close($0, $1) })
    }
}

@Test func parityRMSSD() {
    for c in vectors.rmssd {
        #expect(close(HRV.rmssd(c.input, minPairs: c.minPairs), c.expected))
    }
}

@Test func parityOvernightRMSSD() {
    for c in vectors.overnightRmssd {
        #expect(close(HRV.overnightRMSSD(minuteRR: c.minuteRr, asleep: c.asleep), c.expected))
    }
}

@Test func parityRestingHR() {
    for c in vectors.restingHr {
        #expect(close(RestingHeartRate.lowestSustained(c.minuteHr, window: c.window), c.expected))
    }
}

@Test func parityColeKripke() {
    for c in vectors.coleKripke {
        let got = SleepDetector.coleKripke(c.activity)
        #expect(zip(got, c.expected).allSatisfy { close($0, $1) } && got.count == c.expected.count)
    }
}

@Test func paritySleepDetection() {
    for c in vectors.sleep {
        let flags = SleepDetector.classify(hr: c.hr, activity: c.activity, blocks: c.blocks)
        #expect(flags == c.expectedAsleep)
        let sessions = SleepDetector.sessions(flags)
        #expect(sessions.count == c.expectedSessions.count)
        for (got, want) in zip(sessions, c.expectedSessions) {
            #expect(got == SleepDetector.Session(start: want.start, end: want.end, asleep: want.asleep,
                                                 awake: want.awake, disturbances: want.disturbances,
                                                 isNap: want.isNap))
        }
    }
}

@Test func parityStrain() {
    for c in vectors.strain {
        let t = Strain.trimp(c.minuteHr, resting: c.resting, maximum: c.maximum,
                             sex: BiologicalSex(rawValue: c.sex) ?? .unspecified)
        #expect(close(t, c.expectedTrimp), "\(c.name)")
        #expect(close(Strain.fromTRIMP(t), c.expectedStrain), "\(c.name)")
    }
}

@Test func paritySleepNeed() {
    for c in vectors.sleepNeed {
        let got = Recovery.sleepNeed(goal: c.goal, previousStrain: c.previousStrain,
                                     previousNeed: c.previousNeed, previousAsleep: c.previousAsleep)
        #expect(close(got, c.expected))
    }
}

@Test func parityRecovery() {
    for c in vectors.recovery {
        let got = Recovery.score(hrv: c.hrv, rhr: c.rhr, sleepMinutes: c.sleepMinutes, need: c.need,
                                 baselineHRV: c.baselineHrv, baselineRHR: c.baselineRhr)
        #expect(close(got, c.expected), "\(c.name): swift \(String(describing: got)) python \(String(describing: c.expected))")
    }
}
