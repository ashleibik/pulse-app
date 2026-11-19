import Foundation
import Testing
@testable import PulseCore

// The band's wear-sensor status lines, as the owner saw them in the sync log.

private let tightLine = "TIGHTNESS V1: Long Prediction Available, loose count = 5, loose flag = 1"
private let chipLine = "IQS7223B: Error reported, error code 0x05"
private let driverLine = "CAPSENSE: Error reported while processing command"
private let start = Date(timeIntervalSince1970: 1_790_000_000)

private func frame(_ text: String) -> [UInt8] { [0xAA, 0x10, 0x00, 0x32, 0x01] + Array(text.utf8) + [0x00, 0xFE, 0x81, 0x03] }
private func minutes(_ value: Double) -> Date { start.addingTimeInterval(value * 60) }

@Test func theThreeStatusLinesAreRead() {
    var scanner = WearSensor.Scanner()
    #expect(scanner.scan(frame(tightLine)) == [.tightness(looseCount: 5, isLoose: true)])
    #expect(scanner.scan(frame(chipLine)) == [.sensorError(code: 5)])
    #expect(scanner.scan(frame(driverLine)) == [.commandError])
}

@Test func aTightStrapIsReadAsNotLoose() {
    let line = "TIGHTNESS V1: Long Prediction Available, loose count = 0, loose flag = 0"
    #expect(WearSensor.events(in: line) == [.tightness(looseCount: 0, isLoose: false)])
}

@Test func severalLinesInOneNotificationAreAllRead() {
    var scanner = WearSensor.Scanner()
    #expect(scanner.scan(frame(chipLine) + frame(driverLine) + frame(tightLine))
        == [.sensorError(code: 5), .commandError, .tightness(looseCount: 5, isLoose: true)])
}

@Test func aLineSplitAcrossTwoNotificationsIsStillRead() {
    var scanner = WearSensor.Scanner()
    let bytes = frame(tightLine)
    #expect(scanner.scan(Array(bytes[..<40])).isEmpty)
    #expect(scanner.scan(Array(bytes[40...])) == [.tightness(looseCount: 5, isLoose: true)])
}

@Test func otherBandDataIsIgnored() {
    var scanner = WearSensor.Scanner()
    #expect(scanner.scan((0..<2_000).map { UInt8(truncatingIfNeeded: $0 &* 37) }).isEmpty)
    #expect(scanner.scan(frame("BATTERY: charging normally, nothing to report")).isEmpty)
    #expect(scanner.scan(frame("TIGHTNESS V1: Short Prediction Pending")).isEmpty)
    #expect(scanner.scan(frame("CAPSENSE: Calibration finished")).isEmpty)
}

@Test func theSettingsRowSaysWhatTheBandReported() {
    #expect(WearSensor.status([], now: start).label == "--")
    let tight = WearSensor.Observation(time: start, isLoose: false)
    let loose = WearSensor.Observation(time: start, isLoose: true)
    let error = WearSensor.Observation(.sensorError(code: 5), at: start)
    #expect(WearSensor.status([tight], now: minutes(1)).label == "OK")
    #expect(WearSensor.status([loose], now: minutes(1)).label == "Loose")
    #expect(WearSensor.status([tight, error], now: minutes(1)).label == "Error")
    #expect(WearSensor.status([loose, error], now: minutes(1)).label == "Loose / error")
    #expect(WearSensor.status([loose, error], now: minutes(1)).errorCode == 5)
}

@Test func theNewestTightnessReadingWinsAndOldReadingsExpire() {
    let list = [WearSensor.Observation(time: start, isLoose: true), WearSensor.Observation(time: minutes(5), isLoose: false)]
    #expect(WearSensor.status(list, now: minutes(6)).isLoose == false)
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

@Test func aWorkoutSpentLooseHasReducedQuality() {
    let loose = (0..<9).map { WearSensor.Observation(time: minutes(Double($0) * 5), isLoose: true) }
    #expect(WearSensor.quality(from: minutes(0), to: minutes(45), observations: loose) == .reduced)
}

@Test func aWorkoutWithATightStrapIsGood() {
    let tight = (0..<9).map { WearSensor.Observation(time: minutes(Double($0) * 5), isLoose: false) }
    #expect(WearSensor.quality(from: minutes(0), to: minutes(45), observations: tight) == .good)
}

@Test func aBriefMomentOfLoosenessDoesNotLowerAWorkout() {
    var list = (0..<9).map { WearSensor.Observation(time: minutes(Double($0) * 5), isLoose: false) }
    list[4].isLoose = true                                                            // 5 of 45 minutes
    #expect(WearSensor.quality(from: minutes(0), to: minutes(45), observations: list) == .good)
}

@Test func noReadingsMeansTheQualityIsUnknown() {
    #expect(WearSensor.quality(from: minutes(0), to: minutes(45), observations: []) == .unknown)
    let late = [WearSensor.Observation(time: minutes(44), isLoose: true)]
    #expect(WearSensor.quality(from: minutes(0), to: minutes(45), observations: late) == .unknown)
    let errorsOnly = [WearSensor.Observation(.commandError, at: minutes(1))]
    #expect(WearSensor.quality(from: minutes(0), to: minutes(45), observations: errorsOnly) == .unknown)
}
