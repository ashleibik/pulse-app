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
    func feed(_ frame: [UInt8]) {
        // As the band sends them: 244-byte notifications, so one packet spans eight.
        var i = 0
        while i < frame.count {
            let chunk = Array(frame[i..<min(i + 244, frame.count)])
            for effect in session.receive(characteristic: Whoop.dataUUID, bytes: chunk, now: 0) {
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
        feed(SimulatedBand.rawMotionFrame(timestamp: 1_795_000_000 + UInt32(second), accel: [axis { _ in 0 }, axis { _ in 0 }, axis { _ in 4096 }]))
        feed(SimulatedBand.rawOpticalFrame(timestamp: 1_795_000_000 + UInt32(second)))
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
