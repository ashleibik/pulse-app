import SwiftUI
import SwiftData
import PulseCore

/// Add a past workout by hand. You give the type, start and end; Pulse fills in heart rate, zones,
/// strain and calories from what the band recorded in that window.
/// Mono design (ios/design/DESIGN.md).
struct AddWorkoutView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var profiles: [ProfileRecord]
    @Query(sort: \DaySummaryRecord.date, order: .reverse) private var days: [DaySummaryRecord]

    @State private var kind: WorkoutKind = .strength
    @State private var start = Date.now.addingTimeInterval(-3600)
    @State private var end = Date.now.addingTimeInterval(-900)

    /// A workout ends after it starts, lasts at least a minute, and can't end in the future.
    private var timesAreValid: Bool { !WorkoutDetector.isTooShort(start: start, end: end) && end <= .now }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                Text("Pulse finds most workouts by itself. Add one here if it missed it.")
                    .textStyle(.body)
                    .foregroundStyle(DS.Colors.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 0) {
                    row("Type") {
                        Picker("Type", selection: $kind) {
                            ForEach(WorkoutKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .tint(DS.Colors.primary)
                    }
                    Hairline()
                    row("Started") {
                        DatePicker("Started", selection: $start, in: ...Date.now)
                            .labelsHidden()
                            .tint(DS.Colors.primary)
                    }
                    Hairline()
                    row("Ended") {
                        DatePicker("Ended", selection: $end, in: ...Date.now)
                            .labelsHidden()
                            .tint(DS.Colors.primary)
                    }
                }

                Text(timesAreValid ? "Heart rate, zones, strain and calories are filled in from your band's data for that time."
                                   : "The end must be at least a minute after the start, and not in the future.")
                    .textStyle(.caption)
                    .foregroundStyle(timesAreValid ? DS.Colors.secondary : DS.Colors.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, DS.Space.side)
            .padding(.top, DS.Space.s)
            .padding(.bottom, DS.Space.xl)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            ScreenHeader(title: "Add workout", isSheet: true) {
                IconButton(systemName: "xmark", label: "Close") { dismiss() }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button {
                add()
            } label: {
                Text("Add workout").frame(maxWidth: .infinity)
            }
            .buttonStyle(.primaryPill)
            .disabled(!timesAreValid)
            .padding(.horizontal, DS.Space.side)
            .padding(.vertical, DS.Space.m)
            .background(DS.Colors.sheet)
        }
        .monoSheet()
    }

    private func row<Trailing: View>(_ label: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: DS.Space.s) {
            Text(label)
                .textStyle(.body)
                .foregroundStyle(DS.Colors.primary)
            Spacer(minLength: DS.Space.s)
            trailing()
        }
        .frame(minHeight: 60)
    }

    private func add() {
        let raw = PulseStore.minutes(from: start, to: end, in: context)
        let rest = days.first { Calendar.current.isDate($0.date, inSameDayAs: start) }?.restingHeartRate
        let workout = WorkoutDetector.manual(kind: kind, start: start, end: end, minutes: raw,
                                             profile: profiles.first?.metricsProfile ?? MetricsProfile(),
                                             body: profiles.first?.calorieBody(), restingHeartRate: rest)
        context.insert(WorkoutRecord(workout))
        try? context.save()
        dismiss()
    }
}
