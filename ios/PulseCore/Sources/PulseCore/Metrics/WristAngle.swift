import Foundation

/// How far the wrist turned each second, from the direction of gravity. Spec: docs/METRICS.md §4.
///
/// The size of the band's gravity reading depends on how the wrist is lying, so a still wrist can look
/// like movement. Its direction doesn't have that problem. Sleep research uses the same idea: no change
/// in arm angle over several minutes means rest (van Hees et al. 2015).
public enum WristAngle {
    /// Stored for a second with nothing to compare with.
    public static let noReading: UInt8 = 255
    /// The largest stored value: 25.4 degrees in one second.
    static let largest = 254.0
    /// Seconds with a reading that a minute needs before its angle is trusted.
    public static let minimumSeconds = 30
    /// Movement units per stored step (a tenth of a degree), on the same scale as `MinuteBuilder.activity`.
    static let movementPerStep = MinuteBuilder.activityScale * (Double.pi / 180) / 10

    /// The angle between two gravity readings, in degrees. nil when one of them can't be used.
    public static func degrees(from a: [Double], to b: [Double]) -> Double? {
        guard a.count == 3, b.count == 3 else { return nil }
        let cross = [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]
        let sine = (cross[0] * cross[0] + cross[1] * cross[1] + cross[2] * cross[2]).squareRoot()
        let cosine = a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
        guard sine > 0 || cosine != 0 else { return nil }
        return atan2(sine, cosine) * 180 / .pi
    }

    /// The minutes with how far the wrist turned in each of their seconds added.
    public static func adding(to minutes: [MinuteSample], from records: [Whoop.HistoryRecord]) -> [MinuteSample] {
        var byMinute: [UInt32: [UInt8]] = [:]
        var last: (timestamp: UInt32, accel: [Double])?
        for record in records.sorted(by: { $0.timestamp < $1.timestamp }) {
            guard let accel = record.accelG else { continue }
            defer { last = (record.timestamp, accel) }
            guard let previous = last, record.timestamp > previous.timestamp, record.timestamp - previous.timestamp <= 2,
                  let turned = degrees(from: previous.accel, to: accel) else { continue }
            let minute = record.timestamp / 60
            var seconds = byMinute[minute] ?? [UInt8](repeating: noReading, count: 60)
            seconds[Int(record.timestamp % 60)] = UInt8(min(largest, (turned * 10).rounded()))
            byMinute[minute] = seconds
        }
        return minutes.map { minute in
            var out = minute
            out.wristAngle = byMinute[UInt32(minute.start.timeIntervalSince1970 / 60)]
            return out
        }
    }

    /// Two versions of the same minute: a second with a reading wins over one without.
    public static func merged(existing: [UInt8]?, incoming: [UInt8]?) -> [UInt8]? {
        guard let incoming, incoming.count == 60 else { return existing }
        guard var out = existing, out.count == 60 else { return incoming }
        for second in 0..<60 where incoming[second] != noReading { out[second] = incoming[second] }
        return out
    }

    /// Average movement of a minute, or nil when too few of its seconds have a reading.
    static func movement(_ seconds: [UInt8]?) -> Double? {
        guard let seconds, seconds.count == 60 else { return nil }
        var count = 0, total = 0
        for value in seconds where value != noReading {
            count += 1
            total += Int(value)
        }
        guard count >= minimumSeconds else { return nil }
        return Double(total) / Double(count) * movementPerStep
    }
}
