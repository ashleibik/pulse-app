import Foundation

/// Everything that happens between "Bluetooth is connected" and "the band's history is saved",
/// as a pure state machine: no Bluetooth, no database, no timers.
///
/// The app's Bluetooth layer feeds it the raw bytes of every notification and carries out the
/// effects it returns. Because it is pure, the exact code that will talk to the real band is
/// tested on Windows against a simulated band that lives in the test target (BandSessionTests).
///
///   start()            -> live heart rate off, ask battery, firmware text and the band's clock
///   clock answer       -> set the clock to the phone's time (every connect), read it back to
///                         confirm it latched, then start the history download
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
        /// Readable text from REPORT_VERSION_INFO (its exact layout is unknown), e.g. "41.17.4".
        public var firmware: String?
        /// The full REPORT_VERSION_INFO body as hex, for the sync log (to decode the layout later).
        public var firmwareRawHex: String?
        /// True once SET_CLOCK was sent in this session (it is sent on every connect).
        public var clockWasSet = false
        /// The band's clock as last read (unix seconds, raw: may be an unset clock like 4242).
        public var bandClock: UInt32?
        /// The phone's time (unix seconds) when `bandClock` was read.
        public var bandClockReadAt: Double?
        /// Where the reading came from: "GET_CLOCK", or "HISTORY_END" (the band stamps each batch).
        public var bandClockSource: String?
        /// Band minus phone, in seconds. nil while unknown or when the band's clock is not set at all.
        public var clockOffsetSeconds: Double? {
            guard let bandClock, let bandClockReadAt, Whoop.plausibleUnix(bandClock) else { return nil }
            return Double(bandClock) - bandClockReadAt
        }

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

    /// How far the download is.
    public struct Progress: Sendable, Equatable {
        public var recordsSaved = 0
        public var batchesSaved = 0
        /// The previous owner's records thrown away (acked, never saved).
        public var recordsCleared = 0
        /// 0...1 once the band said how much it holds; nil until then.
        public var fraction: Double?
        /// True while the records arriving are older than the cutoff.
        public var clearingOldData = false

        public init() {}
    }

    public enum Effect: Sendable, Equatable {
        /// Write these bytes to CMD_TO_STRAP (with response).
        case write([UInt8], description: String)
        /// Save these records durably, then call `didPersist(token:recordCount:)`.
        case persist([Whoop.HistoryRecord], token: [UInt8])
        case info(Info)
        case progress(Progress)
        /// A live heart-rate reading (only while realtime streaming is on).
        case liveHeartRate(Int)
        /// One second of 100 Hz motion (only while the raw stream is on, during a step test).
        case rawMotion(Whoop.RawMotion)
        case finished(records: Int)
        case failed(String)
        case log(LogEntry)
        /// One line for the sync log (every notification, frame and batch). Debug only.
        case trace(String)
    }

    public enum Phase: Sendable, Equatable { case idle, hello, syncing, finished, failed }

    public private(set) var phase: Phase = .idle
    public private(set) var info = Info()
    /// Frames whose checksum did not match (a sign of a bad connection).
    public private(set) var badFrames = 0
    /// Goes up with every packet of the download's conversation (command answers, history records, batch markers), and
    /// never with the 100 Hz motion stream or live heart rate. The app's stall watchdog watches it: the stream sends data
    /// every second, so "anything arrived" would hide a download that stopped.
    public private(set) var downloadActivity = 0

    private var sync: HistorySync
    private var seq = Whoop.SeqCounter()
    private var reassemblers: [String: Whoop.FrameReassembler] = [:]
    private var nextLogID = 0
    /// Write every notification to the sync log in full (Debug > Sync log > Verbose). Off: history
    /// packets are summarized once per batch.
    public var verboseTrace = false
    private var quiet = (notifications: 0, frames: 0, bytes: 0)
    /// The 100 Hz stream's packets, counted like history: motion and the optical variant. And live heart rate, which runs all
    /// night as Pulse's heartbeat (`MotionStreamPolicy.heartbeat`): one packet a second, never one log line each.
    private var quietRaw = (motion: 0, other: 0, heartRate: 0)
    /// Dates the 100 Hz stream's seconds by the phone's clock.
    private var motionClock = MotionClock()
    /// From GET_DATA_RANGE: where the band's unsynced data starts and ends (flash pages).
    private var range: (trim: UInt32, write: UInt32, capacity: UInt32)?

    /// - Parameter discardBefore: unix seconds; history older than this is the previous owner's and
    ///   is dropped unread (still acked, which frees the band's memory). nil = keep everything.
    public init(maxRetries: Int = 5, discardBefore: UInt32? = nil) {
        // The hello commands use the low sequence numbers; history uses its own range from 32.
        sync = HistorySync(maxRetries: maxRetries, startSeq: 32, discardBefore: discardBefore)
    }

    public var progress: Progress {
        var p = Progress()
        p.recordsSaved = sync.recordsSaved
        p.batchesSaved = sync.batchesSaved
        p.recordsCleared = sync.recordsCleared
        p.clearingOldData = sync.isClearingOldData
        p.fraction = fraction
        return p
    }

    /// Pages acked so far / pages the band held when we asked. The ack token starts with the
    /// band's trim page ([OS]), and GET_DATA_RANGE gives the trim and write pages at the start.
    /// An estimate: the band keeps recording during the download. Capped at 99% until done.
    private var fraction: Double? {
        guard let range, range.capacity > 0, let token = sync.lastToken, token.count == 8 else { return nil }
        let trimNow = LE.u32(token, 0)
        let cap = Int64(range.capacity)
        let total = (Int64(range.write) - Int64(range.trim) + cap) % cap
        guard total > 0, trimNow <= range.capacity else { return nil }
        let done = (Int64(trimNow) - Int64(range.trim) + cap) % cap
        return min(0.99, max(0, Double(done) / Double(total)))
    }

    /// One line for the history packets that were counted instead of logged.
    private mutating func flushQuiet() -> [Effect] {
        guard quiet.notifications > 0 else { return [] }
        defer {
            quiet = (0, 0, 0)
            quietRaw = (0, 0, 0)
        }
        if quietRaw.motion + quietRaw.other > 0 {
            let heartRate = quietRaw.heartRate > 0 ? ", \(quietRaw.heartRate) heart-rate packets" : ""
            return [.trace("  … REALTIME_RAW: \(quietRaw.motion) motion and \(quietRaw.other) other packets\(heartRate), \(quiet.frames) history frames, in \(quiet.notifications) notifications (\(quiet.bytes) bytes), all checksums ok (summarized)")]
        }
        if quietRaw.heartRate > 0 {
            return [.trace("  … REALTIME_HR: \(quietRaw.heartRate) heart-rate packets, \(quiet.frames) history frames, in \(quiet.notifications) notifications (\(quiet.bytes) bytes), all checksums ok (summarized)")]
        }
        return [.trace("  … HISTORICAL_DATA: \(quiet.frames) frames in \(quiet.notifications) notifications (\(quiet.bytes) bytes), all checksums ok (summarized; turn on Verbose for every packet)")]
    }

    // MARK: - Driving the session

    /// Call once the characteristics are ready.
    public mutating func start() -> [Effect] {
        guard phase == .idle else { return [] }
        phase = .hello
        var effects: [Effect] = []
        // Battery: the live heart-rate stream must never be left on by a crash or a killed app.
        // The live workout screen switches it on again when it needs it.
        effects += write(Whoop.Command.realtimeHR(on: false, seq: seq.next()), "TOGGLE_REALTIME_HR off")
        // The same for the 100 Hz stream, which also stays on across reconnects (a step test cut short).
        effects += write(Whoop.Command.rawStream(on: false, seq: seq.next()), "SEND_R10_R11_REALTIME off")
        let battery = Whoop.Command.getBattery(seq: seq.next())
        effects += write(battery, "GET_BATTERY_LEVEL")
        let version = Whoop.Command.reportVersion(seq: seq.next())
        effects += write(version, "REPORT_VERSION_INFO")
        let clock = Whoop.Command.getClock(seq: seq.next())
        effects += write(clock, "GET_CLOCK")
        // Read-only: how much the band holds, for the progress bar.
        effects += write(Whoop.Command.getDataRange(seq: seq.next()), "GET_DATA_RANGE")
        return effects
    }

    /// The band did not answer GET_CLOCK in time: set its clock anyway, then download.
    /// - Parameter now: the phone's clock (unix seconds).
    public mutating func clockTimedOut(now: Double) -> [Effect] {
        beginHistory(setClockTo: now)
    }

    /// Feed the bytes of every notification, from any characteristic.
    /// - Parameter now: the phone's clock (unix seconds), used to check the band's clock.
    public mutating func receive(characteristic: String, bytes: [UInt8], now: Double) -> [Effect] {
        let key = characteristic.lowercased()
        var reassembler = reassemblers[key] ?? Whoop.FrameReassembler()
        let droppedBefore = reassembler.droppedBytes
        let frames = reassembler.feed(bytes)
        reassemblers[key] = reassembler

        let channel = Self.channelName(key)
        let resynced = reassembler.droppedBytes > droppedBefore
        // A big download is thousands of identical-looking history packets. Unless the log is
        // verbose, they are counted (not hex-dumped) and summarized at the end of each batch.
        // That keeps the log small and saves the CPU time of formatting them.
        let quietTypes = [Whoop.PacketType.historicalData, .realtimeRaw, .realtimeData].map { Int($0.rawValue) }
        let onlyHistory = frames.allSatisfy { $0.valid && quietTypes.contains($0.packetType) }
        if !verboseTrace && !resynced && key == Whoop.dataUUID && onlyHistory {
            quiet.notifications += 1
            quiet.bytes += bytes.count
            var effects: [Effect] = []
            for frame in frames {
                let packet = Whoop.decode(frame)
                if frame.packetType == Int(Whoop.PacketType.realtimeRaw.rawValue) {
                    if case .rawMotion = packet { quietRaw.motion += 1 } else { quietRaw.other += 1 }
                } else if frame.packetType == Int(Whoop.PacketType.realtimeData.rawValue) {
                    quietRaw.heartRate += 1
                } else {
                    quiet.frames += 1
                }
                effects += handle(packet, frame: frame, channel: key, now: now)
            }
            return effects
        }
        var effects = flushQuiet()
        effects.append(.trace("RX \(channel) \(key) len=\(bytes.count) \(Whoop.hex(bytes))"))
        for frame in frames {
            let declared = frame.raw.count >= 3 ? Int(frame.raw[1]) | Int(frame.raw[2]) << 8 : -1
            effects.append(.trace("  FRAME \(frame.typeName) seq=\(frame.seq) op=\(frame.opcode) len=\(frame.raw.count) declared=\(declared) crc8=\(frame.headerCRCOK ? "ok" : "FAIL") crc32=\(frame.payloadCRCOK ? "ok" : "FAIL")"))
            guard frame.valid else {
                badFrames += 1
                effects.append(log(.fromBand, key, "Bad checksum (\(frame.typeName))", frame.raw, ok: false))
                continue
            }
            effects += handle(Whoop.decode(frame), frame: frame, channel: key, now: now)
        }
        if resynced {
            effects.append(.trace("  RESYNC skipped \(reassembler.droppedBytes - droppedBefore) bytes looking for the next frame start"))
        }
        if reassembler.pendingBytes > 0 {
            effects.append(.trace("  WAITING \(reassembler.pendingBytes) bytes of a frame that continues in the next notification"))
        }
        return effects
    }

    /// The connection is kept open (like WHOOP's own app): after a finished download, ask for what
    /// the band recorded since. The clock was set when this connection started; battery and data
    /// range are read again so the screens stay fresh. Does nothing unless the last download finished.
    public mutating func pullAgain() -> [Effect] {
        guard phase == .finished else { return [] }
        phase = .syncing
        sync = HistorySync(maxRetries: sync.maxRetries, startSeq: 32, discardBefore: sync.discardBefore)
        range = nil
        var effects = write(Whoop.Command.getBattery(seq: seq.next()), "GET_BATTERY_LEVEL")
        effects += write(Whoop.Command.getDataRange(seq: seq.next()), "GET_DATA_RANGE")
        return effects + map(sync.start(setClockTo: nil))
    }

    /// The app's watchdog saw no data for a while during the download.
    public mutating func stalled() -> [Effect] {
        guard phase == .syncing else { return [] }
        return map(sync.stalled())
    }

    /// Turns the band's live heart-rate stream on or off (the live screens, and the heartbeat that keeps Pulse awake while
    /// the 100 Hz stream is off, `MotionStreamPolicy.heartbeat`).
    public mutating func setLive(_ on: Bool) -> [Effect] {
        let command = Whoop.Command.realtimeHR(on: on, seq: seq.next())
        return flushQuiet() + write(command, "TOGGLE_REALTIME_HR")
    }

    /// Turns the band's 100 Hz motion stream on or off (step counting, docs/METRICS.md §15).
    public mutating func setRawStream(_ on: Bool) -> [Effect] {
        motionClock = MotionClock()             // a new stream starts at the phone's time
        return flushQuiet() + write(Whoop.Command.rawStream(on: on, seq: seq.next()), "SEND_R10_R11_REALTIME \(on ? "on" : "off")")
    }

    /// Call after the batch from `.persist` is safely on disk. Returns the ack for the band.
    public mutating func didPersist(token: [UInt8], recordCount: Int) -> [Effect] {
        var effects = map(sync.didPersist(token: token, recordCount: recordCount))
        if !effects.isEmpty {
            effects.append(.progress(progress))
        }
        return effects
    }

    // MARK: - Internals

    private mutating func handle(_ packet: Whoop.Packet, frame: Whoop.Frame, channel: String, now: Double) -> [Effect] {
        switch packet {
        case .commandResponse, .metadata, .history: downloadActivity &+= 1
        case .realtime, .event, .rawMotion, .unknown: break
        }
        switch packet {
        case .commandResponse(let response):
            var effects = [log(.fromBand, channel, "\(response.opcodeName) -> \(response.statusName)", frame.raw)]
            var changed = false
            if let battery = response.batteryPercent { info.batteryPercent = battery; changed = true }
            if response.opcode == Int(Whoop.Cmd.getBatteryLevel.rawValue) {
                // Every reading, with where it came from: to tell a real 0% from a bad read later.
                effects.append(.trace(response.batteryPercent.map { String(format: "BATTERY %.1f%% (GET_BATTERY_LEVEL, fresh)", $0) }
                    ?? "BATTERY no valid reading: GET_BATTERY_LEVEL status \(response.statusName), body \(Whoop.hex(response.body))"))
            }
            if let r = response.dataRange, r.capacityPages > 0, r.writePage <= r.capacityPages, r.trimPage <= r.capacityPages {
                if range == nil { range = (r.trimPage, r.writePage, r.capacityPages) }
                let behind = (Int64(r.writePage) - Int64(r.trimPage) + Int64(r.capacityPages)) % Int64(r.capacityPages)
                let span = [r.oldestRecord, r.newestRecord].map { $0.map(HistorySync.utc) ?? "?" }
                effects.append(.trace("DATA_RANGE \(behind) pages to sync (trim \(r.trimPage), write \(r.writePage), capacity \(r.capacityPages)), used \(r.usedRecords) records, free \(r.freeRecords), oldest \(span[0]), newest \(span[1])"))
            }
            if response.opcode == Int(Whoop.Cmd.reportVersionInfo.rawValue), !response.body.isEmpty {
                info.firmware = response.versionText
                info.firmwareRawHex = Whoop.hex(response.body)
                changed = true
            }
            if changed { effects.append(.info(info)) }
            if response.opcode == Int(Whoop.Cmd.getClock.rawValue) {
                if let raw = response.bandClockRaw {
                    info.bandClock = raw
                    info.bandClockReadAt = now
                    info.bandClockSource = "GET_CLOCK"
                    let offset = info.clockOffsetSeconds.map { String(format: "%+.1f s", $0) } ?? "not set"
                    effects.append(.trace("CLOCK band \(Whoop.plausibleUnix(raw) ? HistorySync.utc(raw) : "unset (\(raw))"), band - phone = \(offset)"))
                    effects.append(.info(info))
                } else {
                    effects.append(.trace("CLOCK answer without a time: status \(response.statusName), \(response.body.count) body bytes"))
                }
                // Always set it to the phone's time: the band's clock dates every record it stores.
                if phase == .hello { effects += beginHistory(setClockTo: now) }
            }
            return effects

        case .event(let event):
            var effects = [log(.fromBand, channel, "Event \(event.eventName)", frame.raw)]
            var changed = false
            if let battery = event.batteryPercent { info.batteryPercent = battery; changed = true }
            if let charging = event.charging { info.isCharging = charging; changed = true }
            let at = Whoop.plausibleUnix(event.timestamp) ? HistorySync.utc(event.timestamp) : "unset clock (\(event.timestamp))"
            switch Whoop.EventID(rawValue: UInt16(truncatingIfNeeded: event.eventID)) {
            case .wristOn: info.isWorn = true; changed = true
            case .wristOff: info.isWorn = false; changed = true
            case .chargingOn:
                info.isCharging = true; changed = true
                effects.append(.trace("CHARGING ON (band event at \(at))"))
            case .chargingOff:
                info.isCharging = false; changed = true
                effects.append(.trace("CHARGING OFF (band event at \(at))"))
            case .batteryLevel:
                let volts = event.batteryMillivolts.map { "\($0) mV" } ?? "? mV"
                let plugged = event.charging == true ? "yes" : "no"
                effects.append(.trace(event.batteryPercent.map {
                    String(format: "BATTERY %.1f%%", $0) + " (band event at \(at), \(volts), charging \(plugged))"
                } ?? "BATTERY event without a valid reading at \(at): body \(Whoop.hex(event.body))"))
            case .boot:
                effects.append(.trace("BAND REBOOTED (BOOT event at \(at)): if the battery was near 0%, it ran flat"))
            case .rtcLost:
                effects.append(.trace("BAND CLOCK LOST (RTC_LOST event at \(at)): it lost power or reset; records stamped before the next SET_CLOCK have no real date"))
            case .setRtc:
                effects.append(.trace("Band confirms its clock was set (SET_RTC event at \(at))"))
            default: break
            }
            if changed { effects.append(.info(info)) }
            return effects

        case .realtime(let reading):
            return reading.heartRate > 0 ? [.liveHeartRate(reading.heartRate)] : []

        case .metadata(let meta):
            // One log line per batch boundary (not per record: a night is ~30,000 records).
            var effects = flushQuiet() + [log(.fromBand, channel, "\(meta.metaName)", frame.raw)]
            // Each HISTORY_END carries the band's own clock: a free reading when GET_CLOCK says nothing.
            if let stamp = meta.timestamp, info.bandClockSource != "GET_CLOCK" {
                info.bandClock = stamp
                info.bandClockReadAt = now
                info.bandClockSource = "HISTORY_END"
                effects.append(.info(info))
            }
            return effects + map(sync.handle(packet))

        case .history:
            return map(sync.handle(packet))

        case .rawMotion(let motion):
            // The packet's own time field is not the time on the owner's firmware: each second gets the phone's clock.
            guard let second = motionClock.second(for: motion, receivedAt: now) else { return [] }
            return [.rawMotion(Whoop.RawMotion(timestamp: second, subsec: 0, heartRate: motion.heartRate, accel: motion.accel))]

        case .unknown(let type, let typeName, _):
            // The stream's optical variant: counted in the summary, not logged one by one.
            if type == Int(Whoop.PacketType.realtimeRaw.rawValue) { return [] }
            return [log(.fromBand, channel, "Unknown packet \(typeName)", frame.raw)]
        }
    }

    private mutating func beginHistory(setClockTo unixTime: Double?) -> [Effect] {
        guard phase == .hello else { return [] }       // only once
        phase = .syncing
        var effects: [Effect] = []
        if let unixTime {
            info.clockWasSet = true
            effects.append(.info(info))
            effects += write(Whoop.Command.setClock(seq: seq.next(), unixTime: unixTime), "SET_CLOCK")
            // Read it back: [OS] warns a wrong SET_CLOCK is acknowledged but silently ignored.
            effects += write(Whoop.Command.getClock(seq: seq.next()), "GET_CLOCK (check)")
        }
        return effects + map(sync.start(setClockTo: nil))
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
                effects.append(.trace("FAILED: \(message)"))
                effects.append(.failed(message))
            case .note(let text):
                effects.append(.trace(text))
            case .cleared:
                effects.append(.progress(progress))
            }
        }
        return effects
    }

    private mutating func write(_ bytes: [UInt8], _ description: String) -> [Effect] {
        [log(.toBand, Whoop.cmdToStrapUUID, description, bytes),
         .trace("TX CMD \(description) len=\(bytes.count) \(Whoop.hex(bytes))"),
         .write(bytes, description: description)]
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
