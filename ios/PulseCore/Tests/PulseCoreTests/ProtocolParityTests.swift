import Foundation
import Testing
@testable import PulseCore

/// The Swift protocol port must reproduce re-toolkit/protocol on shared/test-vectors/protocol_v1.json.
/// Regenerate with `python -m tools.make_protocol_vectors` (in re-toolkit/) after changing the Python side.

// `[String: Any]` isn't Sendable, so Swift 6 can't prove sharing it across test threads is safe.
// It's loaded once and only ever read, which is safe, hence nonisolated(unsafe).
nonisolated(unsafe) let protocolVectors: [String: Any] = {
    let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let data = try! Data(contentsOf: repo.appendingPathComponent("shared/test-vectors/protocol_v1.json"))
    return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
}()

func cases(_ key: String) -> [[String: Any]] { protocolVectors[key] as! [[String: Any]] }

func bytes(_ hex: String) -> [UInt8] {
    var out: [UInt8] = []
    var i = hex.startIndex
    while i < hex.endIndex {
        let j = hex.index(i, offsetBy: 2)
        out.append(UInt8(hex[i..<j], radix: 16)!)
        i = j
    }
    return out
}

func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }

/// JSON numbers come back as NSNumber/Int/Double; null as NSNull.
func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }
func int(_ v: Any?) -> Int? { (v as? NSNumber)?.intValue }

// MARK: - Checksums, frames, builders

@Test func parityCRC() {
    for c in cases("crc") {
        let data = bytes(c["hex"] as! String)
        #expect(Int(Whoop.crc8(data)) == int(c["crc8"]))
        #expect(Int(Whoop.crc32(data)) == int(c["crc32"]))
    }
}

@Test func parityFrameParsing() {
    for c in cases("frames") {
        let name = c["name"] as! String
        let f = Whoop.parseFrame(bytes(c["hex"] as! String))
        #expect((f != nil) == (c["parsed"] as! Bool), "\(name)")
        guard let f else { continue }
        #expect(f.headerCRCOK == (c["header_crc_ok"] as! Bool), "\(name)")
        #expect(f.payloadCRCOK == (c["payload_crc_ok"] as! Bool), "\(name)")
        #expect(hex(f.inner) == c["inner_hex"] as! String, "\(name)")
    }
}

@Test func parityCommandBuilders() {
    for c in cases("builders") {
        let seq = UInt8(int(c["seq"])!)
        let want = c["hex"] as! String
        let got: [UInt8]?
        switch c["name"] as! String {
        case "hr_broadcast": got = Whoop.Command.hrBroadcast(on: c["on"] as! Bool, seq: seq)
        case "realtime_hr": got = Whoop.Command.realtimeHR(on: c["on"] as! Bool, seq: seq)
        case "report_version": got = Whoop.Command.reportVersion(seq: seq)
        case "get_battery": got = Whoop.Command.getBattery(seq: seq)
        case "get_clock": got = Whoop.Command.getClock(seq: seq)
        case "get_hello": got = Whoop.Command.getHello(seq: seq)
        case "get_data_range": got = Whoop.Command.getDataRange(seq: seq)
        case "send_historical_data": got = Whoop.Command.sendHistoricalData(seq: seq)
        case "set_clock": got = Whoop.Command.setClock(seq: seq, unixTime: num(c["when"])!)
        case "history_ack": got = Whoop.Command.historyAck(token: bytes(c["token"] as! String), seq: seq)
        default: got = nil; Issue.record("unknown builder \(c["name"]!)")
        }
        #expect(got.map(hex) == want, "\(c["name"]!)")
    }
    #expect(Whoop.Command.historyAck(token: [1, 2, 3], seq: 0) == nil)
}

@Test func parityAllowlist() {
    let allowed = (protocolVectors["allowed_opcodes"] as! [NSNumber]).map { UInt8($0.intValue) }
    let refused = (protocolVectors["refused_opcodes"] as! [NSNumber]).map { UInt8($0.intValue) }
    #expect(Set(allowed) == Whoop.allowedOpcodes)
    #expect(allowed.count + refused.count == 256)
    for op in refused {
        #expect(throws: Whoop.UnsafeCommandError(opcode: op)) { try Whoop.buildCommand(op, seq: 0) }
    }
    // The dangerous ones, by name, for anyone reading this test:
    for cmd in [Whoop.Cmd.forceTrim, .reboot, .forgetBonds, .powerCycle, .startUpdateLoad, .loadUpdateData,
                .processUpdateImage, .setReadPointer] {
        #expect(throws: Whoop.UnsafeCommandError.self) { try Whoop.buildCommand(cmd.rawValue, seq: 0) }
    }
}

@Test func parityReassembly() {
    for c in cases("reassembly") {
        let stream = bytes(c["stream_hex"] as! String)
        let size = int(c["chunk_size"])!
        var r = Whoop.FrameReassembler()
        var frames: [Whoop.Frame] = []
        var i = 0
        while i < stream.count {
            frames += r.feed(Array(stream[i..<min(i + size, stream.count)]))
            i += size
        }
        #expect(frames.map { hex($0.raw) } == c["frames"] as! [String], "chunk \(size)")
        #expect(frames.map(\.valid) == c["valid"] as! [Bool], "chunk \(size)")
        #expect(r.droppedBytes == int(c["dropped"]), "chunk \(size)")
    }
}

// MARK: - Decoding

@Test func parityDecode() throws {
    for c in cases("decode") {
        let name = c["name"] as! String
        let want = c["decoded"] as! [String: Any]
        let frame = try #require(Whoop.parseFrame(bytes(c["hex"] as! String)))
        let packet = Whoop.decode(frame)
        let kind = want["kind"] as! String
        switch packet {
        case .realtime(let r):
            #expect(kind == "realtime_hr", "\(name)")
            #expect(Int(r.timestamp) == int(want["timestamp"]) && Int(r.subsec) == int(want["subsec"]))
            #expect(r.heartRate == int(want["hr"]))
            #expect(r.rrMs == (want["rr_ms"] as! [NSNumber]).map(\.intValue))
            #expect(r.wearing == want["wearing"] as? Bool)
        case .commandResponse(let r):
            #expect(kind == "command_response", "\(name)")
            #expect(r.opcode == int(want["opcode"]) && r.opcodeName == want["opcode_name"] as! String, "\(name)")
            #expect(r.requestSeq == int(want["request_seq"]) && r.status == int(want["status"]), "\(name)")
            #expect(r.statusName == want["status_name"] as! String, "\(name)")
            #expect(hex(r.body) == want["body_hex"] as! String, "\(name)")
            let d = want["decoded"] as! [String: Any]
            #expect(r.batteryPercent.map { abs($0 - num(d["battery_pct"])!) < 1e-9 } ?? (d["battery_pct"] == nil), "\(name)")
            if d.keys.contains("band_clock_raw") {
                #expect(r.bandClockRaw.map(Int.init) == int(d["band_clock_raw"]), "\(name)")
                #expect(r.bandClock.map(Int.init) == int(d["band_clock"]), "\(name)")
            } else {
                #expect(r.bandClockRaw == nil, "\(name)")
            }
            if d.keys.contains("write_page") {
                let dr = try #require(r.dataRange)
                #expect(Int(dr.writePage) == int(d["write_page"]) && Int(dr.trimPage) == int(d["trim_page"]))
                #expect(Int(dr.wrapCount) == int(d["wrap_count"]) && Int(dr.capacityPages) == int(d["capacity_pages"]))
                #expect(Int(dr.usedRecords) == int(d["used_records"]) && Int(dr.freeRecords) == int(d["free_records"]))
                #expect(dr.oldestRecord.map(Int.init) == int(d["oldest_record"]))
                #expect(dr.newestRecord.map(Int.init) == int(d["newest_record"]))
            } else {
                #expect(r.dataRange == nil, "\(name)")
            }
            #expect(r.asciiView == d["ascii_view"] as? String, "\(name)")
            #expect(r.versionText == d["version_text"] as? String, "\(name)")
        case .event(let e):
            #expect(kind == "event", "\(name)")
            #expect(e.eventID == int(want["event_id"]) && e.eventName == want["event_name"] as! String, "\(name)")
            #expect(Int(e.timestamp) == int(want["timestamp"]) && Int(e.subsec) == int(want["subsec"]))
            #expect(hex(e.body) == want["body_hex"] as! String)
            let d = want["decoded"] as! [String: Any]
            #expect(e.batteryPercent.map { abs($0 - num(d["battery_pct"])!) < 1e-9 } ?? (d["battery_pct"] == nil))
            #expect(e.batteryMillivolts.map(Int.init) == int(d["battery_mv"]))
            #expect(e.charging == d["charging"] as? Bool)
        case .metadata(let m):
            #expect(kind == "metadata", "\(name)")
            #expect(m.metaType == int(want["meta_type"]) && m.metaName == want["meta_name"] as! String, "\(name)")
            #expect(m.timestamp.map(Int.init) == int(want["timestamp"]), "\(name)")
            #expect(m.expectedPackets.map(Int.init) == int(want["expected_packets"]), "\(name)")
            #expect(m.token.map(hex) == want["token_hex"] as? String, "\(name)")
        case .history(let h):
            #expect(kind == "history_record", "\(name)")
            #expect(h.version == int(want["version"]) && Int(h.counter) == int(want["counter"]))
            #expect(Int(h.timestamp) == int(want["timestamp"]) && Int(h.subsec) == int(want["subsec"]))
            #expect(h.heartRate == int(want["hr"]) && h.length == int(want["length"]))
            #expect(h.rrMsUnverified == (want["rr_ms_unverified"] as! [NSNumber]).map(\.intValue))
            if let accel = want["accel_g"] as? [NSNumber] {
                let got = try #require(h.accelG, "\(name)")
                // Python rounds to 4 decimals for display; compare within that.
                #expect(zip(got, accel).allSatisfy { abs($0 - $1.doubleValue) < 1e-4 }, "\(name)")
            } else {
                #expect(h.accelG == nil, "\(name)")
            }
        case .unknown(let type, let typeName, let inner):
            #expect(kind == "unknown", "\(name): Swift decoded as unknown, Python as \(kind)")
            #expect(type == int(want["packet_type"]) && typeName == want["type_name"] as! String, "\(name)")
            #expect(hex(inner) == want["inner_hex"] as! String, "\(name)")
        }
    }
}

@Test func parityHeartRateMeasurement() throws {
    for c in cases("hrm") {
        let want = c["decoded"] as! [String: Any]
        let got = try #require(Whoop.parseHeartRateMeasurement(bytes(c["hex"] as! String)))
        #expect(got.heartRate == int(want["hr"]))
        #expect(got.contact == want["contact"] as? Bool)
        let rr = (want["rr_ms"] as! [NSNumber]).map(\.doubleValue)
        #expect(got.rrMs.count == rr.count)
        // Python rounds to 0.1 ms for display.
        #expect(zip(got.rrMs, rr).allSatisfy { abs($0 - $1) <= 0.05 + 1e-9 })
    }
}
