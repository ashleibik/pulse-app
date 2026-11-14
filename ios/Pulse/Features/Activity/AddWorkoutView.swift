import SwiftUI
import SwiftData
import PulseCore

/// Add a workout by hand, for sessions Pulse can't spot by itself (weights, yoga: the heart rate
/// stays too low for automatic detection). You give the type and the time; Pulse fills in heart
/// rate, zones and strain from what the band recorded in that window.
/// Mono design (ios/design/DESIGN.md).
struct AddWorkoutView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var profiles: [ProfileRecord]
    @Query(sort: \DaySummaryRecord.date, order: .reverse) private var days: [DaySummaryRecord]

    @State private var kind: WorkoutKind = .strength
    @State private var start = Date.now.addingTimeInterval(-3600)
    @State private var minutes = 45

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
                    row("Duration") {
                        Text(PulseFormat.duration(minutes: minutes))
                            .textStyle(.bodyStrong)
                            .monospacedDigit()
                            .foregroundStyle(DS.Colors.primary)
                            .padding(.trailing, DS.Space.xs)
                        IconButton(systemName: "minus", label: "Shorter") { minutes = max(10, minutes - 5) }
                            .disabled(minutes <= 10)
                        IconButton(systemName: "plus", label: "Longer") { minutes = min(240, minutes + 5) }
                            .disabled(minutes >= 240)
                    }
                }

                Text("Heart rate, zones and strain are filled in from your band's data for that time.")
                    .textStyle(.caption)
                    .foregroundStyle(DS.Colors.secondary)
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
        // A workout can't end in the future: there is no band data for that yet.
        let end = min(start.addingTimeInterval(Double(minutes) * 60), .now)
        let raw = PulseStore.minutes(from: start, to: end, in: context)
        let rest = days.first { Calendar.current.isDate($0.date, inSameDayAs: start) }?.restingHeartRate
        let workout = WorkoutDetector.manual(kind: kind, start: start, end: end, minutes: raw,
                                             profile: profiles.first?.metricsProfile ?? MetricsProfile(),
                                             restingHeartRate: rest)
        context.insert(WorkoutRecord(workout))
        try? context.save()
        dismiss()
    }
}
