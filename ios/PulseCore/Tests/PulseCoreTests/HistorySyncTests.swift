import Foundation
import Testing
@testable import PulseCore

/// End to end without hardware: SimulatedBand <-> notification chunks <-> FrameReassembler
/// <-> decode <-> HistorySync <-> "database". Exactly the path the iOS app will run.

struct SyncHarness {
    var band: SimulatedBand
    var sync = HistorySync()
    var reassemblers: [String: Whoop.FrameReassembler] = [:]
    var saved: [Whoop.HistoryRecord] = []
    var savedTokens: [[UInt8]] = []
    var finished: (batches: Int, records: Int)?
    var failure: String?
    /// Turn off to simulate the app crashing/forgetting to confirm a save.
    var confirmSaves = true

    init(band: SimulatedBand) { self.band = band }

    mutating func run(maxSteps: Int = 10_000) {
        var queue = sync.start()
        var steps = 0
        while !queue.isEmpty && steps < maxSteps {
            steps += 1
            let action = queue.removeFirst()
            switch action {
            case .send(let bytes, _):
                for n in band.receive(write: bytes) {
                    var r = reassemblers[n.characteristic] ?? Whoop.FrameReassembler()
                    let frames = r.feed(n.bytes)
                    reassemblers[n.characteristic] = r
                    for f in frames where f.valid && n.characteristic == Whoop.dataUUID {
                        queue += sync.handle(Whoop.decode(f))
                    }
                }
            case .persist(let records, let token):
                // The ack must not exist yet: the band hasn't seen it, and it's only created below.
                #expect(!band.acksReceived.contains(token))
                guard confirmSaves else { continue }
                saved += records
                savedTokens.append(token)
                queue += sync.didPersist(token: token, recordCount: records.count)
            case .finished(let batches, let records):
                finished = (batches, records)
            case .failed(let message):
                failure = message
            }
        }
    }
}

func samples(_ count: Int, start: UInt32 = 1_750_000_000) -> [SimulatedBand.Sample] {
    (0..<count).map { i in
        SimulatedBand.Sample(timestamp: start + UInt32(i), heartRate: UInt8(55 + i % 20), accel: [0.01, -0.02, 0.99])
    }
}

@Test func downloadsEveryRecordExactlyOnce() {
    var h = SyncHarness(band: SimulatedBand(samples: samples(250), batchSize: 100, mtuPayload: 20))
    h.run()
    #expect(h.failure == nil)
    #expect(h.finished?.batches == 3 && h.finished?.records == 250)
    #expect(h.saved.count == 250)
    #expect(h.saved.map(\.timestamp) == (0..<250).map { 1_750_000_000 + UInt32($0) })
    #expect(h.band.acksReceived == h.savedTokens)          // every ack matches a saved batch, in order
    #expect(h.sync.state == .complete)
}

@Test func neverAcksWithoutConfirmedSave() {
    var h = SyncHarness(band: SimulatedBand(samples: samples(150), batchSize: 100))
    h.confirmSaves = false
    h.run()
    #expect(h.band.acksReceived.isEmpty)
    #expect(h.sync.state == .waitingForSave(token: SimulatedBand.token(forBatch: 0)))
    // A confirmation for some OTHER token does nothing.
    var sync = h.sync
    #expect(sync.didPersist(token: SimulatedBand.token(forBatch: 7), recordCount: 100).isEmpty)
    // The right one produces exactly one ack.
    let actions = sync.didPersist(token: SimulatedBand.token(forBatch: 0), recordCount: 100)
    #expect(actions.count == 1)
    if case .send(_, let description) = actions.first { #expect(description == "HISTORY_ACK") }
}

@Test func lostNotificationMeansRetryNotHalfSave() {
    var band = SimulatedBand(samples: samples(250), batchSize: 100, mtuPayload: 20)
    band.dropNotificationIndex = 30          // lose a chunk in the middle of batch 1
    var h = SyncHarness(band: band)
    h.run()
    #expect(h.failure == nil)
    #expect(h.sync.retries == 0)              // reset after the successful retry
    #expect(h.saved.count == 250)             // nothing missing, nothing duplicated
    #expect(Set(h.saved.map(\.timestamp)).count == 250)
    #expect(h.band.commandsReceived.filter { $0 == "SEND_HISTORICAL_DATA" }.count == 2)
}

@Test func givesUpAfterRepeatedLosses() {
    var sync = HistorySync(maxRetries: 2)
    _ = sync.start()
    let incompleteEnd = Whoop.Packet.metadata(Whoop.Metadata(metaType: 2, metaName: "HISTORY_END", timestamp: nil,
                                                             expectedPackets: 100, token: [1, 2, 3, 4, 5, 6, 7, 8]))
    #expect(sync.handle(incompleteEnd).count == 1)   // retry 1
    #expect(sync.handle(incompleteEnd).count == 1)   // retry 2
    let last = sync.handle(incompleteEnd)
    guard case .failed = last.first else { Issue.record("expected failure"); return }
    #expect(sync.state != .receiving)
}

@Test func emptyBandFinishesImmediately() {
    var h = SyncHarness(band: SimulatedBand(samples: []))
    h.run()
    #expect(h.finished?.batches == 0 && h.saved.isEmpty)
}

// MARK: - Minute builder + full pipeline

@Test func minuteBuilderGroupsSeconds() {
    // 1_749_999_980 is 20 seconds past a whole minute (1_749_999_960 = 29_166_666 x 60).
    let records = samples(150, start: 1_749_999_980).map { s in
        Whoop.HistoryRecord(version: 24, counter: 0, timestamp: s.timestamp, subsec: 0, heartRate: Int(s.heartRate),
                            accelG: [0, 0, 1.1], rrMsUnverified: [], length: 88)
    }
    let minutes = MinuteBuilder.minutes(from: records)
    #expect(minutes.count == 3)                                  // :20-:59, full minute, :00-:49
    #expect(minutes[0].heartRate.prefix(20).allSatisfy { $0 == 0 })
    #expect(minutes[1].heartRate.allSatisfy { $0 > 0 })
    #expect(minutes[0].activity[30] == 50)                       // |1.1 - 1| x 500
    #expect(MinuteBuilder.activity(accelG: [0, 0, 1]) == 0)
    #expect(MinuteBuilder.activity(accelG: nil) == 0)
}

@Test func bandBytesBecomeTheSameSleepAsTheSimulation() throws {
    // Take one simulated night, turn it into per-second band records (HR + an accel vector whose
    // magnitude encodes the activity), push it through the whole BLE pipeline, rebuild minutes,
    // and check the metrics engine finds the same night as it does on the original minutes.
    let cal = utcCalendar
    let night = try #require(dataset.sleeps.first)
    let window = dataset.minutes.filter {
        $0.start >= night.start.addingTimeInterval(-3 * 3600) && $0.start < night.end.addingTimeInterval(3 * 3600)
    }
    var band: [SimulatedBand.Sample] = []
    for m in window {
        for s in 0..<60 {
            let a = Float(m.activity[s]) / Float(MinuteBuilder.activityScale)
            band.append(SimulatedBand.Sample(timestamp: UInt32(m.start.timeIntervalSince1970) + UInt32(s),
                                             heartRate: m.heartRate[s], accel: [0, 0, 1 + a]))
        }
    }
    var h = SyncHarness(band: SimulatedBand(samples: band, batchSize: 3600, mtuPayload: 182))
    h.run(maxSteps: 100_000)
    #expect(h.saved.count == band.count)

    let rebuilt = MinuteBuilder.minutes(from: h.saved)
    #expect(rebuilt.count == window.count)
    #expect(zip(rebuilt, window).allSatisfy { $0.heartRate == $1.heartRate })

    let end = night.end.addingTimeInterval(3 * 3600)
    let direct = MetricsEngine.run(minutes: window, calendar: cal, now: end).sleeps.filter { !$0.isNap }
    let viaBand = MetricsEngine.run(minutes: rebuilt, calendar: cal, now: end).sleeps.filter { !$0.isNap }
    #expect(direct.count == 1 && viaBand.count == 1)
    #expect(viaBand.first?.start == direct.first?.start && viaBand.first?.end == direct.first?.end)
}
