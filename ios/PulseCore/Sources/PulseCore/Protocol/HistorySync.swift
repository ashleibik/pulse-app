import Foundation

/// The history download as a pure state machine: no Bluetooth, no database, no clocks.
/// The BLE layer feeds it decoded packets and carries out the actions it returns.
///
///   start() ──► send SEND_HISTORICAL_DATA
///   records ─► collected into the current batch
///   HISTORY_END(token) ─► .persist(batch, token)   ── app saves to disk ──► didPersist(token) ─► send ack
///   HISTORY_COMPLETE ──► .finished
///
/// Safety rules (each one is a test in HistorySyncTests):
///   1. An ack for a batch with records to keep is only ever produced by didPersist(token:), so nothing
///      is acknowledged before it's saved. (After an ack the band may free that storage. Acking first
///      and crashing = lost data.)
///      Exception, on purpose: records older than `discardBefore` (a used band's previous owner) are
///      dropped as they arrive. A batch left with nothing to keep is acked at once: there is nothing
///      to save, and the ack is what lets the band free that memory.
///   2. didPersist with the wrong token produces nothing.
///   3. The record count the band announces in HISTORY_END is ADVISORY, never a reason to reject a
///      batch. On the WHOOP 4.0 it does not match the number of records actually sent, and the gap
///      changes from run to run. Rejecting on it re-requests the same batch forever (our first real
///      band sync failed exactly like this: "Batch kept arriving incomplete (4 tries)").
///      Source: OpenStrap/edge lib/ble/adapters/_registry.dart, `burstCountGateEnforced` is false
///      for WHOOP 4 on purpose, and its test "a short gen4 burst is still ACKed with the verbatim
///      token". The mismatch is written to the sync log so real captures can pin down its meaning.
///   4. If the band goes quiet mid-download, `stalled()` asks again. Nothing was acked for the open
///      batch, so the band sends it again. After `maxRetries` quiet periods in a row it gives up;
///      every batch saved before that stays saved.
public struct HistorySync: Sendable {

    public enum State: Sendable, Equatable {
        case idle
        case receiving
        case waitingForSave(token: [UInt8])
        case complete
        case failed(String)
    }

    public enum Action: Sendable, Equatable {
        /// Write these bytes to CMD_TO_STRAP (with response).
        case send([UInt8], description: String)
        /// Save these records durably, then call didPersist(token:).
        case persist([Whoop.HistoryRecord], token: [UInt8])
        case finished(batches: Int, records: Int)
        /// A batch made only of records older than `discardBefore` was acked without saving.
        case cleared(records: Int)
        case failed(String)
        /// Something worth a line in the sync log (no effect on the download).
        case note(String)
    }

    public private(set) var state: State = .idle
    public private(set) var batchesSaved = 0
    public private(set) var recordsSaved = 0
    public private(set) var retries = 0
    public let maxRetries: Int
    /// Records older than this (unix seconds) are thrown away unread: on a used band they are the
    /// previous owner's. Records with an impossible date are thrown away too. `nil` = keep everything.
    public let discardBefore: UInt32?
    /// Old records dropped so far (never saved, but acked so the band frees its memory).
    public private(set) var recordsCleared = 0
    /// Date of the newest record received (kept or not), and the newest batch token: for progress.
    public private(set) var lastRecordTime: UInt32?
    public private(set) var lastToken: [UInt8]?

    private var batch: [Whoop.HistoryRecord] = []
    private var batchDropped = 0
    /// Oldest and newest record date of the open batch (kept or dropped), for the sync log.
    private var batchSpan: (first: UInt32, last: UInt32)?
    private var seq: Whoop.SeqCounter

    public init(maxRetries: Int = 5, startSeq: UInt8 = 0, discardBefore: UInt32? = nil) {
        self.maxRetries = maxRetries
        self.seq = Whoop.SeqCounter(start: startSeq)
        self.discardBefore = discardBefore
    }

    /// True while the records arriving are older than `discardBefore` (a backlog being cleared).
    public var isClearingOldData: Bool {
        guard let discardBefore, let lastRecordTime else { return false }
        return lastRecordTime < discardBefore
    }

    private func keeps(_ record: Whoop.HistoryRecord) -> Bool {
        guard let discardBefore else { return true }
        return Whoop.plausibleUnix(record.timestamp) && record.timestamp >= discardBefore
    }

    /// Begin the download. Optionally set the band's clock first (fixes garbage timestamps).
    public mutating func start(setClockTo unixTime: Double? = nil) -> [Action] {
        state = .receiving
        batch = []
        batchDropped = 0
        var actions: [Action] = []
        if let unixTime {
            actions.append(.send(Whoop.Command.setClock(seq: seq.next(), unixTime: unixTime), description: "SET_CLOCK"))
        }
        actions.append(.send(Whoop.Command.sendHistoricalData(seq: seq.next()), description: "SEND_HISTORICAL_DATA"))
        return actions
    }

    /// Feed every decoded packet from the DATA characteristic.
    public mutating func handle(_ packet: Whoop.Packet) -> [Action] {
        switch packet {
        case .history(let record):
            guard state == .receiving else { return [] }
            if Whoop.plausibleUnix(record.timestamp) {
                lastRecordTime = record.timestamp
                batchSpan = (batchSpan?.first ?? record.timestamp, record.timestamp)
            }
            if keeps(record) { batch.append(record) } else { batchDropped += 1 }
            return []

        case .metadata(let meta):
            switch Whoop.MetaType(rawValue: UInt8(truncatingIfNeeded: meta.metaType)) {
            case .historyStart:
                state = .receiving
                batch = []
                batchDropped = 0
                batchSpan = nil
                return []
            case .historyEnd:
                return batchEnded(meta)
            case .historyComplete:
                state = .complete
                return [.finished(batches: batchesSaved, records: recordsSaved)]
            case nil:
                return []
            }

        default:
            return []
        }
    }

    private mutating func batchEnded(_ meta: Whoop.Metadata) -> [Action] {
        guard state == .receiving else { return [] }
        guard let token = meta.token, token.count == 8 else {
            return fail("History batch ended without a valid token.")
        }
        var actions: [Action] = []
        let received = batch.count + batchDropped
        let expected = meta.expectedPackets.map { Int($0) }
        let tokenHex = Whoop.hex(token)
        let clock = meta.timestamp.map { " band clock \(Self.utc($0))" } ?? " band clock not set"
        let dropped = (batchDropped > 0 ? ", \(batchDropped) old dropped" : "")
            + (batchSpan.map { ", dated \(Self.utc($0.first)) → \(Self.utc($0.last))" } ?? "")
        batchSpan = nil
        if let expected, expected != received {
            actions.append(.note("HISTORY_END announced \(expected), received \(received) records\(dropped), token \(tokenHex),\(clock) (count is advisory on WHOOP 4.0: saving anyway)"))
        } else {
            actions.append(.note("HISTORY_END \(received) records\(dropped), token \(tokenHex),\(clock)"))
        }
        lastToken = token
        recordsCleared += batchDropped
        let droppedNow = batchDropped
        batchDropped = 0
        let records = batch
        batch = []
        if records.isEmpty && droppedNow > 0 {
            // Only the previous owner's records: nothing to keep, so ack right away (no database trip).
            guard let ack = Whoop.Command.historyAck(token: token, seq: seq.next()) else { return actions }
            retries = 0
            return actions + [.cleared(records: droppedNow), .send(ack, description: "HISTORY_ACK")]
        }
        state = .waitingForSave(token: token)
        return actions + [.persist(records, token: token)]
    }

    /// "2023-02-22 05:36:03Z": record dates in the sync log, independent of the phone's time zone.
    static func utc(_ unix: UInt32) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss'Z'"
        return f.string(from: Date(timeIntervalSince1970: Double(unix)))
    }

    /// Call after the batch from `.persist` is durably saved. Returns the ack to send.
    public mutating func didPersist(token: [UInt8], recordCount: Int) -> [Action] {
        guard case .waitingForSave(let expected) = state, expected == token,
              let ack = Whoop.Command.historyAck(token: token, seq: seq.next())
        else { return [] }
        state = .receiving
        batchesSaved += 1
        recordsSaved += recordCount
        retries = 0
        return [.send(ack, description: "HISTORY_ACK")]
    }

    /// The band sent nothing for a while (the app's watchdog decides how long). While a batch is
    /// being saved this does nothing: the band is waiting for our ack, not stuck.
    public mutating func stalled() -> [Action] {
        guard state == .receiving else { return [] }
        retries += 1
        let lost = batch.count
        batch = []
        batchDropped = 0
        if retries > maxRetries {
            return fail("The band stopped sending data (\(retries - 1) retries). Everything downloaded so far is saved; sync again to continue.")
        }
        return [.note("No data for a while: asking again (retry \(retries) of \(maxRetries), \(lost) unsaved records of the open batch will be resent)"),
                .send(Whoop.Command.sendHistoricalData(seq: seq.next()), description: "SEND_HISTORICAL_DATA (retry \(retries))")]
    }

    private mutating func fail(_ message: String) -> [Action] {
        state = .failed(message)
        return [.failed(message)]
    }
}
