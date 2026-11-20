import Foundation

/// What `SleepModel` remembers between runs, so that only the weeks whose data changed are calculated again.
///
/// A week's result depends only on its own minutes, the edits that touch it, and what the model had learned
/// by the end of the week before. All of that goes into the week's key, so a reused week is exactly what a
/// full calculation would give. The cache can be thrown away at any time: the next run simply takes longer.
public struct SleepModelCache: Sendable, Equatable {
    /// One finished calculation of a week.
    struct Week: Sendable, Equatable {
        var key: UInt64
        var asleep: [Bool]
        /// Minutes the model was sure about: P(asleep) of at least 0.8 or at most 0.2.
        var sure: [Bool]
        var learned: SleepModel.Learned
    }

    /// Per-minute beat results of the latest week, the only week new minutes keep arriving in.
    struct Recent: Sendable, Equatable {
        var start: Date
        var fingerprints: [UInt64]
        var beats: SleepModel.MinuteBeats
    }

    var weeks: [Int64: Week] = [:]
    var recent: Recent?
    /// Weeks taken from the cache and weeks calculated in the last run.
    public internal(set) var reusedWeeks = 0
    public internal(set) var calculatedWeeks = 0

    public init() {}

    // MARK: - File format

    private static let magic: UInt32 = 0x324D_5350       // "PSM2"

    /// The cache as bytes for a file.
    public func encoded() -> Data {
        var w = Writer()
        w.u32(Self.magic)
        w.u32(UInt32(MetricsEngine.algorithmVersion))
        w.u32(UInt32(weeks.count))
        for (start, week) in weeks.sorted(by: { $0.key < $1.key }) {
            w.u64(UInt64(bitPattern: start))
            w.u64(week.key)
            w.bits(week.asleep)
            w.bits(week.sure)
            w.learned(week.learned)
        }
        w.u32(recent == nil ? 0 : 1)
        if let recent {
            w.double(recent.start.timeIntervalSince1970)
            w.u32(UInt32(recent.fingerprints.count))
            for value in recent.fingerprints { w.u64(value) }
            for value in recent.beats.beats { w.u16(value) }
            for value in recent.beats.pairs { w.u16(value) }
            for value in recent.beats.squares { w.double(value) }
        }
        return Data(w.bytes)
    }

    /// nil when the bytes are damaged or were written by another version of the formulas.
    public init?(data: Data) {
        var r = Reader(bytes: [UInt8](data))
        guard let parsed = try? Self.parse(&r), r.isAtEnd else { return nil }
        self = parsed
    }

    private static func parse(_ r: inout Reader) throws -> SleepModelCache {
        guard try r.u32() == magic, try r.u32() == UInt32(MetricsEngine.algorithmVersion) else { throw Reader.Failure.damaged }
        var cache = SleepModelCache()
        for _ in 0..<(try r.u32()) {
            let start = Int64(bitPattern: try r.u64())
            let key = try r.u64()
            let asleep = try r.bits()
            let sure = try r.bits()
            guard sure.count == asleep.count else { throw Reader.Failure.damaged }
            cache.weeks[start] = Week(key: key, asleep: asleep, sure: sure, learned: try r.learned())
        }
        if try r.u32() == 1 {
            let start = Date(timeIntervalSince1970: try r.double())
            let count = Int(try r.u32())
            try r.require(count * 20)
            let fingerprints = try (0..<count).map { _ in try r.u64() }
            let beats = try (0..<count).map { _ in try r.u16() }
            let pairs = try (0..<count).map { _ in try r.u16() }
            let squares = try (0..<count).map { _ in try r.double() }
            cache.recent = Recent(start: start, fingerprints: fingerprints,
                                  beats: SleepModel.MinuteBeats(beats: beats, pairs: pairs, squares: squares))
        }
        return cache
    }

    private struct Writer {
        var bytes: [UInt8] = []

        mutating func u16(_ v: UInt16) { for shift in stride(from: 0, to: 16, by: 8) { bytes.append(UInt8(truncatingIfNeeded: v >> shift)) } }
        mutating func u32(_ v: UInt32) { for shift in stride(from: 0, to: 32, by: 8) { bytes.append(UInt8(truncatingIfNeeded: v >> shift)) } }
        mutating func u64(_ v: UInt64) { for shift in stride(from: 0, to: 64, by: 8) { bytes.append(UInt8(truncatingIfNeeded: v >> shift)) } }
        mutating func double(_ v: Double) { u64(v.bitPattern) }

        mutating func bits(_ flags: [Bool]) {
            u32(UInt32(flags.count))
            var packed = [UInt8](repeating: 0, count: (flags.count + 7) / 8)
            for (i, flag) in flags.enumerated() where flag { packed[i / 8] |= 1 << UInt8(i % 8) }
            bytes.append(contentsOf: packed)
        }

        mutating func signal(_ s: SleepModel.Signal) {
            for v in [s.asleep.mean, s.asleep.sd, s.awake.mean, s.awake.sd] { double(v) }
        }

        mutating func optionalSignal(_ s: SleepModel.Signal?) {
            u32(s == nil ? 0 : 1)
            if let s { signal(s) }
        }

        mutating func learned(_ l: SleepModel.Learned) {
            signal(l.heartRate)
            signal(l.movement)
            signal(l.unsteadiness)
            optionalSignal(l.cleanBeats)
            optionalSignal(l.hrv)
            for count in l.asleepCounts { u16(UInt16(clamping: Int(count))) }
            double(l.nights)
            u32(l.awakeRate == nil ? 0 : 1)
            if let rate = l.awakeRate { double(rate) }
        }
    }

    private struct Reader {
        enum Failure: Error { case damaged }
        let bytes: [UInt8]
        var position = 0

        var isAtEnd: Bool { position == bytes.count }

        func require(_ count: Int) throws {
            guard count >= 0, position + count <= bytes.count else { throw Failure.damaged }
        }

        private mutating func unsigned(_ size: Int) throws -> UInt64 {
            try require(size)
            var value: UInt64 = 0
            for i in 0..<size { value |= UInt64(bytes[position + i]) << UInt64(8 * i) }
            position += size
            return value
        }

        mutating func u16() throws -> UInt16 { UInt16(try unsigned(2)) }
        mutating func u32() throws -> UInt32 { UInt32(try unsigned(4)) }
        mutating func u64() throws -> UInt64 { try unsigned(8) }
        mutating func double() throws -> Double { Double(bitPattern: try unsigned(8)) }

        mutating func bits() throws -> [Bool] {
            let count = Int(try u32())
            let size = (count + 7) / 8
            try require(size)
            let flags = (0..<count).map { bytes[position + $0 / 8] & (1 << UInt8($0 % 8)) != 0 }
            position += size
            return flags
        }

        mutating func signal() throws -> SleepModel.Signal {
            let values = [try double(), try double(), try double(), try double()]
            guard values[1] > 0, values[3] > 0 else { throw Failure.damaged }
            return SleepModel.Signal(asleep: SleepModel.Curve(mean: values[0], sd: values[1]),
                                     awake: SleepModel.Curve(mean: values[2], sd: values[3]))
        }

        mutating func learned() throws -> SleepModel.Learned {
            var l = SleepModel.Learned()
            l.heartRate = try signal()
            l.movement = try signal()
            l.unsteadiness = try signal()
            l.cleanBeats = try u32() == 1 ? try signal() : nil
            l.hrv = try u32() == 1 ? try signal() : nil
            l.asleepCounts = try (0..<1440).map { _ in Double(try u16()) }
            l.nights = try double()
            l.awakeRate = try u32() == 1 ? try double() : nil
            return l
        }
    }
}
