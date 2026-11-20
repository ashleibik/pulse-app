import Foundation

/// Steps counted on the band's 100 Hz motion stream while a step test runs (docs/METRICS.md §15).
///
/// The stream only exists while the app asks for it (SEND_R10_R11_REALTIME), so this is for walks Pulse supervises,
/// not all day. Each second's packet is kept by the band's own timestamp; an unbroken run of seconds is counted
/// with OpenStrap's pedometer in one go, and a missing second splits the run.
public struct LiveSteps: Sendable, Equatable {
    public private(set) var seconds: [UInt32: Whoop.RawMotion] = [:]

    public init() {}

    /// A second sent twice keeps the later copy.
    public mutating func add(_ motion: Whoop.RawMotion) { seconds[motion.timestamp] = motion }

    public var isEmpty: Bool { seconds.isEmpty }

    private func keys(from start: Date, to end: Date) -> [UInt32] {
        let lo = UInt32(max(0, start.timeIntervalSince1970.rounded(.down)))
        let hi = UInt32(max(0, end.timeIntervalSince1970.rounded(.up)))
        return seconds.keys.filter { $0 >= lo && $0 < hi }.sorted()
    }

    /// Unbroken runs of seconds between two times.
    func runs(from start: Date, to end: Date) -> [[Whoop.RawMotion]] {
        var out: [[Whoop.RawMotion]] = []
        var previous: UInt32?
        for key in keys(from: start, to: end) {
            guard let motion = seconds[key] else { continue }
            if let previous, key == previous + 1 { out[out.count - 1].append(motion) } else { out.append([motion]) }
            previous = key
        }
        return out
    }

    /// The size of each reading in g, gravity included.
    static func magnitudes(_ run: [Whoop.RawMotion]) -> [Double] {
        var out: [Double] = []
        out.reserveCapacity(run.count * Whoop.RawMotion.samplesPerAxis)
        for motion in run {
            guard motion.accel.count == 3 else { continue }
            let n = min(motion.accel[0].count, motion.accel[1].count, motion.accel[2].count)
            for i in 0..<n {
                let x = Double(motion.accel[0][i]) / Whoop.RawMotion.countsPerG
                let y = Double(motion.accel[1][i]) / Whoop.RawMotion.countsPerG
                let z = Double(motion.accel[2][i]) / Whoop.RawMotion.countsPerG
                out.append((x * x + y * y + z * z).squareRoot())
            }
        }
        return out
    }

    /// OpenStrap's pedometer over each unbroken run between two times.
    public func steps(from start: Date, to end: Date) -> Int {
        runs(from: start, to: end).reduce(0) { $0 + OpenStrapPedometer.pedometer(Self.magnitudes($1)) }
    }

    /// Share of the seconds between two times the stream delivered.
    public func coverage(from start: Date, to end: Date) -> Double {
        let length = end.timeIntervalSince(start)
        guard length > 0 else { return 0 }
        return min(1, Double(keys(from: start, to: end).count) / length.rounded(.up))
    }

    /// The median size of the readings, in g. About 1 when the band's scale is the one NOOP and OpenStrap use.
    public var medianG: Double? {
        let all = Self.magnitudes(seconds.keys.sorted().compactMap { seconds[$0] })
        guard !all.isEmpty else { return nil }
        return Stats.median(all)
    }
}
