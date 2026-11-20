import SwiftUI
import SwiftData
import PulseCore

/// Walks the owner said no to, so detection doesn't ask again.
enum WorkoutSuggestions {
    private static let key = "dismissedWorkoutSuggestions"

    static var dismissed: Set<String> { Set(UserDefaults.standard.stringArray(forKey: key) ?? []) }

    static func dismiss(_ id: UUID) {
        UserDefaults.standard.set(Array(dismissed.union([id.uuidString])), forKey: key)
    }
}

/// "Was this a walk?" (DESIGN.md §4b-4).
struct WalkSuggestionCard: View {
    let workout: WorkoutRecord

    @Environment(\.modelContext) private var context

    private var times: String {
        "\(workout.start.formatted(date: .abbreviated, time: .shortened)) – \(workout.end.formatted(date: .omitted, time: .shortened))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text("Was this a walk?")
                    .textStyle(.heading)
                    .foregroundStyle(DS.Colors.primary)
                Text("\(times) · \(PulseFormat.duration(minutes: workout.durationMinutes))")
                    .textStyle(.body)
                    .foregroundStyle(DS.Colors.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: DS.Space.s) {
                Button("Yes") {
                    workout.isSuggestion = false
                    try? context.save()
                }
                .buttonStyle(.primaryPill)
                Button("No") {
                    WorkoutSuggestions.dismiss(workout.id)
                    context.delete(workout)
                    try? context.save()
                }
                .buttonStyle(.secondaryPill)
            }
        }
        .monoCard(padding: DS.Space.m)
    }
}
