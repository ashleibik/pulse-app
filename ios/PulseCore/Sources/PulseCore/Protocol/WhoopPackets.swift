import Foundation

// Decoding valid frames into meaningful packets. Port of re-toolkit/protocol/parser.py.
// Offsets are into frame.inner (inner[0] = packet type). Confidence levels: docs/PROTOCOL.md.

extension Whoop {

    /// REALTIME_DATA (0x28). Layout REPORTED [OS], consistent with the [BW] sample.
    public struct RealtimeHR: Sendable, Equatable {
        public let timestamp: UInt32      // [2:6]
        public let subsec: UInt16         // [6:8] units UNKNOWN
        public let heartRate: Int         // [8], 0 = no reading
        public let rrMs: [Int]            // count at [9], i16 LE ms at [10 + 2i], max 4
        public let wearing: Bool?         // [18]
    }

    public struct DataRange: Sendable, Equatable {
        public let writePage, trimPage, wrapCount, capacityPages, usedRecords, freeRecords: UInt32
        public let oldestRecord: UInt32?
        public let newestRecord: UInt32?
    }

    /// COMMAND_RESPONSE (0x24). Layout REPORTED [OS].
    public struct CommandResponse: Sendable, Equatable {
        public let opcode: Int               // [2]
        public let opcodeName: String
        public let requestSeq: Int?          // [3]
        public let status: Int?              // [4]
        public let statusName: String
        public let body: [UInt8]             // [5...]
        public var batteryPercent: Double?
        public var bandClock: UInt32?        // nil if implausible (clock not set)
        public var bandClockRaw: UInt32?
        public var dataRange: DataRange?
        public var asciiView: String?        // REPORT_VERSION_INFO: layout UNKNOWN, show readable text
    }

    /// EVENT (0x30). Layout REPORTED [OS].
    public struct Event: Sendable, Equatable {
        public let eventID: Int              // [2:4]
        public let eventName: String
        public let timestamp: UInt32         // [4:8]
        public let subsec: UInt16            // [8:10]
        public let body: [UInt8]             // [12 : 12 + u16 at 10]
        public var batteryPercent: Double?
        public var batteryMillivolts: UInt32?
        public var charging: Bool?
    }

    /// METADATA (0x31): history markers. HISTORY_END layout REPORTED [OS], matches [BW] sample.
    public struct Metadata: Sendable, Equatable {
        public let metaType: Int             // [2]
        public let metaName: String
        public var timestamp: UInt32?        // [3:7]   (HISTORY_END)
        public var expectedPackets: UInt32?  // [9:13]
        public var token: [UInt8]?           // [13:21] echoed back in the ack
    }

    /// HISTORICAL_DATA (0x2F): one stored ~1 Hz record. Partly decoded (REPORTED [OS]).
    public struct HistoryRecord: Sendable, Equatable {
        public let version: Int              // [1]
        public let counter: UInt32           // [3:7]
        public let timestamp: UInt32         // [7:11]
        public let subsec: UInt16            // [11:13]
        public let heartRate: Int            // [17], 0 = off wrist
        public let accelG: [Double]?         // [36:48] 3 x float32, gravity vector (nil if implausible)
        public let rrMsUnverified: [Int]     // UNKNOWN layout guess: count [18], i16 from [19]
        public let length: Int
    }

    public enum Packet: Sendable, Equatable {
        case realtime(RealtimeHR)
        case commandResponse(CommandResponse)
        case event(Event)
        case metadata(Metadata)
        case history(HistoryRecord)
        case unknown(packetType: Int, typeName: String, inner: [UInt8])
    }

    static let rrRangeMs = 200...2500

    /// Decode one VALID frame. Anything not understood comes back as `.unknown` with its bytes.
    public static func decode(_ frame: Frame) -> Packet {
        let inner = frame.inner
        let decoded: Packet?
        let type = frame.packetType >= 0 ? PacketType(rawValue: UInt8(frame.packetType)) : nil
        switch type {
        case .realtimeData: decoded = decodeRealtime(inner)
        case .commandResponse: decoded = .commandResponse(decodeCommandResponse(inner))
        case .event: decoded = decodeEvent(inner)
        case .metadata: decoded = .metadata(decodeMetadata(inner))
        case .historicalData: decoded = decodeHistory(inner)
        default: decoded = nil
        }
        return decoded ?? .unknown(packetType: frame.packetType, typeName: frame.typeName, inner: inner)
    }

    static func rrList(_ inner: [UInt8], countAt off: Int, maxCount: Int = 4) -> [Int] {
        guard inner.count > off else { return [] }
        let count = Int(inner[off])
        guard count <= maxCount else { return [] }
        var out: [Int] = []
        for i in 0..<count {
            let at = off + 1 + 2 * i
            if at + 2 > inner.count { break }
            let v = Int(LE.i16(inner, at))
            if rrRangeMs.contains(v) { out.append(v) }
        }
        return out
    }

    static func decodeRealtime(_ inner: [UInt8]) -> Packet? {
        guard inner.count >= 10 else { return nil }
        return .realtime(RealtimeHR(timestamp: LE.u32(inner, 2), subsec: LE.u16(inner, 6), heartRate: Int(inner[8]),
                                    rrMs: rrList(inner, countAt: 9),
                                    wearing: inner.count > 18 ? inner[18] != 0 : nil))
    }

    static func decodeCommandResponse(_ inner: [UInt8]) -> CommandResponse {
        let opcode = inner.count > 2 ? Int(inner[2]) : -1
        let status: Int? = inner.count > 4 ? Int(inner[4]) : nil
        var r = CommandResponse(opcode: opcode, opcodeName: name(Cmd.self, opcode),
                                requestSeq: inner.count > 3 ? Int(inner[3]) : nil,
                                status: status, statusName: status.map { name(ResponseStatus.self, $0) } ?? "",
                                body: inner.count > 5 ? Array(inner[5...]) : [])
        let cmd = opcode >= 0 ? Cmd(rawValue: UInt8(opcode)) : nil
        switch cmd {
        case .getBatteryLevel where inner.count >= 7:
            let pct = Double(LE.u16(inner, 5)) / 10
            if (0...100).contains(pct) { r.batteryPercent = pct }
        case .getClock where inner.count >= 9:
            let ts = LE.u32(inner, 5)
            r.bandClock = plausibleUnix(ts) ? ts : nil
            r.bandClockRaw = ts
        case .getDataRange where inner.count >= 38:
            var oldest: UInt32?, newest: UInt32?
            if inner.count >= 66 {
                let o = LE.u32(inner, 38), n = LE.u32(inner, 62)
                if plausibleUnix(o) && plausibleUnix(n) { (oldest, newest) = (o, n) }
            }
            r.dataRange = DataRange(writePage: LE.u32(inner, 14), trimPage: LE.u32(inner, 18),
                                    wrapCount: LE.u32(inner, 22), capacityPages: LE.u32(inner, 26),
                                    usedRecords: LE.u32(inner, 30), freeRecords: LE.u32(inner, 34),
                                    oldestRecord: oldest, newestRecord: newest)
        case .reportVersionInfo:
            r.asciiView = String(r.body.map { (32..<127).contains($0) ? Character(UnicodeScalar($0)) : "." })
        default:
            break
        }
        return r
    }

    static func decodeEvent(_ inner: [UInt8]) -> Packet? {
        guard inner.count >= 12 else { return nil }
        let id = Int(LE.u16(inner, 2))
        let bodyLength = Int(LE.u16(inner, 10))
        let body = Array(inner[12..<min(inner.count, 12 + bodyLength)])
        var e = Event(eventID: id, eventName: name(EventID.self, id), timestamp: LE.u32(inner, 4),
                      subsec: LE.u16(inner, 8), body: body)
        if id == Int(EventID.batteryLevel.rawValue) && body.count >= 10 {
            let pct = Double(LE.u32(body, 1)) / 10
            if (0...100).contains(pct) {
                e.batteryPercent = pct
                let mv = LE.u32(body, 5)
                if (2500...4500).contains(mv) { e.batteryMillivolts = mv }
                e.charging = body[9] != 0
            }
        }
        return .event(e)
    }

    static func decodeMetadata(_ inner: [UInt8]) -> Metadata {
        let type = inner.count > 2 ? Int(inner[2]) : -1
        var m = Metadata(metaType: type, metaName: name(MetaType.self, type))
        if type == Int(MetaType.historyEnd.rawValue) {
            if inner.count >= 7, plausibleUnix(LE.u32(inner, 3)) { m.timestamp = LE.u32(inner, 3) }
            if inner.count >= 13 { m.expectedPackets = LE.u32(inner, 9) }
            if inner.count >= 21 { m.token = Array(inner[13..<21]) }
        }
        return m
    }

    static func decodeHistory(_ inner: [UInt8]) -> Packet? {
        guard inner.count >= 18 else { return nil }
        var accel: [Double]?
        if inner.count >= 48 {
            let x = Double(LE.f32(inner, 36)), y = Double(LE.f32(inner, 40)), z = Double(LE.f32(inner, 44))
            let mag2 = x * x + y * y + z * z
            if (0.25...3.24).contains(mag2) { accel = [x, y, z] }   // 0.5-1.8 g: a sane gravity vector
        }
        return .history(HistoryRecord(version: Int(inner[1]), counter: LE.u32(inner, 3), timestamp: LE.u32(inner, 7),
                                      subsec: LE.u16(inner, 11), heartRate: Int(inner[17]), accelG: accel,
                                      rrMsUnverified: rrList(inner, countAt: 18), length: inner.count))
    }

    // MARK: - Standard Heart Rate Measurement (0x2A37), Bluetooth SIG spec

    public struct HeartRateMeasurement: Sendable, Equatable {
        public let heartRate: Int
        public let contact: Bool?        // nil = sensor doesn't report contact
        public let rrMs: [Double]        // converted from 1/1024 s
    }

    public static func parseHeartRateMeasurement(_ data: [UInt8]) -> HeartRateMeasurement? {
        guard let flags = data.first else { return nil }
        var i = 1
        let hr: Int
        if flags & 0x01 != 0 {
            guard data.count >= 3 else { return nil }
            hr = Int(LE.u16(data, 1)); i = 3
        } else {
            guard data.count >= 2 else { return nil }
            hr = Int(data[1]); i = 2
        }
        let contact: Bool? = flags & 0x04 != 0 ? (flags & 0x02 != 0) : nil
        if flags & 0x08 != 0 { i += 2 }   // energy expended: skip
        var rr: [Double] = []
        if flags & 0x10 != 0 {
            while i + 1 < data.count {
                rr.append(Double(LE.u16(data, i)) * 1000 / 1024)
                i += 2
            }
        }
        return HeartRateMeasurement(heartRate: hr, contact: contact, rrMs: rr)
    }
}
