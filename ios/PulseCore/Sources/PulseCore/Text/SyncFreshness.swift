import Foundation

/// Today's "Last synced" line (DESIGN.md §4b): how long ago a pull from the band last finished, and a warning once that is
/// long enough to mean the background sync has stopped (docs/METRICS.md §15, "Keeping Pulse awake").
public enum SyncFreshness {
    /// Past this without a finished pull, the line becomes a warning. Pulls run every 5 minutes in the background.
    public static let staleAfter: TimeInterval = 2 * 3600

    public struct Line: Equatable, Sendable {
        public let text: String
        public let isStale: Bool
    }

    /// - Parameters:
    ///   - lastSync: when the newest pull finished (`BandRecord.lastHistorySyncAt`); nil = never, then there is no line.
    ///   - syncing: a pull is running right now.
    public static func line(lastSync: Date?, now: Date, syncing: Bool) -> Line? {
        guard let lastSync else { return nil }
        let age = max(0, now.timeIntervalSince(lastSync))
        let stale = age >= staleAfter
        if syncing {
            return Line(text: stale ? "Syncing… last synced \(ago(age))" : "Syncing…", isStale: false)
        }
        if age < 60 { return Line(text: "Synced just now", isStale: false) }
        if age < 3600 { return Line(text: "Synced \(ago(age))", isStale: false) }
        return Line(text: "Last synced \(ago(age))", isStale: stale)
    }

    /// 240 s -> "4 min ago", 2h 14m -> "2h 14m ago", 3 days -> "3 days ago".
    static func ago(_ age: TimeInterval) -> String {
        let minutes = Int(age / 60)
        if minutes < 60 { return "\(max(1, minutes)) min ago" }
        if minutes < 24 * 60 { return PulseFormat.duration(minutes: minutes) + " ago" }
        let days = minutes / (24 * 60)
        return days == 1 ? "1 day ago" : "\(days) days ago"
    }
}
