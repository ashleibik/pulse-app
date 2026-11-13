import Foundation

/// A pretend WHOOP band that speaks the protocol byte for byte. It answers commands with
/// notifications, sends stored history in batches, and waits for acks.
///
/// Used by tests now, and later by the app's "demo band" mode, so the whole Bluetooth pipeline
/// can be exercised without hardware. Its packet layouts follow docs/PROTOCOL.md; where the real
/// band's behaviour is unknown (e.g. exactly when it resends a batch), it does the simplest
/// plausible thing, and that is noted here.
public struct SimulatedBand: Sendable {

    public struct Sample: Sendable, Equatable {
        public var timestamp: UInt32
        public var heartRate: UInt8
        public var accel: [Float]     // x, y, z in g

        public init(timestamp: UInt32, heartRate: UInt8, accel: [Float]) {
            self.timestamp = timestamp
            self.heartRate = heartRate
            self.accel = accel
        }
    }

    public struct Notification: Sendable, Equatable {
        public let characteristic: String
        public let bytes: [UInt8]
    }

    public var mtuPayload: Int                 // bytes per notification (BLE MTU - 3)
    public var batteryDeciPercent: UInt16 = 765
    public var clock: UInt32
    /// Test hook: drop this outgoing notification index once (simulates a lost packet).
    public var dropNotificationIndex: Int?
    public private(set) var acksReceived: [[UInt8]] = []
    public private(set) var commandsReceived: [String] = []

    private let batches: [[Sample]]
    private var currentBatch = 0
    private var outgoingCount = 0
    private var seq = Whoop.SeqCounter()
    private var counter: UInt32 = 1000

    public init(samples: [Sample], batchSize: Int = 200, mtuPayload: Int = 20, clock: UInt32 = 1_750_000_000) {
        var batches: [[Sample]] = []
        var i = 0
        while i < samples.count {
            batches.append(Array(samples[i..<min(i + batchSize, samples.count)]))
            i += batchSize
        }
        self.batches = batches
        self.mtuPayload = mtuPayload
        self.clock = clock
    }

    /// Token for a batch: u32 "trim page" + u32 "wrap count" (structure per [OS]).
    public static func token(forBatch index: Int) -> [UInt8] {
        LE.bytes(UInt32(5000 + index)) + LE.bytes(UInt32(0))
    }

    /// Handle bytes written to CMD_TO_STRAP. Returns the notifications the band would send back.
    public mutating func receive(write bytes: [UInt8]) -> [Notification] {
        guard let frame = Whoop.parseFrame(bytes), frame.valid,
              frame.packetType == Int(Whoop.PacketType.command.rawValue) else { return [] }
        let opcode = UInt8(frame.opcode)
        let requestSeq = UInt8(frame.seq)
        commandsReceived.append(Whoop.name(Whoop.Cmd.self, frame.opcode))

        switch Whoop.Cmd(rawValue: opcode) {
        case .getBatteryLevel:
            return respond(opcode, requestSeq, LE.bytes(batteryDeciPercent))
        case .getClock:
            return respond(opcode, requestSeq, LE.bytes(clock))
        case .setClock:
            if frame.body.count >= 4 { clock = LE.u32(frame.body, 0) }
            return respond(opcode, requestSeq, [])
        case .sendHistoricalData:
            return sendCurrentBatch()
        case .historicalDataResult:
            let token = Array(frame.body.dropFirst().prefix(8))
            acksReceived.append(token)
            if token == Self.token(forBatch: currentBatch) { currentBatch += 1 }
            // Assumption: after an ack the band continues straight away with the next batch.
            return sendCurrentBatch()
        default:
            return respond(opcode, requestSeq, [])
        }
    }

    // MARK: - Building notifications

    private mutating func respond(_ opcode: UInt8, _ requestSeq: UInt8, _ body: [UInt8]) -> [Notification] {
        let inner = [Whoop.PacketType.commandResponse.rawValue, seq.next(), opcode, requestSeq,
                     Whoop.ResponseStatus.ok.rawValue] + body
        return chunked(Whoop.buildFrame(inner: inner), on: Whoop.cmdFromStrapUUID)
    }

    private mutating func sendCurrentBatch() -> [Notification] {
        var stream: [UInt8] = []
        guard currentBatch < batches.count else {
            stream = Whoop.buildFrame(inner: [Whoop.PacketType.metadata.rawValue, seq.next(),
                                              Whoop.MetaType.historyComplete.rawValue])
            return chunked(stream, on: Whoop.dataUUID)
        }
        let batch = batches[currentBatch]
        for sample in batch {
            stream += Self.historyFrame(sample, counter: counter)
            counter &+= 1
        }
        var end = [Whoop.PacketType.metadata.rawValue, seq.next(), Whoop.MetaType.historyEnd.rawValue]
        end += LE.bytes(batch.last?.timestamp ?? clock) + LE.bytes(UInt16(0))
        end += LE.bytes(UInt32(batch.count)) + Self.token(forBatch: currentBatch)
        stream += Whoop.buildFrame(inner: end)
        return chunked(stream, on: Whoop.dataUUID)
    }

    /// An 88-byte version-24 record with the fields we know about (docs/PROTOCOL.md §8).
    public static func historyFrame(_ s: Sample, counter: UInt32) -> [UInt8] {
        var inner = [UInt8](repeating: 0, count: 88)
        inner[0] = Whoop.PacketType.historicalData.rawValue
        inner[1] = 24
        inner.replaceSubrange(3..<7, with: LE.bytes(counter))
        inner.replaceSubrange(7..<11, with: LE.bytes(s.timestamp))
        inner[17] = s.heartRate
        for (k, value) in s.accel.prefix(3).enumerated() {
            inner.replaceSubrange((36 + 4 * k)..<(40 + 4 * k), with: LE.bytes(value))
        }
        return Whoop.buildFrame(inner: inner)
    }

    private mutating func chunked(_ stream: [UInt8], on characteristic: String) -> [Notification] {
        var out: [Notification] = []
        var i = 0
        while i < stream.count {
            let chunk = Array(stream[i..<min(i + mtuPayload, stream.count)])
            if outgoingCount == dropNotificationIndex {
                dropNotificationIndex = nil      // lose it once
            } else {
                out.append(Notification(characteristic: characteristic, bytes: chunk))
            }
            outgoingCount += 1
            i += mtuPayload
        }
        return out
    }
}
