import Foundation
@testable import PulseCore

// TEST SUPPORT ONLY. Lives in the test target, so it can never be part of the app build.

/// A pretend WHOOP band that speaks the protocol byte for byte. It answers commands with
/// notifications, sends stored history in batches, and waits for acks.
///
/// Used by tests, so the whole Bluetooth pipeline can be exercised without hardware. Its packet layouts follow docs/PROTOCOL.md; where the real
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

        public init(characteristic: String, bytes: [UInt8]) {
            self.characteristic = characteristic
            self.bytes = bytes
        }
    }

    public var mtuPayload: Int                 // bytes per notification (BLE MTU - 3)
    public var batteryDeciPercent: UInt16 = 765
    public var clock: UInt32
    /// Test hook: drop this outgoing notification index once (simulates a lost packet).
    public var dropNotificationIndex: Int?
    public private(set) var acksReceived: [[UInt8]] = []
    /// True while the app has asked for live heart rate (TOGGLE_REALTIME_HR).
    public private(set) var realtimeOn = false
    /// True while the app has the 100 Hz stream on (SEND_R10_R11_REALTIME). Starts on, like a band left streaming.
    public private(set) var rawStreamOn = true
    public private(set) var commandsReceived: [String] = []

    private var batches: [[Sample]]
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

    /// The band keeps recording while connected: these samples come with the next history request.
    public mutating func record(_ more: [Sample], batchSize: Int = 200) {
        var i = 0
        while i < more.count {
            batches.append(Array(more[i..<min(i + batchSize, more.count)]))
            i += batchSize
        }
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
            // Reply body [u32 seconds][u32 sub-seconds] ([OS] control.dart).
            return respond(opcode, requestSeq, LE.bytes(clock) + LE.bytes(UInt32(0)))
        case .setClock:
            if frame.body.count >= 4 { clock = LE.u32(frame.body, 0) }
            return respond(opcode, requestSeq, [])
        case .getDataRange:
            // 65-byte body ([OS] control.dart): rev 1, then u32 pages at body[1...]; we fill
            // write [9], trim [13], wrap [17], capacity [21], used [25], free [29].
            var body = [UInt8](repeating: 0, count: 65)
            body[0] = 1
            let fields: [(Int, UInt32)] = [(9, 5000 + UInt32(batches.count)), (13, 5000), (17, 0), (21, 100_000),
                                           (25, UInt32(batches.reduce(0) { $0 + $1.count })), (29, 1_000_000)]
            for (at, value) in fields { body.replaceSubrange(at..<(at + 4), with: LE.bytes(value)) }
            return respond(opcode, requestSeq, body)
        case .toggleRealtimeHr:
            realtimeOn = frame.body.first == 1
            return respond(opcode, requestSeq, [])
        case .sendR10R11Realtime:
            rawStreamOn = frame.body.first == 1
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

    /// One live heart-rate packet (type 0x28), laid out as docs/PROTOCOL.md describes:
    /// timestamp at [2:6], heart rate at [8], "on wrist" at [18].
    public static func realtimeFrame(timestamp: UInt32, heartRate: UInt8) -> [UInt8] {
        var inner = [UInt8](repeating: 0, count: 20)
        inner[0] = Whoop.PacketType.realtimeData.rawValue
        inner.replaceSubrange(2..<6, with: LE.bytes(timestamp))
        inner[8] = heartRate
        inner[18] = 1
        return Whoop.buildFrame(inner: inner)
    }

    /// One second of the 100 Hz stream's motion variant (type 0x2B, 1,920 inner bytes): unix time at [11],
    /// heart rate at [17], x, y and z samples from [85], [285] and [485].
    public static func rawMotionFrame(timestamp: UInt32, heartRate: UInt8 = 80, accel: [[Int16]]) -> [UInt8] {
        var inner = [UInt8](repeating: 0, count: Whoop.RawMotion.innerLength)
        inner[0] = Whoop.PacketType.realtimeRaw.rawValue
        inner[2] = 0x0A
        inner.replaceSubrange(11..<15, with: LE.bytes(timestamp))
        inner[17] = heartRate
        for (axis, start) in [85, 285, 485].enumerated() {
            for (i, value) in accel[axis].prefix(100).enumerated() {
                inner.replaceSubrange((start + 2 * i)..<(start + 2 * i + 2), with: LE.bytes(UInt16(bitPattern: value)))
            }
        }
        return Whoop.buildFrame(inner: inner)
    }

    /// The stream's optical variant (1,924 inner bytes), which Pulse doesn't use.
    public static func rawOpticalFrame(timestamp: UInt32) -> [UInt8] {
        var inner = [UInt8](repeating: 0, count: 1924)
        inner[0] = Whoop.PacketType.realtimeRaw.rawValue
        inner.replaceSubrange(11..<15, with: LE.bytes(timestamp))
        return Whoop.buildFrame(inner: inner)
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
