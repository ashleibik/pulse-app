import Foundation

/// Workouts Pulse found that the owner deleted, so detection doesn't record them again (docs/METRICS.md §10). Kept under the
/// same key as the dismissed walk suggestions of earlier versions, so those stay away too.
enum DismissedWorkouts {
    private static let key = "dismissedWorkoutSuggestions"

    static var ids: Set<String> { Set(UserDefaults.standard.stringArray(forKey: key) ?? []) }

    static func dismiss(_ id: UUID) {
        UserDefaults.standard.set(Array(ids.union([id.uuidString])), forKey: key)
    }
}
