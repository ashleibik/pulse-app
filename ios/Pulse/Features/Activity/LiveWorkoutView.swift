import SwiftUI
import SwiftData
import PulseCore

/// Start a workout now, watch your heart rate live, finish it when you're done.
///
/// The live number comes straight from the band (it needs to be paired and nearby). Without a
/// band the timer still runs and the workout is still saved. The saved numbers (average heart
/// rate, zones, strain) are filled in from the band's stored data, at the next sync at the latest.
///
/// ⚠ The live stream has only been run against the simulated band.
struct LiveWorkoutView: View {
    @Environment(BandManager.self) private var band
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var profiles: [ProfileRecord]
    @Query(sort: \DaySummaryRecord.date, order: .reverse) private var days: [DaySummaryRecord]

    @State private var kind: WorkoutKind = .run
    @State private var start = Date.now
    @State private var confirmDiscard = false

    private var maxHR: Double { profiles.first?.estimatedMaxHeartRate() ?? 190 }

    var body: some View {
        VStack(spacing: DS.Space.l) {
            ScreenHeader(title: "Workout") {
                IconButton(systemName: "xmark", label: "Discard workout") { confirmDiscard = true }
            }
            Spacer(minLength: 0)

            ZStack {
                // The ring fills with how hard you're going: heart rate as a share of your maximum.
                GlowOrb(fraction: min(1, Double(band.liveHeartRate ?? 0) / maxHR), color: zoneColor)
                VStack(spacing: 0) {
                    Text(band.liveHeartRate.map(String.init) ?? "--")
                        .font(.system(size: 84, weight: .bold).width(.condensed))
                        .monospacedDigit()
                        .foregroundStyle(DS.Colors.primary)
                        .contentTransition(.numericText())
                        .animation(DS.Motion.spring, value: band.liveHeartRate)
                    Text("BPM")
                        .textStyle(.label)
                        .foregroundStyle(DS.Colors.secondary)
                }
            }
            .frame(width: 260, height: 260)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Heart rate")
            .accessibilityValue(band.liveHeartRate.map { "\($0) beats per minute" } ?? "not available")

            // A clock that redraws once a second.
            TimelineView(.periodic(from: start, by: 1)) { timeline in
                Text(elapsed(until: timeline.date))
                    .textStyle(.display)
                    .monospacedDigit()
                    .foregroundStyle(DS.Colors.primary)
            }

            if band.liveHeartRate == nil {
                Text("Live heart rate needs your band paired and nearby. The timer works without it.")
                    .textStyle(.caption)
                    .foregroundStyle(DS.Colors.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, DS.Space.side)
            }
            Spacer(minLength: 0)

            HStack(spacing: DS.Space.m) {
                Text("Type")
                    .textStyle(.body)
                    .foregroundStyle(DS.Colors.primary)
                Spacer()
                Picker("Type", selection: $kind) {
                    ForEach(WorkoutKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .tint(DS.Colors.accent)
            }
            .padding(.horizontal, DS.Space.side)

            Button {
                finish()
            } label: {
                Text("Finish workout").frame(maxWidth: .infinity)
            }
            .buttonStyle(.primaryPill)
            .padding(.horizontal, DS.Space.side)
            .padding(.bottom, DS.Space.l)
        }
        .monoBackground()
        .onAppear {
            start = .now
            band.startLive(context: context)
        }
        .onDisappear { band.stopLive() }
        .confirmationDialog("Discard this workout?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard") { dismiss() }
        }
    }

    /// Green while easy, yellow when hard, red near your maximum.
    private var zoneColor: Color {
        guard let hr = band.liveHeartRate else { return DS.Colors.tertiary }
        let share = Double(hr) / maxHR
        if share < 0.7 { return DS.Colors.accent }
        return share < 0.9 ? DS.Colors.warn : DS.Colors.alert
    }

    private func elapsed(until now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }

    private func finish() {
        let end = Date.now
        // Under a minute is a mis-tap, not a workout.
        if end.timeIntervalSince(start) >= 60 {
            let raw = PulseStore.minutes(from: start, to: end, in: context)
            let rest = days.first { Calendar.current.isDate($0.date, inSameDayAs: start) }?.restingHeartRate
            let workout = WorkoutDetector.manual(kind: kind, start: start, end: end, minutes: raw,
                                                 profile: profiles.first?.metricsProfile ?? MetricsProfile(),
                                                 restingHeartRate: rest)
            context.insert(WorkoutRecord(workout))
            try? context.save()
        }
        dismiss()
    }
}
