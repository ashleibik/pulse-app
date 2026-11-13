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
///   1. An ack is only ever produced by didPersist(token:), so nothing is acknowledged before it's saved.
///      (After an ack the band may free that storage. Acking first and crashing = lost data.)
///   2. didPersist with the wrong token produces nothing.
///   3. If a batch arrives with fewer records than the band announced (a lost notification), it is
///      discarded and requested again, never half-saved and acked. After `maxRetries` it gives up.
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
        case failed(String)
    }

    public private(set) var state: State = .idle
    public private(set) var batchesSaved = 0
    public private(set) var recordsSaved = 0
    public private(set) var retries = 0
    public let maxRetries: Int

    private var batch: [Whoop.HistoryRecord] = []
    private var seq: Whoop.SeqCounter

    public init(maxRetries: Int = 3, startSeq: UInt8 = 0) {
        self.maxRetries = maxRetries
        self.seq = Whoop.SeqCounter(start: startSeq)
    }

    /// Begin the download. Optionally set the band's clock first (fixes garbage timestamps).
    public mutating func start(setClockTo unixTime: Double? = nil) -> [Action] {
        state = .receiving
        batch = []
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
            if state == .receiving { batch.append(record) }
            return []

        case .metadata(let meta):
            switch Whoop.MetaType(rawValue: UInt8(truncatingIfNeeded: meta.metaType)) {
            case .historyStart:
                state = .receiving
                batch = []
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
        if let expected = meta.expectedPackets, batch.count < Int(expected) {
            // Lost notifications: don't save half a batch. Ask again; without an ack the band resends it.
            retries += 1
            batch = []
            if retries > maxRetries {
                return fail("Batch kept arriving incomplete (\(retries) tries). Move closer and sync again.")
            }
            return [.send(Whoop.Command.sendHistoricalData(seq: seq.next()), description: "SEND_HISTORICAL_DATA (retry \(retries))")]
        }
        state = .waitingForSave(token: token)
        let records = batch
        batch = []
        return [.persist(records, token: token)]
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

    private mutating func fail(_ message: String) -> [Action] {
        state = .failed(message)
        return [.failed(message)]
    }
}
