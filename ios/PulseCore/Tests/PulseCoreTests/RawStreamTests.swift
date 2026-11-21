import Foundation
import Testing
@testable import PulseCore

// The band's 100 Hz motion stream (SEND_R10_R11_REALTIME, packet type 0x2B), used only by the step test.

private func axis(_ value: (Int) -> Int16) -> [Int16] { (0..<100).map(value) }

@Test func theStreamCommandIsAllowedAndBuildsAsNoopSendsIt() throws {
    #expect(Whoop.allowedOpcodes.contains(0x3F))
    let on = try #require(Whoop.parseFrame(Whoop.Command.rawStream(on: true, seq: 5)))
    #expect(on.valid && on.opcode == 0x3F && on.seq == 5 && Array(on.body.prefix(1)) == [1])
    let off = try #require(Whoop.parseFrame(Whoop.Command.rawStream(on: false, seq: 6)))
    #expect(off.opcode == 0x3F && Array(off.body.prefix(1)) == [0])
    // Still refused: erasing, rebooting, firmware.
    #expect(throws: Whoop.UnsafeCommandError.self) { try Whoop.buildCommand(Whoop.Cmd.forceTrim.rawValue, seq: 0) }
}

@Test func aMotionPacketDecodesItsHundredSamplesPerAxis() throws {
    let x = axis { Int16($0 * 10) }, y = axis { Int16(-$0) }, z = axis { _ in 4096 }
    let bytes = SimulatedBand.rawMotionFrame(timestamp: 1_795_000_000, heartRate: 92, accel: [x, y, z])
    let frame = try #require(Whoop.parseFrame(bytes))
    #expect(frame.valid && frame.raw.count == 1928)              // 1,924 declared + the 4-byte header
    guard case .rawMotion(let motion) = Whoop.decode(frame) else { Issue.record("not decoded as motion"); return }
    #expect(motion.timestamp == 1_795_000_000 && motion.heartRate == 92)
    #expect(motion.accel == [x, y, z])
}

@Test func theOpticalVariantStaysUnknown() throws {
    let frame = try #require(Whoop.parseFrame(SimulatedBand.rawOpticalFrame(timestamp: 1_795_000_000)))
    guard case .unknown(let type, _, _) = Whoop.decode(frame) else { Issue.record("decoded"); return }
    #expect(type == 0x2B)
}

@Test func streamedPacketsReachTheAppQuietly() {
    var session = BandSession()
    _ = session.start()
    var motions: [Whoop.RawMotion] = []
    var logs = 0
    var traces: [String] = []
    func feed(_ frame: [UInt8], at now: Double) {
        // As the band sends them: 244-byte notifications, so one packet spans eight.
        var i = 0
        while i < frame.count {
            let chunk = Array(frame[i..<min(i + 244, frame.count)])
            for effect in session.receive(characteristic: Whoop.dataUUID, bytes: chunk, now: now) {
                switch effect {
                case .rawMotion(let m): motions.append(m)
                case .log: logs += 1
                case .trace(let line): traces.append(line)
                default: break
                }
            }
            i += 244
        }
    }
    for second in 0..<5 {
        let now = 1_795_000_000.4 + Double(second)
        feed(SimulatedBand.rawMotionFrame(timestamp: 1_795_000_000 + UInt32(second), accel: [axis { _ in 0 }, axis { _ in 0 }, axis { _ in 4096 }]),
             at: now)
        feed(SimulatedBand.rawOpticalFrame(timestamp: 1_795_000_000 + UInt32(second)), at: now)
    }
    #expect(motions.map(\.timestamp) == (0..<5).map { 1_795_000_000 + UInt32($0) })
    #expect(logs == 0)                                           // never one line per packet
    #expect(traces.isEmpty)
    // Turning the stream off writes the one summary line.
    let off = session.setRawStream(false)
    let summary = off.compactMap { if case .trace(let line) = $0 { line } else { nil } }
    #expect(summary.contains { $0.contains("REALTIME_RAW: 5 motion and 5 other packets") })
    #expect(off.contains { if case .write(_, let d) = $0 { d == "SEND_R10_R11_REALTIME off" } else { false } })
}

// MARK: - Dating the stream by the phone's clock

/// Values the owner's band put in the packets' time field (backup of 2026-11-21): not the time at all.
private let bandTimeFields: [UInt32] = [1_686_115_560, 2_158_128_000, 1_686_142_020, 1_686_387_660, 1_686_665_940]

private func packet(_ field: UInt32, z: Int16 = 4096) -> Whoop.RawMotion {
    Whoop.RawMotion(timestamp: field, subsec: 0, heartRate: 80, accel: [axis { _ in 0 }, axis { _ in 0 }, axis { _ in z }])
}

@Test func theStreamIsDatedByThePhoneNotByThePacketsTimeField() {
    var clock = MotionClock()
    let seconds = (0..<5).compactMap { clock.second(for: packet(bandTimeFields[$0], z: 4096 + Int16($0)), receivedAt: 1_795_287_000.6 + Double($0)) }
    #expect(seconds == (0..<5).map { 1_795_287_000 + UInt32($0) })
}

@Test func aBurstStaysOneSecondAfterAnotherAndAPauseStartsAgain() {
    var clock = MotionClock()
    #expect(clock.second(for: packet(1, z: 1), receivedAt: 1000.2) == 1000)
    // Three packets that waited in Bluetooth arrive together: still one second each.
    #expect(clock.second(for: packet(2, z: 2), receivedAt: 1003.1) == 1001)
    #expect(clock.second(for: packet(3, z: 3), receivedAt: 1003.1) == 1002)
    #expect(clock.second(for: packet(4, z: 4), receivedAt: 1003.2) == 1003)
    // The stream paused for a minute: the next packet is dated by the phone again.
    #expect(clock.second(for: packet(5, z: 5), receivedAt: 1063.5) == 1063)
    // The same packet twice counts once.
    #expect(clock.second(for: packet(5, z: 5), receivedAt: 1063.6) == nil)
    // A still wrist sends equal readings with another time field: that is a new second.
    #expect(clock.second(for: packet(6, z: 5), receivedAt: 1064.5) == 1064)
}

@Test func aWalkWithTheOwnersTimeFieldsIsCountedOnTodaysMinutes() {
    // Two minutes of walking through the session, the packets carrying the band's meaningless time fields.
    var session = BandSession()
    _ = session.start()
    let start = 1_795_287_000.0                 // 2026-11-21 18:50 UTC, a minute boundary
    var counter = StreamStepCounter()
    var minutes: [StepMinute] = []
    for (second, walk) in walkPackets(seconds: 120, stepHz: 1.8, from: 0).enumerated() {
        let field = bandTimeFields[second % bandTimeFields.count] &+ UInt32(second * 7919)
        let bytes = SimulatedBand.rawMotionFrame(timestamp: field, heartRate: 95, accel: walk.accel)
        for effect in session.receive(characteristic: Whoop.dataUUID, bytes: bytes, now: start + Double(second) + 0.3) {
            if case .rawMotion(let motion) = effect { minutes += counter.add(motion) }
        }
    }
    minutes += counter.finish()
    #expect(minutes.map(\.start) == [Date(timeIntervalSince1970: start), Date(timeIntervalSince1970: start + 60)])
    #expect(minutes.allSatisfy { $0.seconds == 60 })
    // 1.8 steps a second: about 108 a minute.
    #expect(minutes.allSatisfy { abs($0.steps - 108) <= 6 }, "\(minutes.map(\.steps))")
}
