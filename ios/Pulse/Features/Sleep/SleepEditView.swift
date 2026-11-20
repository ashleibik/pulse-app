import SwiftUI
import SwiftData
import PulseCore

/// The sleep being corrected. Plain dates: the stored sleep is rebuilt as soon as a correction is saved.
struct SleepEditTarget: Identifiable {
    let start: Date
    let end: Date
    var id: Date { start }
}

/// Fix a sleep's times, or say it wasn't sleep at all. The correction is kept apart from the detected
/// data, so it survives every recalculation, and all numbers that depend on the night follow it.
struct SleepEditView: View {
    let target: SleepEditTarget

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(DataLoader.self) private var loader
    @State private var start: Date
    @State private var end: Date
    @State private var confirmRemove = false

    init(target: SleepEditTarget) {
        self.target = target
        _start = State(initialValue: target.start)
        _end = State(initialValue: target.end)
    }

    /// At least 10 minutes, at most a day, and not in the future.
    private var timesAreValid: Bool {
        let length = end.timeIntervalSince(start)
        return length >= 10 * 60 && length <= 86_400 && end <= .now
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                VStack(alignment: .leading, spacing: 0) {
                    timeRow("Fell asleep", selection: $start)
                    Hairline()
                    timeRow("Woke up", selection: $end)
                }
                .monoCard(padding: DS.Space.m)

                if !timesAreValid {
                    Text("Waking up must be after falling asleep, within a day, and not in the future.")
                        .textStyle(.caption)
                        .foregroundStyle(DS.Colors.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button("Save times") { save(start: start, end: end) }
                    .buttonStyle(.primaryPill)
                    .disabled(!timesAreValid)
                Button("I wasn't asleep") { confirmRemove = true }
                    .buttonStyle(.secondaryPill)

                Text("Recovery and sleep need follow your change. You can undo your edits in Settings > Your data.")
                    .textStyle(.caption)
                    .foregroundStyle(DS.Colors.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, DS.Space.side)
            .padding(.top, DS.Space.l)
            .padding(.bottom, DS.Space.xl)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            ScreenHeader(title: "Edit sleep", isSheet: true) {
                IconButton(systemName: "xmark", label: "Close") { dismiss() }
            }
        }
        .monoSheet()
        .confirmationDialog("Remove this sleep?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove sleep", role: .destructive) { save(start: nil, end: nil) }
        } message: {
            Text("Pulse will treat this time as awake.")
        }
    }

    private func timeRow(_ label: String, selection: Binding<Date>) -> some View {
        HStack(spacing: DS.Space.m) {
            Text(label)
                .textStyle(.body)
                .foregroundStyle(DS.Colors.primary)
            Spacer(minLength: DS.Space.s)
            DatePicker(label, selection: selection, in: ...Date.now)
                .labelsHidden()
                .tint(DS.Colors.accent)
        }
        .frame(minHeight: 52)
    }

    private func save(start: Date?, end: Date?) {
        SleepAnswer.save(target: target, start: start, end: end, context: context, loader: loader)
        dismiss()
    }
}
