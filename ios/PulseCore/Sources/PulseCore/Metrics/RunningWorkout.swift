import Foundation

/// A workout the owner started in Pulse and hasn't finished yet (ios/design/DESIGN.md §4b-4).
///
/// Only its start and type: the numbers come from the band's stored minutes once it is finished. The app keeps it on the
/// phone, so it carries on when the owner leaves the workout screen, closes Pulse, or iOS ends the app in the background.
public struct RunningWorkout: Codable, Equatable, Sendable {
    public var start: Date
    public var kind: WorkoutKind

    public init(start: Date, kind: WorkoutKind) {
        self.start = start
        self.kind = kind
    }

    /// The stored form.
    public func encoded() -> Data? { try? JSONEncoder().encode(self) }

    /// nil when the stored form can't be read (then no workout is running).
    public init?(data: Data) {
        guard let workout = try? JSONDecoder().decode(RunningWorkout.self, from: data) else { return nil }
        self = workout
    }

    /// Pulse doesn't record a workout by itself over one the owner is timing: a found workout that ends after this one
    /// started is left out, like one over a workout added by hand (docs/METRICS.md §10). The running one has no end yet.
    public func overlaps(start: Date, end: Date) -> Bool {
        end > self.start
    }

    /// "0:12:34": hours, minutes and seconds since the start (never below zero).
    public func elapsedText(at now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
}
