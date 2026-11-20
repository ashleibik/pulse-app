import SwiftUI
import SwiftData
import PulseCore

/// Log a nap by hand (DESIGN.md §4b-7). It is kept as one of the user's sleep corrections, so it survives every
/// recalculation. With no band data for those minutes, the whole nap counts as asleep (docs/METRICS.md §4, step 10).
struct AddNapView: View {
    /// Every sleep already saved, so a nap can't overlap one.
    let otherSleeps: [DateInterval]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(DataLoader.self) private var loader
    @State private var start: Date
    @State private var end: Date

    /// The shortest and longest nap that can be logged.
    static let shortest: TimeInterval = 10 * 60
    static let longest: TimeInterval = 3 * 3600

    init(otherSleeps: [DateInterval], now: Date = .now) {
        self.otherSleeps = otherSleeps
        let rounded = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / 300).rounded(.down) * 300)
        _end = State(initialValue: rounded)
        _start = State(initialValue: rounded.addingTimeInterval(-30 * 60))
    }

    private var problem: String? {
        let length = end.timeIntervalSince(start)
        if length < Self.shortest || length > Self.longest { return "A nap lasts 10 minutes to 3 hours." }
        if end > .now { return "A nap can't end in the future." }
        if otherSleeps.contains(where: { $0.start < end && start < $0.end }) { return "This overlaps a sleep that's already saved." }
        return nil
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

                if let problem {
                    Text(problem)
                        .textStyle(.caption)
                        .foregroundStyle(DS.Colors.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button("Save nap") { save() }
                    .buttonStyle(.primaryPill)
                    .disabled(problem != nil)

                Text("Naps lower your next night's sleep need. They don't change recovery. You can undo this in Settings > Your data.")
                    .textStyle(.caption)
                    .foregroundStyle(DS.Colors.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, DS.Space.side)
            .padding(.top, DS.Space.l)
            .padding(.bottom, DS.Space.xl)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            ScreenHeader(title: "Add nap", isSheet: true) {
                IconButton(systemName: "xmark", label: "Close") { dismiss() }
            }
        }
        .monoSheet()
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

    private func save() {
        SleepAnswer.save(target: SleepEditTarget(start: start, end: end), start: start, end: end, context: context, loader: loader)
        dismiss()
    }
}
