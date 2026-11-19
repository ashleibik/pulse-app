import Foundation

/// What the band says about how it sits on the wrist. Spec: docs/METRICS.md §13.
///
/// The band writes readable status lines (CONSOLE_LOGS) next to its data, for example:
///
///     TIGHTNESS V1: Long Prediction Available, loose count = 5, loose flag = 1
///     IQS7223B: Error reported, error code 0x05
///     CAPSENSE: Error reported while processing command
///
/// WHOOP doesn't document these lines, so their meaning is read from their wording.
public enum WearSensor {
    public static let looseHint = "Strap seems loose, tighten for accurate heart rate"
    public static let lessCertainNote = "The strap seemed loose for much of this time, so heart rate is less certain."

    public enum Event: Sendable, Equatable {
        case tightness(looseCount: Int, isLoose: Bool)
        /// The capacitive sensor chip reported an error.
        case sensorError(code: Int?)
        /// The band's capacitive sensor driver reported an error.
        case commandError
    }

    /// A status line, and when the band wrote it.
    public struct Reading: Sendable, Equatable {
        public var event: Event
        /// The band's clock. nil when its clock isn't set.
        public var time: Date?
    }

    /// Finds the status lines in the band's raw Bluetooth notifications, without touching the sync.
    ///
    /// The band cuts its text into packets of 50 characters, often in the middle of a word, so the
    /// packets are joined again in order. Layout of a CONSOLE_LOGS frame, seen on the owner's band:
    ///
    ///     AA, length (2), header check, 0x32, sequence, 2, 0, unix time (4), 2 bytes, text size (2), 1,
    ///     text, 0, checksum (4)
    public struct Scanner: Sendable {
        private var line: [UInt8] = []
        private var lastSequence: UInt8?
        private static let consoleType: UInt8 = 0x32
        private static let textOffset = 17
        private static let longestLine = 400

        public init() {}

        public mutating func scan(_ bytes: [UInt8]) -> [Reading] {
            var readings: [Reading] = []
            var offset = 0
            while offset + 5 <= bytes.count, bytes[offset] == 0xAA {
                let total = Int(bytes[offset + 1]) | Int(bytes[offset + 2]) << 8 + 4
                guard total > 4, offset + total <= bytes.count else { break }
                if bytes[offset + 4] == Self.consoleType, total > Self.textOffset + 5 {
                    readings += read(Array(bytes[offset..<(offset + total)]))
                }
                offset += total
            }
            return readings
        }

        private mutating func read(_ frame: [UInt8]) -> [Reading] {
            let sequence = frame[5]
            if sequence == lastSequence { return [] }                       // the same packet again
            if let last = lastSequence, sequence != last &+ 1 { line = [] } // a packet was lost: this line is broken
            lastSequence = sequence

            let size = Int(frame[14]) | Int(frame[15]) << 8
            let end = min(Self.textOffset + max(0, size - 2), frame.count - 5)
            guard end > Self.textOffset else { return [] }
            let stamp = UInt32(frame[8]) | UInt32(frame[9]) << 8 | UInt32(frame[10]) << 16 | UInt32(frame[11]) << 24
            let time = Whoop.plausibleUnix(stamp) ? Date(timeIntervalSince1970: Double(stamp)) : nil

            var readings: [Reading] = []
            for byte in frame[Self.textOffset..<end] {
                if byte == 0x0A {
                    readings += WearSensor.events(in: String(decoding: line, as: UTF8.self)).map { Reading(event: $0, time: time) }
                    line = []
                } else if line.count < Self.longestLine {
                    line.append(byte)
                }
            }
            return readings
        }
    }

    /// The status lines in a piece of text, in order.
    public static func events(in text: String) -> [Event] {
        var out: [Event] = []
        var rest = Substring(text)
        let markers = ["TIGHTNESS", "IQS7223B", "CAPSENSE"]
        while let next = markers.compactMap({ rest.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) {
            let afterMarker = rest[next.upperBound...]
            let following = markers.compactMap { afterMarker.range(of: $0)?.lowerBound }.min() ?? rest.endIndex
            let line = rest[next.lowerBound..<following]
            if line.hasPrefix("TIGHTNESS") {
                if let flag = number(after: "loose flag", in: line) {
                    out.append(.tightness(looseCount: number(after: "loose count", in: line) ?? 0, isLoose: flag != 0))
                }
            } else if line.contains("Error reported") {
                out.append(line.hasPrefix("IQS7223B") ? .sensorError(code: hexCode(in: line)) : .commandError)
            }
            rest = rest[following...]
        }
        return out
    }

    private static func number(after label: String, in line: Substring) -> Int? {
        guard let found = line.range(of: label) else { return nil }
        let value = line[found.upperBound...].drop { $0 == " " || $0 == "=" }.prefix { $0.isASCII && $0.isNumber }
        return Int(value)
    }

    private static func hexCode(in line: Substring) -> Int? {
        guard let found = line.range(of: "0x") else { return nil }
        return Int(line[found.upperBound...].prefix { $0.isHexDigit }, radix: 16)
    }

    // MARK: - What was seen

    public struct Observation: Codable, Sendable, Equatable {
        public var time: Date
        /// nil = this line wasn't about tightness.
        public var isLoose: Bool?
        public var hasError: Bool
        public var errorCode: Int?

        public init(time: Date, isLoose: Bool? = nil, hasError: Bool = false, errorCode: Int? = nil) {
            self.time = time
            self.isLoose = isLoose
            self.hasError = hasError
            self.errorCode = errorCode
        }

        public init(_ event: Event, at time: Date) {
            switch event {
            case .tightness(_, let isLoose): self.init(time: time, isLoose: isLoose)
            case .sensorError(let code): self.init(time: time, hasError: true, errorCode: code)
            case .commandError: self.init(time: time, hasError: true)
            }
        }
    }

    /// A reading counts for this long after the band reported it.
    public static let freshSeconds = 30.0 * 60
    static let keepSeconds = 30.0 * 86_400
    static let repeatSeconds = 5.0 * 60
    static let mostKept = 5_000

    /// Adds an observation, skipping repeats so the file stays small.
    public static func adding(_ new: Observation, to list: [Observation]) -> [Observation] {
        // The band can send older lines after a reconnect, so readings are kept in time order.
        let sameKind = list.last { ($0.isLoose != nil) == (new.isLoose != nil) && $0.time <= new.time }
        if let sameKind, sameKind.isLoose == new.isLoose, sameKind.errorCode == new.errorCode,
           new.time.timeIntervalSince(sameKind.time) < repeatSeconds { return list }
        let all = (list + [new]).sorted { $0.time < $1.time }
        let oldest = all[all.count - 1].time.addingTimeInterval(-keepSeconds)
        return Array(all.filter { $0.time >= oldest }.suffix(mostKept))
    }

    public struct Status: Sendable, Equatable {
        /// nil = the band hasn't reported lately.
        public var isLoose: Bool?
        public var hasError: Bool
        public var errorCode: Int?
        /// The newest tightness reading, however old. For showing what the band last said.
        public var lastReading: Observation?

        /// "OK", "Loose", "Error", "Loose / error", or "--".
        public var label: String {
            switch (isLoose, hasError) {
            case (true, true): "Loose / error"
            case (true, false): "Loose"
            case (_, true): "Error"
            case (false, false): "OK"
            case (nil, false): "--"
            default: "--"
            }
        }
    }

    public static func status(_ list: [Observation], now: Date) -> Status {
        // A minute of slack: the band's clock can run slightly ahead of the phone's.
        let fresh = list.filter { now.timeIntervalSince($0.time) <= freshSeconds && $0.time <= now.addingTimeInterval(60) }
        let error = fresh.last { $0.hasError }
        return Status(isLoose: fresh.last { $0.isLoose != nil }?.isLoose, hasError: error != nil, errorCode: error?.errorCode,
                      lastReading: list.last { $0.isLoose != nil })
    }

    // MARK: - Data quality

    public enum Quality: Sendable, Equatable { case good, reduced, unknown }

    /// The strap counts as loose for a stretch when at least this share of the measured time was loose.
    public static let reducedShare = 0.25
    /// Below this share of readings over a stretch, Pulse can't say how the strap sat.
    static let knownShare = 0.25

    /// How much to trust the heart rate of a workout or a night.
    public static func quality(from start: Date, to end: Date, observations: [Observation]) -> Quality {
        guard end > start else { return .unknown }
        let readings = observations.filter { $0.isLoose != nil }.sorted { $0.time < $1.time }
        var known = 0.0, loose = 0.0
        for (index, reading) in readings.enumerated() {
            let until = index + 1 < readings.count ? readings[index + 1].time : .distantFuture
            let from = max(reading.time, start)
            let to = min(until, reading.time.addingTimeInterval(freshSeconds), end)
            guard to > from else { continue }
            known += to.timeIntervalSince(from)
            if reading.isLoose == true { loose += to.timeIntervalSince(from) }
        }
        guard known >= knownShare * end.timeIntervalSince(start) else { return .unknown }
        return loose / known >= reducedShare ? .reduced : .good
    }
}
