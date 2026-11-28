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
    /// The newest band minutes the sleep model looks at to tell the owner fell asleep ...
    public static let asleepWindowMinutes = 20
    /// ... and the share of them, measured, that must be likely asleep.
    public static let asleepShare = 0.8

    /// The sleep model's newest minutes say the owner has fallen asleep: at least `asleepShare` of the newest
    /// `asleepWindowMinutes` are likely asleep, with at least half of them measured (docs/METRICS.md §15). Shorter windows
    /// fired on the owner's still minutes at noon.
    /// - Parameter newest: oldest first; true = likely asleep, false = awake, nil = no band data (`MetricsResult.newestMinutesAsleep`).
    public static func looksAsleep(_ newest: [Bool?]) -> Bool {
        let measured = newest.suffix(asleepWindowMinutes).compactMap { $0 }
        guard measured.count * 2 >= asleepWindowMinutes else { return false }
        return Double(measured.filter { $0 }.count) >= asleepShare * Double(measured.count)
    }

    public enum Decision: String, Equatable, Sendable {
        case stream, lowBattery, notWorn, asleep

        public var isOn: Bool { self == .stream }
    }

    /// Whether the band's live heart rate runs as Pulse's heartbeat (docs/METRICS.md §15, "Keeping Pulse awake"): whenever the
    /// stream is off. iOS only runs Pulse in the background while the band sends it something, and the stream used to be the
    /// only thing it sent. With the stream off in bed nothing woke Pulse, so nothing was pulled and nothing turned the stream
    /// back on: on 2026-11-26/27 the stream went off at 21:50 and the night only arrived when the owner opened Pulse the next
    /// afternoon. The heartbeat is one small packet a second (about 1% of the stream's data), enough for a pull every few
    /// minutes. A step test or the stream itself keeps Pulse awake instead.
    public static func heartbeat(for decision: Decision) -> Bool {
        !decision.isOn
    }

    /// - Parameters:
    ///   - minutes: the newest band minutes, any order (the last 10 minutes or more).
    ///   - streaming: whether the stream is on now, so the battery limits don't flicker.
    ///   - asleep: the owner is asleep or still in their night: a sleep found and not finished yet (short wakes in bed
    ///     included), or the newest minutes `looksAsleep` before the sleep is found (docs/METRICS.md §15).
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
