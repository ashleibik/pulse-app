import Foundation

/// Everything that happens between "Bluetooth is connected" and "the band's history is saved",
/// as a pure state machine: no Bluetooth, no database, no timers.
///
/// The app's Bluetooth layer feeds it the raw bytes of every notification and carries out the
/// effects it returns. Because it is pure, the exact code that will talk to the real band is
/// tested on Windows against `SimulatedBand` (BandSessionTests).
///
///   start()            -> ask battery, firmware text and the band's clock
///   clock answer       -> set the clock if it is wrong, then start the history download
///   history batches    -> .persist(records, token)  -- app saves --> didPersist(token) -> ack
///   HISTORY_COMPLETE   -> .finished
///
/// ⚠ UNVERIFIED on a real band (no hardware yet): the order of the hello commands, whether the
/// band answers GET_CLOCK before history starts, and the ack token (re-toolkit/docs/PROTOCOL.md).
/// If the clock answer never comes, the app calls `clockTimedOut()` and the download starts anyway.
public struct BandSession: Sendable {

    /// What we learned about the band so far. `nil` = not reported yet.
    public struct Info: Sendable, Equatable {
        public var batteryPercent: Double?
        public var isCharging: Bool?
        public var isWorn: Bool?
        /// Readable text from REPORT_VERSION_INFO (its exact layout is unknown).
        public var firmware: String?
        /// True if we had to set the band's clock in this session.
        public var clockWasSet = false

        public init() {}
    }

    /// One line for the debug screen.
    public struct LogEntry: Sendable, Equatable, Identifiable {
        public enum Direction: String, Sendable { case toBand, fromBand }
        public let id: Int
        public let direction: Direction
        /// "CMD", "RESP", "EVENT", "DATA" or the raw characteristic UUID.
        public let channel: String
        public let summary: String
        public let hex: String
        public let crcOK: Bool
    }

    public enum Effect: Sendable, Equatable {
        /// Write these bytes to CMD_TO_STRAP (with response).
        case write([UInt8], description: String)
        /// Save these records durably, then call `didPersist(token:recordCount:)`.
        case persist([Whoop.HistoryRecord], token: [UInt8])
        case info(Info)
        case progress(recordsSaved: Int, batchesSaved: Int)
        /// A live heart-rate reading (only while realtime streaming is on).
        case liveHeartRate(Int)
        case finished(records: Int)
        case failed(String)
        case log(LogEntry)
    }

    public enum Phase: Sendable, Equatable { case idle, hello, syncing, finished, failed }

    public private(set) var phase: Phase = .idle
    public private(set) var info = Info()
    /// Frames whose checksum did not match (a sign of a bad connection).
    public private(set) var badFrames = 0

    private var sync: HistorySync
    private var seq = Whoop.SeqCounter()
    private var reassemblers: [String: Whoop.FrameReassembler] = [:]
    private var nextLogID = 0
    /// The band's clock may differ from the phone's by this much before we correct it.
    public static let clockToleranceSeconds = 5.0

    public init(maxRetries: Int = 3) {
        // The hello commands use sequence numbers 0-2; history continues after them.
        sync = HistorySync(maxRetries: maxRetries, startSeq: 3)
    }

    // MARK: - Driving the session

    /// Call once the characteristics are ready.
    public mutating func start() -> [Effect] {
        guard phase == .idle else { return [] }
        phase = .hello
        var effects: [Effect] = []
        let battery = Whoop.Command.getBattery(seq: seq.next())
        effects += write(battery, "GET_BATTERY_LEVEL")
        let version = Whoop.Command.reportVersion(seq: seq.next())
        effects += write(version, "REPORT_VERSION_INFO")
        let clock = Whoop.Command.getClock(seq: seq.next())
        effects += write(clock, "GET_CLOCK")
        return effects
    }

    /// The band did not answer GET_CLOCK in time: download anyway, without touching its clock.
    public mutating func clockTimedOut() -> [Effect] {
        beginHistory(setClockTo: nil)
    }

    /// Feed the bytes of every notification, from any characteristic.
    /// - Parameter now: the phone's clock (unix seconds), used to check the band's clock.
    public mutating func receive(characteristic: String, bytes: [UInt8], now: Double) -> [Effect] {
        let key = characteristic.lowercased()
        var reassembler = reassemblers[key] ?? Whoop.FrameReassembler()
        let frames = reassembler.feed(bytes)
        reassemblers[key] = reassembler

        var effects: [Effect] = []
        for frame in frames {
            guard frame.valid else {
                badFrames += 1
                effects.append(log(.fromBand, key, "Bad checksum (\(frame.typeName))", frame.raw, ok: false))
                continue
            }
            effects += handle(Whoop.decode(frame), frame: frame, channel: key, now: now)
        }
        return effects
    }

    /// Turns the band's live heart-rate stream on or off (used by the live workout screen).
    public mutating func setLive(_ on: Bool) -> [Effect] {
        let command = Whoop.Command.realtimeHR(on: on, seq: seq.next())
        return write(command, "TOGGLE_REALTIME_HR")
    }

    /// Call after the batch from `.persist` is safely on disk. Returns the ack for the band.
    public mutating func didPersist(token: [UInt8], recordCount: Int) -> [Effect] {
        var effects = map(sync.didPersist(token: token, recordCount: recordCount))
        if !effects.isEmpty {
            effects.append(.progress(recordsSaved: sync.recordsSaved, batchesSaved: sync.batchesSaved))
        }
        return effects
    }

    // MARK: - Internals

    private mutating func handle(_ packet: Whoop.Packet, frame: Whoop.Frame, channel: String, now: Double) -> [Effect] {
        switch packet {
        case .commandResponse(let response):
            var effects = [log(.fromBand, channel, "\(response.opcodeName) -> \(response.statusName)", frame.raw)]
            var changed = false
            if let battery = response.batteryPercent { info.batteryPercent = battery; changed = true }
            if response.opcode == Int(Whoop.Cmd.reportVersionInfo.rawValue), let text = response.asciiView {
                info.firmware = text
                changed = true
            }
            if changed { effects.append(.info(info)) }
            if response.opcode == Int(Whoop.Cmd.getClock.rawValue), phase == .hello {
                // `bandClock` is nil when the value is not a plausible date (the clock was never set).
                let wrong = response.bandClock.map { abs(Double($0) - now) > Self.clockToleranceSeconds } ?? true
                effects += beginHistory(setClockTo: wrong ? now : nil)
            }
            return effects

        case .event(let event):
            var effects = [log(.fromBand, channel, "Event \(event.eventName)", frame.raw)]
            var changed = false
            if let battery = event.batteryPercent { info.batteryPercent = battery; changed = true }
            if let charging = event.charging { info.isCharging = charging; changed = true }
            switch Whoop.EventID(rawValue: UInt16(truncatingIfNeeded: event.eventID)) {
            case .wristOn: info.isWorn = true; changed = true
            case .wristOff: info.isWorn = false; changed = true
            case .chargingOn: info.isCharging = true; changed = true
            case .chargingOff: info.isCharging = false; changed = true
            default: break
            }
            if changed { effects.append(.info(info)) }
            return effects

        case .realtime(let reading):
            return reading.heartRate > 0 ? [.liveHeartRate(reading.heartRate)] : []

        case .metadata(let meta):
            // One log line per batch boundary (not per record: a night is ~30,000 records).
            return [log(.fromBand, channel, "\(meta.metaName)", frame.raw)] + map(sync.handle(packet))

        case .history:
            return map(sync.handle(packet))

        case .unknown(_, let typeName, _):
            return [log(.fromBand, channel, "Unknown packet \(typeName)", frame.raw)]
        }
    }

    private mutating func beginHistory(setClockTo unixTime: Double?) -> [Effect] {
        guard phase == .hello else { return [] }       // only once
        phase = .syncing
        var effects: [Effect] = []
        if unixTime != nil {
            info.clockWasSet = true
            effects.append(.info(info))
        }
        return effects + map(sync.start(setClockTo: unixTime))
    }

    /// Translates the history state machine's actions into session effects.
    private mutating func map(_ actions: [HistorySync.Action]) -> [Effect] {
        var effects: [Effect] = []
        for action in actions {
            switch action {
            case .send(let bytes, let description):
                effects += write(bytes, description)
            case .persist(let records, let token):
                effects.append(.persist(records, token: token))
            case .finished(_, let records):
                phase = .finished
                effects.append(.finished(records: records))
            case .failed(let message):
                phase = .failed
                effects.append(.failed(message))
            }
        }
        return effects
    }

    private mutating func write(_ bytes: [UInt8], _ description: String) -> [Effect] {
        [log(.toBand, Whoop.cmdToStrapUUID, description, bytes), .write(bytes, description: description)]
    }

    private mutating func log(_ direction: LogEntry.Direction, _ characteristic: String, _ summary: String,
                              _ bytes: [UInt8], ok: Bool = true) -> Effect {
        nextLogID += 1
        // Long frames (history) are cut: the debug screen only needs the start.
        let shown = bytes.prefix(48).map { String(format: "%02x", $0) }.joined(separator: " ")
        return .log(LogEntry(id: nextLogID, direction: direction, channel: Self.channelName(characteristic),
                             summary: summary, hex: bytes.count > 48 ? shown + " …" : shown, crcOK: ok))
    }

    static func channelName(_ characteristic: String) -> String {
        switch characteristic.lowercased() {
        case Whoop.cmdToStrapUUID: "CMD"
        case Whoop.cmdFromStrapUUID: "RESP"
        case Whoop.eventsUUID: "EVENT"
        case Whoop.dataUUID: "DATA"
        default: characteristic
        }
    }
}

extension SimulatedBand {
    /// Turns stored minutes into the per-second samples a band would have recorded, so the
    /// simulated band can "replay" them. The accel vector's length encodes the activity value
    /// (the inverse of `MinuteBuilder.activity`). Seconds without a reading (HR 0) are kept: the
    /// real band also records while it is off the wrist.
    public static func samples(from minutes: [MinuteSample]) -> [Sample] {
        var out: [Sample] = []
        out.reserveCapacity(minutes.count * 60)
        for minute in minutes {
            let base = UInt32(max(0, minute.start.timeIntervalSince1970))
            for second in 0..<60 {
                let hr = second < minute.heartRate.count ? minute.heartRate[second] : 0
                let activity = second < minute.activity.count ? minute.activity[second] : 0
                out.append(Sample(timestamp: base + UInt32(second), heartRate: hr,
                                  accel: [0, 0, 1 + Float(activity) / Float(MinuteBuilder.activityScale)]))
            }
        }
        return out
    }
}
