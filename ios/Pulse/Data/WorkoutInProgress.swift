import Foundation
import Observation
import PulseCore

/// The workout started in Pulse and not finished yet, and whether its sheet is open (ios/design/DESIGN.md §4b-4).
///
/// Kept in UserDefaults (only its start and type), so it carries on when the owner leaves the sheet, closes Pulse, or iOS
/// ends the app in the background. The sheet is presented by RootView, so it opens from any tab and from the workout bar.
@MainActor
@Observable
final class WorkoutInProgress {
    static let shared = WorkoutInProgress()
    static let storageKey = "runningWorkout"

    private(set) var running: RunningWorkout?
    /// The workout sheet is open.
    var isShowing = false

    private init() {
        running = UserDefaults.standard.data(forKey: Self.storageKey).flatMap(RunningWorkout.init(data:))
    }

    /// "Start activity": opens the sheet, starting a workout now unless one is already running.
    func open() {
        if running == nil {
            running = RunningWorkout(start: .now, kind: .run)
            store()
        }
        isShowing = true
    }

    func setKind(_ kind: WorkoutKind) {
        guard running != nil, running?.kind != kind else { return }
        running?.kind = kind
        store()
    }

    /// Finished (saved) or discarded: no workout runs any more, and the sheet closes.
    func end() {
        running = nil
        isShowing = false
        store()
    }

    private func store() {
        if let data = running?.encoded() {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.storageKey)
        }
    }
}
