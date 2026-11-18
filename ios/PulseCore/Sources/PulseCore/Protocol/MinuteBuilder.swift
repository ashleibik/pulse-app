import Foundation

/// Turns the band's ~1 Hz history records into MinuteSamples, the format the metrics engine reads.
///
/// ⚠ PROVISIONAL (re-calibrate in Phase 5b with real nights):
///   activity = the larger of |accel magnitude - 1 g| and how far the accel vector's direction
///   turned since the previous second, x 500, clamped to 0...255.
///   Why both: turning the wrist (typing, using a mouse) keeps the magnitude at 1 g, so magnitude
///   alone reads as perfectly still. The change of direction shows that movement.
///   The engine's activity scale (docs/METRICS.md §4) is ~1-2 asleep, ~12 sitting, ~75 walking.
///   Typical wrist "dynamic" acceleration is ~0.003 g still, ~0.02 g sitting, ~0.15 g walking,
///   so x500 lands in the same ranges. Real WHOOP accel units and filtering are not yet verified.
public enum MinuteBuilder {
    public static let activityScale = 500.0

    /// - Parameter previous: the reading one second earlier, when there is one.
    public static func activity(accelG: [Double]?, previous: [Double]? = nil) -> UInt8 {
        guard let a = accelG, a.count == 3 else { return 0 }
        let magnitude = (a[0] * a[0] + a[1] * a[1] + a[2] * a[2]).squareRoot()
        var motion = abs(magnitude - 1)
        if let p = previous, p.count == 3 {
            let size = (p[0] * p[0] + p[1] * p[1] + p[2] * p[2]).squareRoot()
            if magnitude > 0, size > 0 {
                let dx = a[0] / magnitude - p[0] / size
                let dy = a[1] / magnitude - p[1] / size
                let dz = a[2] / magnitude - p[2] / size
                motion = max(motion, (dx * dx + dy * dy + dz * dz).squareRoot())
            }
        }
        return UInt8(min(255, max(0, (motion * activityScale).rounded())))
    }

    /// Group records by minute. Seconds with no record stay 0 (= no reading). If a second appears
    /// twice (a resent batch), the later record wins for HR and activity. RR values would be added
    /// twice in that case. That's acceptable while RR-in-history is unverified, but revisit in 5b.
    public static func minutes(from records: [Whoop.HistoryRecord], source: DataSource = .history) -> [MinuteSample] {
        var byMinute: [UInt32: (hr: [UInt8], activity: [UInt8], rr: [UInt16])] = [:]
        var last: (timestamp: UInt32, accel: [Double])?
        for r in records where Whoop.plausibleUnix(r.timestamp) {
            let minute = r.timestamp / 60
            let second = Int(r.timestamp % 60)
            var entry = byMinute[minute] ?? ([UInt8](repeating: 0, count: 60), [UInt8](repeating: 0, count: 60), [])
            entry.hr[second] = UInt8(clamping: r.heartRate)
            // Only a reading from just before says how far the wrist moved.
            let previous = last.flatMap { r.timestamp > $0.timestamp && r.timestamp - $0.timestamp <= 2 ? $0.accel : nil }
            entry.activity[second] = activity(accelG: r.accelG, previous: previous)
            last = r.accelG.map { (r.timestamp, $0) }
            entry.rr += r.rrMsUnverified.map { UInt16(clamping: $0) }
            byMinute[minute] = entry
        }
        return byMinute.keys.sorted().map { minute in
            let e = byMinute[minute]!
            return MinuteSample(start: Date(timeIntervalSince1970: Double(minute) * 60), heartRate: e.hr,
                                rrIntervalsMs: e.rr, activity: e.activity, source: source)
        }
    }
}
