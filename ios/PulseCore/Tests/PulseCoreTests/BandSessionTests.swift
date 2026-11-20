import Foundation
import Testing
@testable import PulseCore

/// The whole "connected -> history saved" conversation, against the simulated band.
/// `samples(_:start:)` comes from HistorySyncTests.swift; `dataset` / `computed` from the metrics tests.

struct SessionHarness {
    var band: SimulatedBand
    var session = BandSession()
    var now: Double
    var saved: [Whoop.HistoryRecord] = []
    var writes: [String] = []
    var finishedRecords: Int?
    var failure: String?
    var lastInfo: BandSession.Info?
    var logLines = 0
    var trace: [String] = []
    var progressReports = 0
    var fractions: [Double?] = []

    init(band: SimulatedBand, now: Double) {
        self.band = band
        self.now = now
    }

    /// Runs until nothing is left to do. `answerClock: false` simulates a band that ignores GET_CLOCK.
    /// `effects`: start from these instead of a fresh hello (e.g. `pullAgain()` on a kept connection).
    mutating func run(answerClock: Bool = true, maxSteps: Int = 200_000, effects: [BandSession.Effect]? = nil) {
        var queue = effects ?? session.start()
        var steps = 0
        while steps < maxSteps {
            steps += 1
            if queue.isEmpty {
                // Nothing pending. If we are still waiting for the clock, the app's timer would fire now.
                guard session.phase == .hello else { break }
                queue += session.clockTimedOut(now: now)
                continue
            }
            switch queue.removeFirst() {
            case .write(let bytes, let description):
                writes.append(description)
                if !answerClock && description.hasPrefix("GET_CLOCK") { continue }
                for n in band.receive(write: bytes) {
                    queue += session.receive(characteristic: n.characteristic, bytes: n.bytes, now: now)
                }
            case .persist(let records, let token):
                #expect(!band.acksReceived.contains(token))     // never acked before it is saved
                saved += records
                queue += session.didPersist(token: token, recordCount: records.count)
            case .info(let info): lastInfo = info
            case .progress(let p): progressReports += 1; fractions.append(p.fraction)
            case .liveHeartRate, .rawMotion: break
            case .finished(let records): finishedRecords = records
            case .failed(let message): failure = message
            case .log: logLines += 1
            case .trace(let line): trace.append(line)
            }
        }
    }
}

@Test func sessionSaysHelloThenDownloadsEverything() {
    let start: UInt32 = 1_750_000_000
    var h = SessionHarness(band: SimulatedBand(samples: samples(250, start: start), batchSize: 100, mtuPayload: 20,
                                               clock: start + 250), now: Double(start) + 251)
    h.run()
    #expect(h.failure == nil)
    #expect(h.finishedRecords == 250)
    #expect(h.saved.map(\.timestamp) == (0..<250).map { start + UInt32($0) })
    #expect(h.session.phase == .finished)
    #expect(h.lastInfo?.batteryPercent == 76.5)
    #expect(h.lastInfo?.clockWasSet == true)                    // set on every connect
    #expect(h.writes.prefix(9) == ["TOGGLE_REALTIME_HR off", "SEND_R10_R11_REALTIME off", "GET_BATTERY_LEVEL",
                                   "REPORT_VERSION_INFO", "GET_CLOCK", "GET_DATA_RANGE", "SET_CLOCK", "GET_CLOCK (check)",
                                   "SEND_HISTORICAL_DATA"])
    #expect(h.band.rawStreamOn == false)                        // a stream left on by a cut-short step test stops
    #expect(h.lastInfo?.bandClockSource == "GET_CLOCK")
    #expect(h.lastInfo?.clockOffsetSeconds.map { abs($0) < 2 } == true)   // read back after setting
    #expect(h.band.realtimeOn == false)
    #expect(h.writes.filter { $0 == "HISTORY_ACK" }.count == 3)
    #expect(h.progressReports == 3)
    #expect(h.session.badFrames == 0)
}

@Test func aKeptConnectionPullsOnlyWhatIsNewWithoutSayingHelloAgain() {
    let start: UInt32 = 1_750_000_000
    var h = SessionHarness(band: SimulatedBand(samples: samples(150, start: start), batchSize: 100, mtuPayload: 20,
                                               clock: start + 150), now: Double(start) + 151)
    h.run()
    #expect(h.finishedRecords == 150)

    // Five minutes later, still connected: the band recorded 60 more seconds.
    h.band.record(samples(60, start: start + 150))
    h.writes = []
    h.finishedRecords = nil
    let pull = h.session.pullAgain()
    h.run(effects: pull)
    #expect(h.failure == nil)
    #expect(h.finishedRecords == 60)
    #expect(h.writes.prefix(3) == ["GET_BATTERY_LEVEL", "GET_DATA_RANGE", "SEND_HISTORICAL_DATA"])
    #expect(!h.writes.contains("SET_CLOCK") && !h.writes.contains("REPORT_VERSION_INFO"))
    #expect(h.saved.map(\.timestamp) == (0..<210).map { start + UInt32($0) })
    #expect(h.session.phase == .finished)

    // Nothing new: a pull is three commands and ends straight away.
    h.finishedRecords = nil
    let empty = h.session.pullAgain()
    h.run(effects: empty)
    #expect(h.finishedRecords == 0)
    #expect(h.saved.count == 210)
}

@Test func pullAgainWaitsUntilTheLastDownloadIsDone() {
    var session = BandSession()
    #expect(session.pullAgain().isEmpty)        // idle: nothing to repeat
    _ = session.start()
    #expect(session.pullAgain().isEmpty)        // still saying hello
}

@Test func sessionFixesAWrongClockBeforeDownloading() {
    // A band whose clock was never set reports a tiny number. History timestamps would be garbage.
    var h = SessionHarness(band: SimulatedBand(samples: samples(50), clock: 12_345), now: 1_750_000_100)
    h.run()
    #expect(h.lastInfo?.clockWasSet == true)
    #expect(h.band.clock == 1_750_000_100)
    let setClock = h.writes.firstIndex(of: "SET_CLOCK") ?? Int.max
    let download = h.writes.firstIndex(of: "SEND_HISTORICAL_DATA") ?? -1
    #expect(setClock < download)
    #expect(h.finishedRecords == 50)
}

@Test func sessionStillDownloadsIfTheClockIsNeverAnswered() {
    var h = SessionHarness(band: SimulatedBand(samples: samples(120), batchSize: 100), now: 1_750_000_200)
    h.run(answerClock: false)
    #expect(h.finishedRecords == 120)
    #expect(h.writes.contains("SET_CLOCK"))                     // set anyway: the phone's time is the truth
    #expect(h.lastInfo?.bandClockSource == "HISTORY_END")       // the batches still tell us the band's time
    #expect(h.writes.filter { $0 == "SEND_HISTORICAL_DATA" }.count == 1)   // and it starts exactly once
}

@Test func sessionCountsCorruptedFramesInsteadOfUsingThem() {
    var session = BandSession()
    _ = session.start()
    var frame = Whoop.buildFrame(inner: [Whoop.PacketType.event.rawValue, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0])
    frame[frame.count - 1] ^= 0xFF                              // break the checksum
    let effects = session.receive(characteristic: Whoop.eventsUUID.uppercased(), bytes: frame, now: 0)
    #expect(session.badFrames == 1)
    let logs = effects.filter { if case .log = $0 { true } else { false } }
    #expect(logs.count == 1)
    // The sync log says exactly which check failed.
    let traces = effects.compactMap { if case .trace(let line) = $0 { line } else { nil } }
    #expect(traces.contains { $0.contains("crc8=ok crc32=FAIL") })
    if case .log(let entry) = logs[0] {
        #expect(!entry.crcOK && entry.channel == "EVENT")
    } else {
        Issue.record("expected a log line")
    }
}

@Test func simulatedBandReplaysMinutesExactly() {
    // minutes -> per-second samples -> history records -> minutes must be a round trip.
    let window = Array(dataset.minutes.prefix(90))
    let band = SimulatedBand.samples(from: window)
    #expect(band.count == 90 * 60)
    let records = band.map { s in
        Whoop.HistoryRecord(version: 24, counter: 0, timestamp: s.timestamp, subsec: 0, heartRate: Int(s.heartRate),
                            accelG: s.accel.map { Double($0) }, rrMsUnverified: [], length: 88)
    }
    let rebuilt = MinuteBuilder.minutes(from: records)
    #expect(rebuilt.map(\.heartRate) == window.map(\.heartRate))
    #expect(rebuilt.map(\.activity) == window.map(\.activity))
}

// MARK: - Workout detection

@Test func detectorFindsTheHardWorkoutsInTheDemoMonth() {
    let rest: (Date) -> Double? = { date in
        computed.days.first { utcCalendar.isDate($0.date, inSameDayAs: date) }?.restingHeartRate
    }
    let detected = WorkoutDetector.detect(minutes: dataset.minutes, restingHeartRate: rest)
    // Every clearly hard session the generator planned (average HR 125+ for 20+ minutes) must be found.
    let hard = dataset.workouts.filter { $0.averageHeartRate >= 125 && $0.durationMinutes >= 20 }
    #expect(hard.count >= 5)
    for workout in hard {
        let hit = detected.contains { $0.start < workout.end && $0.end > workout.start }
        #expect(hit, "missed \(workout.kind) at \(workout.start)")
    }
    // And it must not invent a crowd of workouts out of normal daily life.
    let counted = detected.filter { $0.isSuggestion != true }
    #expect(counted.count <= dataset.workouts.count + 6, "\(counted.count) detected vs \(dataset.workouts.count) planned")
    // Found in simulated minutes = still simulated, so it can never be exported as real.
    #expect(detected.allSatisfy { $0.source == .simulated })
    for workout in detected {
        #expect(workout.durationMinutes >= WorkoutDetector.minimumMinutes)
        #expect(workout.strain > 0 && workout.strain <= 21)
        #expect(workout.zoneSeconds.count == 5)
    }
}

@Test func detectorIgnoresShortBurstsAndKeepsShortPauses() {
    func minute(_ index: Int, hr: UInt8) -> MinuteSample {
        MinuteSample(start: Date(timeIntervalSince1970: 1_750_000_020 + Double(index) * 60),
                     heartRate: [UInt8](repeating: hr, count: 60), rrIntervalsMs: [],
                     activity: [UInt8](repeating: 40, count: 60), source: .history)
    }
    // 6 hard minutes (too short), a long rest, then 8 hard + 1 easy + 8 hard (one workout with a pause).
    var minutes: [MinuteSample] = []
    for i in 0..<6 { minutes.append(minute(i, hr: 150)) }
    for i in 6..<30 { minutes.append(minute(i, hr: 70)) }
    for i in 30..<38 { minutes.append(minute(i, hr: 150)) }
    for i in 38..<39 { minutes.append(minute(i, hr: 80)) }
    for i in 39..<47 { minutes.append(minute(i, hr: 150)) }
    for i in 47..<60 { minutes.append(minute(i, hr: 70)) }

    let detected = WorkoutDetector.detect(minutes: minutes) { _ in 60 }
    #expect(detected.count == 1)
    #expect(detected.first?.start == minutes[30].start)
    #expect(detected.first?.durationMinutes == 17)              // the trailing easy minutes are not counted
    #expect(detected.first?.source == .history)
}

@Test func workoutIDsAreStableAcrossRuns() {
    let start = Date(timeIntervalSince1970: 1_750_000_020)
    #expect(WorkoutDetector.stableID(start: start) == WorkoutDetector.stableID(start: start))
    #expect(WorkoutDetector.stableID(start: start) != WorkoutDetector.stableID(start: start.addingTimeInterval(60)))
}

@Test func manualWorkoutsGetTheirNumbersFromTheBandData() {
    let start = Date(timeIntervalSince1970: 1_750_000_020)
    let minutes = (0..<40).map { i in
        MinuteSample(start: start.addingTimeInterval(Double(i) * 60), heartRate: [UInt8](repeating: i < 30 ? 120 : 70, count: 60),
                     rrIntervalsMs: [], activity: [UInt8](repeating: 20, count: 60), source: .history)
    }
    let workout = WorkoutDetector.manual(kind: .strength, start: start, end: start.addingTimeInterval(30 * 60),
                                         minutes: minutes, restingHeartRate: 60)
    #expect(workout.kind == .strength && workout.source == .manual)
    #expect(workout.averageHeartRate == 120 && workout.maxHeartRate == 120)     // the 70 bpm minutes are outside
    #expect(workout.durationMinutes == 30)
    #expect(workout.strain > 0)

    // No band data in that window: still a workout, with honest zeros.
    let empty = WorkoutDetector.manual(kind: .other, start: start.addingTimeInterval(-7200),
                                       end: start.addingTimeInterval(-3600), minutes: minutes, restingHeartRate: nil)
    #expect(empty.averageHeartRate == 0 && empty.strain == 0 && empty.source == .manual)

    // On top of simulated data it stays simulated, so it can never be exported as real.
    let demo = WorkoutDetector.manual(kind: .run, start: dataset.minutes[0].start,
                                      end: dataset.minutes[0].start.addingTimeInterval(1800),
                                      minutes: dataset.minutes, restingHeartRate: 55)
    #expect(demo.source == .simulated)
}

@Test func syncLogShowsEveryNotificationAndSplitFrames() {
    var session = BandSession()
    _ = session.start()
    let frame = Whoop.buildFrame(inner: [Whoop.PacketType.event.rawValue, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0])
    // One frame split across two notifications, like a small MTU does.
    let first = session.receive(characteristic: Whoop.eventsUUID, bytes: Array(frame[0..<6]), now: 0)
    let second = session.receive(characteristic: Whoop.eventsUUID, bytes: Array(frame[6...]), now: 0)
    let a = first.compactMap { if case .trace(let line) = $0 { line } else { nil } }
    let b = second.compactMap { if case .trace(let line) = $0 { line } else { nil } }
    #expect(a.first?.hasPrefix("RX EVENT") == true && a.first?.contains("len=6") == true)
    #expect(a.contains { $0.contains("WAITING 6 bytes") })
    #expect(b.contains { $0.contains("FRAME") && $0.contains("crc8=ok crc32=ok") })
}

@Test func getClockMatchesTheReferenceOnTheWire() {
    // [OS] builds GET_CLOCK with an empty body; both pad the frame to 4 bytes, so ours is identical.
    // (So the band's silence on GET_CLOCK is not a format problem.)
    #expect(Whoop.Command.getClock(seq: 7) == Whoop.buildFrame(inner: [0x23, 7, Whoop.Cmd.getClock.rawValue]))
}

@Test func bandTimeVersusPhoneTimeIsReported() {
    // The band runs 90 s fast: the first reading shows it, the read-back after SET_CLOCK shows ~0.
    let now: Double = 1_750_000_100
    var h = SessionHarness(band: SimulatedBand(samples: samples(10, start: 1_750_000_000), clock: 1_750_000_190), now: now)
    h.run()
    #expect(h.trace.contains { $0.contains("band - phone = +90.0 s") })
    #expect(h.lastInfo?.clockOffsetSeconds == 0)
    #expect(h.band.clock == 1_750_000_100)
}

@Test func progressComesFromTheBandsPageCounters() {
    // 4 batches; GET_DATA_RANGE says trim 5000, write 5004; each ack token carries the trim page.
    var h = SessionHarness(band: SimulatedBand(samples: samples(400), batchSize: 100), now: 1_750_000_500)
    h.run()
    let known = h.fractions.compactMap { $0 }
    #expect(known.count == 4)
    #expect(known == known.sorted())                                 // only goes up
    #expect(known.allSatisfy { $0 < 1 })                             // 100% only when the band says it's done
    #expect(h.trace.contains { $0.hasPrefix("DATA_RANGE 4 pages to sync") })
}

@Test func historyPacketsAreSummarizedUnlessVerbose() {
    var quietRun = SessionHarness(band: SimulatedBand(samples: samples(300), batchSize: 100, mtuPayload: 20), now: 1_750_000_400)
    quietRun.run()
    var loud = SessionHarness(band: SimulatedBand(samples: samples(300), batchSize: 100, mtuPayload: 20), now: 1_750_000_400)
    loud.session.verboseTrace = true
    loud.run()
    #expect(quietRun.finishedRecords == 300 && loud.finishedRecords == 300)
    #expect(quietRun.trace.filter { $0.contains("… HISTORICAL_DATA: 100 frames") }.count == 3)
    #expect(!quietRun.trace.contains { $0.contains("FRAME HISTORICAL_DATA") })
    #expect(loud.trace.contains { $0.contains("FRAME HISTORICAL_DATA") })
    #expect(quietRun.trace.count * 10 < loud.trace.count)             // the log is >10x smaller
    #expect(quietRun.trace.contains { $0.contains("HISTORY_END") && $0.contains("dated ") })
}
