import Foundation
import Testing
@testable import PulseCore

// Keeping Pulse awake in the background while the 100 Hz stream is off (docs/METRICS.md §15), and Today's "Last synced" line.

@Test func theHeartbeatRunsWheneverTheStreamIsOff() {
    #expect(!MotionStreamPolicy.heartbeat(for: .stream))
    for decision: MotionStreamPolicy.Decision in [.asleep, .notWorn, .lowBattery] {
        #expect(MotionStreamPolicy.heartbeat(for: decision), "\(decision)")
    }
}

@Test func heartbeatPacketsAreQuietAndNeverCountAsDownloadProgress() {
    var session = BandSession()
    _ = session.start()
    let before = session.downloadActivity
    var readings: [Int] = []
    var lines: [String] = []
    for second in 0..<300 {
        let frame = SimulatedBand.realtimeFrame(timestamp: 1_795_000_000 + UInt32(second), heartRate: 52)
        for effect in session.receive(characteristic: Whoop.dataUUID, bytes: frame, now: 1_795_000_000 + Double(second)) {
            switch effect {
            case .liveHeartRate(let bpm): readings.append(bpm)
            case .trace(let line): lines.append(line)
            case .log: lines.append("log")
            default: break
            }
        }
    }
    // Every packet still reaches the app (it is what wakes Pulse) ...
    #expect(readings.count == 300 && readings.allSatisfy { $0 == 52 })
    // ... but writes nothing to the sync log one by one, and the stall watchdog never mistakes it for a download.
    #expect(lines.isEmpty)
    #expect(session.downloadActivity == before)
    // The next command writes one summary line first.
    let off = session.setLive(false)
    let summary = off.compactMap { if case .trace(let line) = $0 { line } else { nil } }
    #expect(summary.first?.contains("REALTIME_HR: 300 heart-rate packets") == true)
    #expect(off.contains { if case .write(_, let d) = $0 { d == "TOGGLE_REALTIME_HR" } else { false } })
}

@Test func heartbeatPacketsDuringTheStreamAreCountedWithIt() {
    var session = BandSession()
    _ = session.start()
    let still = (0..<100).map { _ in Int16(0) }, gravity = (0..<100).map { _ in Int16(4096) }
    for second in 0..<3 {
        let at = 1_795_000_000 + UInt32(second)
        _ = session.receive(characteristic: Whoop.dataUUID, bytes: SimulatedBand.rawMotionFrame(timestamp: at, accel: [still, still, gravity]),
                            now: Double(at))
        _ = session.receive(characteristic: Whoop.dataUUID, bytes: SimulatedBand.realtimeFrame(timestamp: at, heartRate: 70), now: Double(at))
    }
    let summary = session.setRawStream(false).compactMap { if case .trace(let line) = $0 { line } else { nil } }
    #expect(summary.contains { $0.contains("REALTIME_RAW: 3 motion and 0 other packets, 3 heart-rate packets") })
}

// MARK: - "Last synced"

private let now = Date(timeIntervalSince1970: 1_795_820_000)

@Test func theLastSyncedLineSaysHowLongAgo() {
    func text(_ secondsAgo: TimeInterval, syncing: Bool = false) -> String? {
        SyncFreshness.line(lastSync: now.addingTimeInterval(-secondsAgo), now: now, syncing: syncing)?.text
    }
    #expect(text(20) == "Synced just now")
    #expect(text(4 * 60 + 30) == "Synced 4 min ago")
    #expect(text(59 * 60) == "Synced 59 min ago")
    #expect(text(3600) == "Last synced 1h ago")
    #expect(text(2 * 3600 + 14 * 60) == "Last synced 2h 14m ago")
    #expect(text(26 * 3600) == "Last synced 1 day ago")
    #expect(text(3 * 86_400 + 60) == "Last synced 3 days ago")
    #expect(text(60, syncing: true) == "Syncing…")
    #expect(text(11 * 3600 + 20 * 60, syncing: true) == "Syncing… last synced 11h 20m ago")
    #expect(SyncFreshness.line(lastSync: nil, now: now, syncing: false) == nil)
}

@Test func theLineWarnsAfterTwoHours() {
    func stale(_ secondsAgo: TimeInterval, syncing: Bool = false) -> Bool? {
        SyncFreshness.line(lastSync: now.addingTimeInterval(-secondsAgo), now: now, syncing: syncing)?.isStale
    }
    #expect(stale(30 * 60) == false)
    #expect(stale(2 * 3600 - 60) == false)
    #expect(stale(2 * 3600) == true)
    // 2026-11-27: at 13:33 the newest pull had finished around 2:13, over 11 hours earlier.
    #expect(stale(11 * 3600 + 20 * 60) == true)
    // A pull catching up is not a warning: it is fixing it.
    #expect(stale(11 * 3600, syncing: true) == false)
    // A phone clock set back never shows a negative age.
    #expect(SyncFreshness.line(lastSync: now.addingTimeInterval(120), now: now, syncing: false)?.text == "Synced just now")
}
