import Foundation

/// When the band streams its 100 Hz motion so Pulse can count steps (docs/METRICS.md §15). Pulse asks after every pull and when
/// the app opens. A step test keeps the stream on whatever this says.
public enum MotionStreamPolicy {
    /// Below this band battery (and not charging) the stream stops ...
    public static let lowBatteryPercent = 15.0
    /// ... and it starts again from this.
    public static let resumeBatteryPercent = 20.0
    /// No heart rate in this many of the newest minutes: the band isn't worn.
    public static let notWornMinutes = 10
    /// Still for this long: asleep or resting, with no steps to count.
    public static let stillMinutes = 30
    /// Of those, at least this many must have been measured.
    public static let fewestStillMinutesMeasured = 25
    /// A minute is still when the wrist turned less than this on average, in tenths of a degree a second. On the owner's nap,
    /// sleep turned 1 to 8 and lying awake 10 to 40.
    public static let stillTurnTenths = 10.0
    /// The same for minutes saved before the wrist's turn was stored, in Pulse's movement units (a 1° turn is about 9).
    public static let stillMovement = 9.0

    public enum Decision: String, Equatable, Sendable {
        case stream, lowBattery, notWorn, still

        public var isOn: Bool { self == .stream }
    }

    /// - Parameters:
    ///   - minutes: the newest band minutes, any order (the last 30 minutes or more).
    ///   - streaming: whether the stream is on now, so the battery limits don't flicker.
    public static func decide(recent minutes: [MinuteSample], batteryPercent: Double?, charging: Bool?,
                              streaming: Bool) -> Decision {
        if charging != true, let batteryPercent,
           batteryPercent < (streaming ? lowBatteryPercent : resumeBatteryPercent) {
            return .lowBattery
        }
        let sorted = minutes.filter { $0.source != .simulated }.sorted { $0.start < $1.start }
        guard let newest = sorted.last?.start else { return .stream }
        let wornWindow = sorted.filter { $0.start > newest.addingTimeInterval(-Double(notWornMinutes) * 60) }
        if !wornWindow.contains(where: \.isWorn) { return .notWorn }
        let stillWindow = sorted.filter { $0.start > newest.addingTimeInterval(-Double(stillMinutes) * 60) }
        if stillWindow.count >= fewestStillMinutesMeasured, stillWindow.allSatisfy(isStill) { return .still }
        return .stream
    }

    static func isStill(_ minute: MinuteSample) -> Bool {
        guard minute.isWorn else { return false }
        if let turns = minute.wristAngle?.filter({ $0 != WristAngle.noReading }), !turns.isEmpty {
            return Double(turns.reduce(0) { $0 + Int($1) }) / Double(turns.count) < stillTurnTenths
        }
        return minute.movement < stillMovement
    }
}
