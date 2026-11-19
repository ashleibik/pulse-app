import Foundation
import Testing
@testable import PulseCore

// The band's wear-sensor status lines, as the owner saw them in the sync log.

private let tightLine = "TIGHTNESS V1: Long Prediction Available, loose count = 5, loose flag = 1"
private let chipLine = "IQS7223B: Error reported, error code 0x05"
private let driverLine = "CAPSENSE: Error reported while processing command"
private let start = Date(timeIntervalSince1970: 1_790_000_000)

private let bandTime: UInt32 = 1_795_052_465

/// The band's own layout: 50 characters of text per packet, cut wherever the text happens to end.
private func packets(_ text: String, firstSequence: UInt8 = 100) -> [[UInt8]] {
    var bytes = Array(text.utf8)
    while bytes.count % 50 != 0 { bytes.append(0x20) }
    return stride(from: 0, to: bytes.count, by: 50).enumerated().map { index, offset in
        var frame: [UInt8] = [0xAA, 0x44, 0x00, 0x0F, 0x32, firstSequence &+ UInt8(index), 0x02, 0x00]
        frame += withUnsafeBytes(of: bandTime.littleEndian) { Array($0) }
        frame += [0x78, 0x76, 0x34, 0x00, 0x01] + bytes[offset..<(offset + 50)] + [0x00, 0x45, 0xD3, 0x28, 0x66]
        return frame
    }
}

private func scanned(_ text: String) -> [WearSensor.Event] {
    var scanner = WearSensor.Scanner()
    return packets(text).flatMap { scanner.scan($0) }.map(\.event)
}

private func minutes(_ value: Double) -> Date { start.addingTimeInterval(value * 60) }

@Test func theThreeStatusLinesAreRead() {
    #expect(scanned("  8, 103778224: \(tightLine)\n") == [.tightness(looseCount: 5, isLoose: true)])
    #expect(scanned("  8, 103778224: \(chipLine)\n") == [.sensorError(code: 5)])
    #expect(scanned("  8, 103778224: \(driverLine)\n") == [.commandError])
}

@Test func aLineCutAcrossPacketsMidWordIsJoinedAgain() {
    let text = "  8, 103656184: BLE: Enabled Entry.\n  8, 103778224: \(tightLine)\n"
    #expect(packets(text).count >= 2)
    #expect(scanned(text) == [.tightness(looseCount: 5, isLoose: true)])
}

@Test func readingsCarryTheBandsOwnTime() {
    var scanner = WearSensor.Scanner()
    let reading = packets("\(tightLine)\n").flatMap { scanner.scan($0) }.first
    #expect(reading?.time == Date(timeIntervalSince1970: Double(bandTime)))
}

@Test func aTightStrapIsReadAsNotLoose() {
    let line = "TIGHTNESS V1: Long Prediction Available, loose count = 0, loose flag = 0"
    #expect(WearSensor.events(in: line) == [.tightness(looseCount: 0, isLoose: false)])
}

@Test func severalPacketsInOneNotificationAreAllRead() {
    var scanner = WearSensor.Scanner()
    let joined = packets("\(chipLine)\n\(driverLine)\n\(tightLine)\n").flatMap { $0 }
    #expect(scanner.scan(joined).map(\.event) == [.sensorError(code: 5), .commandError, .tightness(looseCount: 5, isLoose: true)])
}

@Test func aLostPacketDropsTheBrokenLineButNotTheNextOne() {
    var scanner = WearSensor.Scanner()
    let all = packets("\(tightLine)\n  8, 103779178: \(chipLine)\n  8, 103779180: \(driverLine)\n")
    #expect(all.count >= 4)
    let kept = all.enumerated().filter { $0.offset != 1 }.map(\.element)
    let events = kept.flatMap { scanner.scan($0) }.map(\.event)
    #expect(!events.contains(.tightness(looseCount: 5, isLoose: true)))
    #expect(events.contains(.commandError))
}

@Test func aRepeatedPacketIsNotReadTwice() {
    var scanner = WearSensor.Scanner()
    let all = packets("\(chipLine)\n")
    #expect((all + all).flatMap { scanner.scan($0) }.count == 1)
}

@Test func otherBandMessagesAreIgnored() {
    #expect(scanned("  8, 1: CAPSENSE: IQS7223B detected wrist state change - ON-WRIST\n").isEmpty)
    #expect(scanned("  8, 1: CAPSENSE: Capsense triggered an off wrist event, but Sigproc controls wear detection\n").isEmpty)
    #expect(scanned("  8, 1: CAPSENSE: ATI Event Reported\n").isEmpty)
    #expect(scanned("  8, 1: TIGHTNESS V1: Detector init/reset\n").isEmpty)
}

@Test func historyDataIsSkipped() {
    var scanner = WearSensor.Scanner()
    var history = [UInt8](repeating: 0x54, count: 92)
    history[0] = 0xAA; history[1] = 88; history[2] = 0; history[4] = 0x2F
    #expect(scanner.scan(history).isEmpty)
    #expect(scanner.scan((0..<2_000).map { UInt8(truncatingIfNeeded: $0 &* 37) }).isEmpty)
}

@Test func theSettingsRowSaysWhatTheBandReported() {
    #expect(WearSensor.status([], now: start).label == "--")
    let reading = WearSensor.Observation(time: start, isLoose: false)
    let error = WearSensor.Observation(.sensorError(code: 5), at: start)
    #expect(WearSensor.status([reading], now: minutes(1)).label == "No errors")
    #expect(WearSensor.status([reading, error], now: minutes(1)).label == "Error")
    #expect(WearSensor.status([reading, error], now: minutes(1)).errorCode == 5)
}

@Test func theBandsLooseFlagIsNeverShownAsLoose() {
    // The band reported this while the owner's strap was tight.
    let flagged = WearSensor.Observation(.tightness(looseCount: 5, isLoose: true), at: start)
    #expect(WearSensor.status([flagged], now: minutes(1)).label == "No errors")
}

@Test func oldReadingsExpire() {
    let list = [WearSensor.Observation(time: start, isLoose: false)]
    #expect(WearSensor.status(list, now: minutes(6)).label == "No errors")
    #expect(WearSensor.status(list, now: minutes(40)).label == "--")
}

@Test func repeatedReadingsAreNotAllStored() {
    var list: [WearSensor.Observation] = []
    for minute in 0..<4 { list = WearSensor.adding(.init(time: minutes(Double(minute)), isLoose: true), to: list) }
    #expect(list.count == 1)
    list = WearSensor.adding(.init(time: minutes(4), isLoose: false), to: list)      // a change is always kept
    list = WearSensor.adding(.init(time: minutes(10), isLoose: false), to: list)     // and a repeat after a while
    #expect(list.count == 3)
    list = WearSensor.adding(.init(time: minutes(60 * 24 * 40), isLoose: true), to: list)
    #expect(list.count == 1)                                                          // old readings are dropped
}

@Test func olderLinesFromAReconnectStayInTimeOrder() {
    var list = WearSensor.adding(.init(time: minutes(20), isLoose: false), to: [])
    list = WearSensor.adding(.init(time: minutes(5), isLoose: true), to: list)
    #expect(list.map(\.time) == [minutes(5), minutes(20)])
    #expect(WearSensor.status(list, now: minutes(21)).lastReading?.time == minutes(20))
}

@Test func theLastReadingIsKeptAfterItExpires() {
    let list = [WearSensor.Observation(time: start, isLoose: true)]
    let later = WearSensor.status(list, now: minutes(120))
    #expect(later.label == "--" && later.lastReading?.isLoose == true)
}
