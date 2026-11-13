import SwiftUI
import SwiftData
import PulseCore

/// Home screen. Goal: answer "How ready am I today?" in 2 seconds.
struct TodayView: View {
    @Query(sort: \DaySummaryRecord.date, order: .reverse) private var days: [DaySummaryRecord]
    @Query(sort: \WorkoutRecord.start, order: .reverse) private var workouts: [WorkoutRecord]

    @State private var showSettings = false
    @State private var explaining: MetricKind?

    var body: some View {
        NavigationStack {
            ScrollView {
                if let today = days.first {
                    content(today)
                        .padding(.horizontal)
                        .padding(.bottom, 24)
                } else {
                    ProgressView("Preparing your data…")
                        .padding(.top, 160)
                }
            }
            .screenBackground()
            .navigationTitle(Text(Date.now, format: .dateTime.weekday(.wide).month().day()))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { SyncStatusChip() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape.fill") }
                        .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(item: $explaining) { kind in
                MetricExplainerView(kind: kind, today: days.first, history: Array(days.prefix(14)))
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    @ViewBuilder
    private func content(_ today: DaySummaryRecord) -> some View {
        VStack(spacing: Theme.spacing) {
            // 1. The answer: recovery ring + one-line verdict + why.
            Button { explaining = .recovery } label: {
                VStack(spacing: 14) {
                    RecoveryRing(score: today.recoveryScore)
                        .padding(.top, 8)
                    if let zone = today.zone {
                        Text(zone.headline)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(Theme.color(for: zone))
                    }
                    Text(today.explanation)
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .card()
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows what recovery means and why it changed")

            // 2. The three supporting numbers.
            HStack(spacing: Theme.spacing) {
                tile(.strain) {
                    MetricTile(title: "Strain", value: PulseFormat.strain(today.strain),
                               caption: "of 21", color: Theme.strain, systemImage: "flame.fill")
                }
                tile(.sleep) {
                    MetricTile(title: "Sleep",
                               value: today.sleepMinutes.map { PulseFormat.duration(minutes: $0) } ?? "--",
                               caption: sleepCaption(today), color: Theme.sleep, systemImage: "moon.fill")
                }
            }
            HStack(spacing: Theme.spacing) {
                tile(.hrv) {
                    MetricTile(title: "HRV", value: today.hrvRMSSD.map { "\(Int($0.rounded()))" } ?? "--",
                               unit: "ms", caption: baselineCaption(today.hrvRMSSD, today.baselineHRV, unit: "ms"),
                               color: Theme.recoveryGreen, systemImage: "waveform.path.ecg")
                }
                tile(.restingHeartRate) {
                    MetricTile(title: "Resting HR", value: today.restingHeartRate.map { "\(Int($0.rounded()))" } ?? "--",
                               unit: "bpm", caption: baselineCaption(today.restingHeartRate, today.baselineRestingHeartRate, unit: "bpm"),
                               color: Theme.heart, systemImage: "heart.fill")
                }
            }

            // 3. Today's workouts.
            let todays = workouts.filter { Calendar.current.isDateInToday($0.start) }
            SectionHeader(title: "Today's activity", trailing: todays.isEmpty ? nil : "\(todays.count)")
                .padding(.top, 8)
            if todays.isEmpty {
                Text("No workouts yet today.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                    .card()
            } else {
                VStack(spacing: 14) {
                    ForEach(todays) { WorkoutRow(workout: $0) }
                }
                .card()
            }
        }
    }

    private func tile<Content: View>(_ kind: MetricKind, @ViewBuilder _ content: () -> Content) -> some View {
        Button { explaining = kind } label: { content() }
            .buttonStyle(.plain)
            .accessibilityHint("Shows what this means")
    }

    private func sleepCaption(_ day: DaySummaryRecord) -> String {
        guard let slept = day.sleepMinutes, day.sleepNeedMinutes > 0 else { return "no data" }
        return "\(Int((Double(slept) / Double(day.sleepNeedMinutes) * 100).rounded()))% of need"
    }

    private func baselineCaption(_ value: Double?, _ baseline: Double?, unit: String) -> String {
        guard let value, let baseline else { return "building baseline" }
        let diff = Int((value - baseline).rounded())
        if diff == 0 { return "at baseline" }
        return diff > 0 ? "▲ \(diff) vs baseline" : "▼ \(-diff) vs baseline"
    }
}

#Preview {
    TodayView()
        .modelContainer(PulseStore.previewContainer)
        .environment(DemoDataLoader())
        .preferredColorScheme(.dark)
}
