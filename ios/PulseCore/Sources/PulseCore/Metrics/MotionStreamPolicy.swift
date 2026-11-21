import Foundation

/// When the band streams its 100 Hz motion so Pulse can count steps (docs/METRICS.md §15). Pulse asks after every pull and when
/// the app opens. A step test keeps the stream on whatever this says.
///
/// It streams whenever the band is worn and the owner is awake, so a walk is counted from its first step. Until 2026-11-21 it
/// also paused after 30 still minutes, and only the next pull, minutes later (up to a quarter of an hour with the app closed),
/// could start it again: the first minutes of every walk after sitting were never counted.
public enum MotionStreamPolicy {
    /// Below this band battery (and not charging) the stream stops ...
    public static let lowBatteryPercent = 15.0
    /// ... and it starts again from this.
    public static let resumeBatteryPercent = 20.0
    /// No heart rate in this many of the newest minutes: the band isn't worn.
    public static let notWornMinutes = 10

    public enum Decision: String, Equatable, Sendable {
        case stream, lowBattery, notWorn, asleep

        public var isOn: Bool { self == .stream }
    }

    /// - Parameters:
    ///   - minutes: the newest band minutes, any order (the last 10 minutes or more).
    ///   - streaming: whether the stream is on now, so the battery limits don't flicker.
    ///   - asleep: a sleep is going on (found, with no band minutes after it yet: docs/METRICS.md §4).
    public static func decide(recent minutes: [MinuteSample], batteryPercent: Double?, charging: Bool?,
                              streaming: Bool, asleep: Bool) -> Decision {
        if charging != true, let batteryPercent,
           batteryPercent < (streaming ? lowBatteryPercent : resumeBatteryPercent) {
            return .lowBattery
        }
        let sorted = minutes.filter { $0.source != .simulated }.sorted { $0.start < $1.start }
        if let newest = sorted.last?.start {
            let wornWindow = sorted.filter { $0.start > newest.addingTimeInterval(-Double(notWornMinutes) * 60) }
            if !wornWindow.contains(where: \.isWorn) { return .notWorn }
        }
        return asleep ? .asleep : .stream
    }
}
