import Foundation

// Frames: build, parse, reassemble.  Port of re-toolkit/protocol/{crc,frames}.py
//
//   AA | len (u16 LE) | CRC8(len) | inner (zero-padded to x4) | CRC32(inner) (u32 LE)
//   len = inner.count + 4. inner[0] = packet type, [1] = seq / record version, [2] = opcode.

extension Whoop {

    // MARK: - Checksums (VERIFIED against real captures)

    /// CRC-8/SMBUS: poly 0x07, init 0, no reflection, no final XOR. Covers the 2 length bytes.
    public static func crc8(_ data: some Sequence<UInt8>) -> UInt8 {
        var crc: UInt8 = 0
        for byte in data {
            crc ^= byte
            for _ in 0..<8 {
                crc = (crc & 0x80) != 0 ? (crc << 1) ^ 0x07 : crc << 1
            }
        }
        return crc
    }

    private static let crc32Table: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    /// Standard zlib/IEEE CRC-32. Covers the padded inner bytes.
    public static func crc32(_ data: some Sequence<UInt8>) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = crc32Table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    // MARK: - Frame

    public struct Frame: Sendable, Equatable {
        public let raw: [UInt8]
        public let inner: [UInt8]
        public let headerCRCOK: Bool
        public let payloadCRCOK: Bool

        public var valid: Bool { headerCRCOK && payloadCRCOK }
        public var packetType: Int { inner.count > 0 ? Int(inner[0]) : -1 }
        public var seq: Int { inner.count > 1 ? Int(inner[1]) : -1 }
        public var opcode: Int { inner.count > 2 ? Int(inner[2]) : -1 }
        public var body: [UInt8] { inner.count > 3 ? Array(inner[3...]) : [] }
        public var typeName: String { Whoop.name(PacketType.self, packetType) }
    }

    /// Parse one frame from the start of `raw`. nil = not a complete frame (yet).
    /// A frame whose checksums fail is still returned, with `valid == false`.
    public static func parseFrame(_ raw: [UInt8]) -> Frame? {
        guard raw.count >= headerLength + crc32Length, raw[0] == startOfFrame else { return nil }
        let declared = Int(LE.u16(raw, 1))
        guard declared >= crc32Length, headerLength + declared <= maxFrameLength else { return nil }
        let total = headerLength + declared
        guard raw.count >= total else { return nil }
        let inner = Array(raw[headerLength..<(total - crc32Length)])
        return Frame(raw: Array(raw[0..<total]), inner: inner,
                     headerCRCOK: crc8(raw[1..<3]) == raw[3],
                     payloadCRCOK: crc32(inner) == LE.u32(raw, total - crc32Length))
    }

    /// Wrap inner bytes in header + CRC32 (zero-padding inner to a multiple of 4).
    public static func buildFrame(inner: [UInt8]) -> [UInt8] {
        let padded = inner + [UInt8](repeating: 0, count: (4 - inner.count % 4) % 4)
        let length = LE.bytes(UInt16(padded.count + crc32Length))
        return [startOfFrame] + length + [crc8(length)] + padded + LE.bytes(crc32(padded))
    }

    // MARK: - Reassembly

    /// Turns BLE notification chunks back into frames. One per characteristic.
    /// Reads the length from the header and waits for that many bytes; on a bad header it skips to
    /// the next 0xAA ("resync"). Zero bytes between frames are padding and are skipped silently.
    public struct FrameReassembler: Sendable {
        public static let maxBuffer = 8192
        private var buffer: [UInt8] = []
        /// Junk bytes skipped while resyncing (diagnostics; should stay ~0 on a healthy link).
        public private(set) var droppedBytes = 0

        public init() {}

        /// Bytes waiting for the rest of their frame (debug log: a frame split across notifications).
        public var pendingBytes: Int { buffer.count }

        public mutating func feed(_ chunk: [UInt8]) -> [Frame] {
            buffer.append(contentsOf: chunk)
            if buffer.count > Self.maxBuffer {
                droppedBytes += buffer.count
                buffer.removeAll()
                return []
            }
            var frames: [Frame] = []
            while true {
                let zeros = buffer.prefix { $0 == 0x00 }.count
                if zeros > 0 { buffer.removeFirst(zeros) }
                guard buffer.count >= headerLength else { break }
                guard buffer[0] == startOfFrame, crc8(buffer[1..<3]) == buffer[3] else {
                    resync()
                    continue
                }
                let declared = Int(LE.u16(buffer, 1))
                guard declared >= crc32Length, headerLength + declared <= maxFrameLength else {
                    resync()
                    continue
                }
                let total = headerLength + declared
                guard buffer.count >= total else { break }
                let frame = parseFrame(Array(buffer[0..<total]))
                buffer.removeFirst(total)
                if let frame { frames.append(frame) }
            }
            return frames
        }

        private mutating func resync() {
            let cut = buffer.dropFirst().firstIndex(of: startOfFrame) ?? buffer.count
            droppedBytes += cut
            buffer.removeFirst(cut)
        }
    }

    // MARK: - Building commands

    public struct UnsafeCommandError: Error, Equatable {
        public let opcode: UInt8
    }

    /// inner = [0x23, seq, opcode, payload...]. Refuses anything not on the allowlist. No override.
    public static func buildCommand(_ opcode: UInt8, payload: [UInt8] = [0x00], seq: UInt8) throws -> [UInt8] {
        guard allowedOpcodes.contains(opcode) else { throw UnsafeCommandError(opcode: opcode) }
        return buildFrame(inner: [PacketType.command.rawValue, seq, opcode] + payload)
    }

    /// For the named builders below: all their opcodes are on the allowlist by construction.
    private static func allowed(_ cmd: Cmd, _ payload: [UInt8], _ seq: UInt8) -> [UInt8] {
        do { return try buildCommand(cmd.rawValue, payload: payload, seq: seq) }
        catch { preconditionFailure("\(cmd) must be on the allowlist") }
    }

    /// Rolling 0-255 command counter (the band echoes it in responses).
    public struct SeqCounter: Sendable {
        private var value: UInt8
        public init(start: UInt8 = 0) { value = start }
        public mutating func next() -> UInt8 {
            defer { value = value &+ 1 }
            return value
        }
    }

    public enum Command {
        /// Standard HR service (0x2A37) on/off. Persistent on the band: ask the user first.
        public static func hrBroadcast(on: Bool, seq: UInt8) -> [UInt8] { allowed(.setGenericHrProfile, [on ? 1 : 0], seq) }
        /// ~1 Hz REALTIME_DATA packets on/off.
        public static func realtimeHR(on: Bool, seq: UInt8) -> [UInt8] { allowed(.toggleRealtimeHr, [on ? 1 : 0], seq) }
        /// The 100 Hz motion (and optical) stream, packet type 0x2B, on/off. It stays on across reconnects:
        /// every connect turns it off, and only a step test turns it on.
        public static func rawStream(on: Bool, seq: UInt8) -> [UInt8] { allowed(.sendR10R11Realtime, [on ? 1 : 0], seq) }
        public static func reportVersion(seq: UInt8) -> [UInt8] { allowed(.reportVersionInfo, [], seq) }
        public static func getBattery(seq: UInt8) -> [UInt8] { allowed(.getBatteryLevel, [], seq) }
        /// [OS] sends an empty body; frames are padded to 4 bytes, so `00` gives the same bytes on the wire.
        public static func getClock(seq: UInt8) -> [UInt8] { allowed(.getClock, [0x00], seq) }
        public static func getHello(seq: UInt8) -> [UInt8] { allowed(.getHelloHarvard, [0x00], seq) }
        public static func getDataRange(seq: UInt8) -> [UInt8] { allowed(.getDataRange, [0x00], seq) }
        public static func sendHistoricalData(seq: UInt8) -> [UInt8] { allowed(.sendHistoricalData, [0x00], seq) }

        /// u32 seconds LE, u16 sub-seconds (1/32768 s) LE, 2 zero bytes. Exactly 8 bytes ([OS]).
        public static func setClock(seq: UInt8, unixTime: Double) -> [UInt8] {
            let secs = UInt32(unixTime.rounded(.towardZero))
            let subsec = UInt16(truncatingIfNeeded: Int((unixTime - Double(secs)) * 32768))
            return allowed(.setClock, LE.bytes(secs) + LE.bytes(subsec) + [0, 0], seq)
        }

        /// Ack one history batch: 0x01 + the 8-byte token from HISTORY_END.
        /// Send ONLY after the batch is saved. nil if the token isn't 8 bytes.
        public static func historyAck(token: [UInt8], seq: UInt8) -> [UInt8]? {
            guard token.count == 8 else { return nil }
            return allowed(.historicalDataResult, [0x01] + token, seq)
        }
    }
}

// MARK: - Hex (debug log)

extension Whoop {
    private static let hexDigits = Array("0123456789abcdef".utf8)

    /// "aa 18 00 ..." Fast enough to run on every notification of a big sync.
    public static func hex(_ bytes: some Collection<UInt8>) -> String {
        var out = [UInt8]()
        out.reserveCapacity(bytes.count * 3)
        for byte in bytes {
            if !out.isEmpty { out.append(0x20) }
            out.append(hexDigits[Int(byte >> 4)])
            out.append(hexDigits[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }
}

// MARK: - Little-endian helpers

enum LE {
    static func u16(_ b: [UInt8], _ off: Int) -> UInt16 {
        UInt16(b[off]) | UInt16(b[off + 1]) << 8
    }
    static func i16(_ b: [UInt8], _ off: Int) -> Int16 { Int16(bitPattern: u16(b, off)) }
    static func u32(_ b: [UInt8], _ off: Int) -> UInt32 {
        UInt32(b[off]) | UInt32(b[off + 1]) << 8 | UInt32(b[off + 2]) << 16 | UInt32(b[off + 3]) << 24
    }
    static func f32(_ b: [UInt8], _ off: Int) -> Float { Float(bitPattern: u32(b, off)) }

    static func bytes(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
    static func bytes(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)]
    }
    static func bytes(_ v: Int16) -> [UInt8] { bytes(UInt16(bitPattern: v)) }
    static func bytes(_ v: Float) -> [UInt8] { bytes(v.bitPattern) }
}
