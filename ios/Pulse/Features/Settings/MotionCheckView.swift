import SwiftUI
import SwiftData
import PulseCore

/// Settings > Band > Motion check: do the band's motion readings really change when you move?
/// Shows the stored values minute by minute, so the sensor can be checked on the wrist.
struct MotionCheckView: View {
    private static let minutesShown: TimeInterval = 20 * 60

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(BandManager.self) private var band
    @State private var minutes: [MinuteSample] = []
    @State private var isChecking = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                Text("Keep your wrist completely still for 3 minutes. Then type or use the mouse for 3 minutes. Then check again: the motion numbers should rise.")
                    .textStyle(.body)
                    .foregroundStyle(DS.Colors.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(MotionCheck.verdict(minutes).message)
                    .textStyle(.bodyStrong)
                    .foregroundStyle(MotionCheck.verdict(minutes) == .changing ? DS.Colors.accent : DS.Colors.warn)
                    .fixedSize(horizontal: false, vertical: true)
                    .monoCard(padding: DS.Space.m)

                Button(isChecking ? "Checking…" : "Sync and check again") { check() }
                    .buttonStyle(.primaryPill)
                    .disabled(isChecking)

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(minutes.reversed().enumerated()), id: \.element.start) { index, minute in
                        if index > 0 { Hairline() }
                        ValueRow(label: minute.start.formatted(date: .omitted, time: .shortened), value: describe(minute))
                    }
                }
            }
            .padding(.horizontal, DS.Space.side)
            .padding(.top, DS.Space.l)
            .padding(.bottom, DS.Space.xl)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            ScreenHeader(title: "Motion check", isSheet: true) {
                IconButton(systemName: "xmark", label: "Close") { dismiss() }
            }
        }
        .monoSheet()
        .onAppear { load() }
    }

    private func describe(_ minute: MinuteSample) -> String {
        guard minute.isWorn else { return "Not worn" }
        let heartRate = minute.averageHeartRate.map { "\(Int($0.rounded())) bpm" } ?? "--"
        return String(format: "%@ · motion %.1f, peak %d", heartRate, minute.averageActivity, Int(minute.activity.max() ?? 0))
    }

    private func load() {
        minutes = PulseStore.minutes(from: Date.now.addingTimeInterval(-Self.minutesShown), to: .now, in: context)
    }

    private func check() {
        isChecking = true
        Task {
            await band.refresh(context: context)
            load()
            isChecking = false
        }
    }
}
