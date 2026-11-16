import Foundation

/// The few numbers the home screen widget shows. Compiled into BOTH the app and the widget.
///
/// The widget runs in its own little process and can't open the app's database, so after every
/// change the app writes this snapshot into a shared "App Group" storage, and the widget reads it.
/// Only today's summary numbers go in here: no raw heartbeats, nothing leaves the phone.
struct WidgetSnapshot: Codable, Equatable {
    /// The day these numbers belong to (start of day).
    var day: Date
    var recovery: Double?
    /// "green" / "yellow" / "red" (PulseCore's RecoveryZone raw value). nil = not enough data yet.
    var zone: String?
    /// "Ready" / "Steady" / "Rest" / "Learning": said in words too, so color is never the only signal.
    var word: String
    var strain: Double
    var sleepMinutes: Int?
    /// True while the app still shows the demo month.
    var simulated: Bool
    var updated: Date

    /// Must match the App Group in both .entitlements files.
    static let appGroup = "group.dev.pulse.app"
    private static let key = "widgetSnapshot"

    static func load() -> WidgetSnapshot? {
        guard let data = UserDefaults(suiteName: appGroup)?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    /// Returns false when the shared storage isn't available (e.g. the App Group was not signed in).
    @discardableResult
    func save() -> Bool {
        guard let defaults = UserDefaults(suiteName: Self.appGroup),
              let data = try? JSONEncoder().encode(self) else { return false }
        defaults.set(data, forKey: Self.key)
        return true
    }

    var sleepText: String {
        guard let sleepMinutes else { return "--" }
        return "\(sleepMinutes / 60)h \(sleepMinutes % 60)m"
    }

    var recoveryText: String { recovery.map { "\(Int($0.rounded()))%" } ?? "--" }

    /// Shown in the widget gallery and while the real snapshot loads.
    static let sample = WidgetSnapshot(day: Calendar.current.startOfDay(for: .now), recovery: 72, zone: "green",
                                       word: "Ready", strain: 11.4, sleepMinutes: 452, simulated: true, updated: .now)
}
