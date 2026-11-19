import SwiftUI
import SwiftData
import PulseCore

/// Saves what the user said about a sleep: new times, "yes, that was sleep", or "I wasn't asleep" (nil times).
@MainActor
enum SleepAnswer {
    static func save(target: SleepEditTarget, start: Date?, end: Date?, context: ModelContext, loader: DataLoader) {
        let correction = SleepCorrection(detectedStart: target.start, detectedEnd: target.end, start: start, end: end,
                                         createdAt: .now)
        context.insert(SleepCorrectionRecord(correction))
        try? context.save()
        Task { await loader.recompute(context: context) }
    }
}

/// "Is this right?" on a sleep Pulse is unsure about (DESIGN.md §4b-2). The answer corrects this sleep
/// and teaches Pulse about similar ones.
struct SleepReviewCard: View {
    let sleep: SleepRecord

    @Environment(\.modelContext) private var context
    @Environment(DataLoader.self) private var loader
    @State private var editing: SleepEditTarget?
    @State private var confirmRemove = false

    private var target: SleepEditTarget { SleepEditTarget(start: sleep.start, end: sleep.end) }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text("Is this right?")
                    .textStyle(.heading)
                    .foregroundStyle(DS.Colors.primary)
                Text(sleep.value.reviewReason?.message ?? "")
                    .textStyle(.body)
                    .foregroundStyle(DS.Colors.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Yes") {
                SleepAnswer.save(target: target, start: sleep.start, end: sleep.end, context: context, loader: loader)
            }
            .buttonStyle(.primaryPill)
            Button("Fix times") { editing = target }
                .buttonStyle(.secondaryPill)
            Button("Not asleep") { confirmRemove = true }
                .buttonStyle(.secondaryPill)
        }
        .disabled(loader.isBusy)
        .monoCard(padding: DS.Space.m)
        .sheet(item: $editing) { SleepEditView(target: $0) }
        .confirmationDialog("Remove this sleep?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove sleep", role: .destructive) {
                SleepAnswer.save(target: target, start: nil, end: nil, context: context, loader: loader)
            }
        } message: {
            Text("Pulse will treat this time as awake.")
        }
    }
}

/// One line under a night's phases when part of it has no band data.
struct UnknownMinutesNote: View {
    let minutes: Int

    var body: some View {
        if minutes > 0 {
            Text("\(PulseFormat.duration(minutes: minutes)) has no band data, so it isn't counted as asleep or awake.")
                .textStyle(.caption)
                .foregroundStyle(DS.Colors.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
