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

    /// The App Group written in both .entitlements files.
    static let plannedGroup = "group.dev.pulse.app"
    private static let key = "widgetSnapshot"

    /// The App Group this copy of the app was actually signed with, or nil if it has none.
    ///
    /// Why not just `plannedGroup`: when Sideloadly re-signs the app with a free Apple ID it may
    /// rename the group (e.g. add your team ID). And `UserDefaults(suiteName:)` with a group the
    /// app isn't entitled to does NOT fail: it quietly writes to the app's private storage, where
    /// the widget can't see it. So: read the real group names from the signing profile inside the
    /// bundle, and keep the first one iOS actually gives us a shared folder for.
    static let appGroup: String? = {
        let candidates = groupsInProfile() + [plannedGroup]
        return candidates.first {
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) != nil
        }
    }()

    /// App Group names from `embedded.mobileprovision` (a signed file with a readable plist inside).
    /// In the widget, Bundle.main is the widget's own bundle, which has its own profile.
    private static func groupsInProfile() -> [String] {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data.subdata(in: start.lowerBound..<end.upperBound), format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any] else { return [] }
        return entitlements["com.apple.security.application-groups"] as? [String] ?? []
    }

    private static var defaults: UserDefaults? { appGroup.flatMap { UserDefaults(suiteName: $0) } }

    static func load() -> WidgetSnapshot? {
        guard let data = defaults?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    /// Returns false when there is no shared storage (the App Group was not kept when signing).
    @discardableResult
    func save() -> Bool {
        guard let defaults = Self.defaults, let data = try? JSONEncoder().encode(self) else { return false }
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
