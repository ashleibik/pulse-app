import SwiftUI
import SwiftData
import PulseCore

/// Home screen. Goal: answer "How ready am I today?" in 2 seconds.
/// Top to bottom: verdict (recovery) -> what to do with it (strain target) -> supporting numbers -> today's activity.
struct TodayView: View {
    @Query(sort: \DaySummaryRecord.date, order: .reverse) private var days: [DaySummaryRecord]
    @Query(sort: \WorkoutRecord.start, order: .reverse) private var workouts: [WorkoutRecord]
    @Query private var profiles: [ProfileRecord]
    @Environment(DemoDataLoader.self) private var loader

    @State private var showSettings = LaunchOptions.route == "settings"
    @State private var showRecovery = LaunchOptions.route == "recovery"
    @State private var explaining: MetricKind?

    var body: some View {
        NavigationStack {
            ScrollView {
                if let today = days.first {
                    content(today)
                        .padding(.horizontal)
                        .padding(.bottom, 24)
                } else {
                    loadingState
                }
            }
            .screenBackground()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { SyncStatusChip() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape.fill") }
                        .accessibilityLabel("Settings")
                }
            }
            .navigationDestination(isPresented: $showRecovery) {
                if let today = days.first { RecoveryDetailView(day: today) }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(item: $explaining) { kind in
                MetricExplainerView(kind: kind, today: days.first, history: Array(days.prefix(14)))
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func content(_ today: DaySummaryRecord) -> some View {
        VStack(alignment: .leading, spacing: Theme.spacing) {
            header
            recoveryCard(today)
            strainCard(today)
            tiles(today)
            activity
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(greeting)
                .font(.largeTitle.weight(.bold))
            Text(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
        }
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func recoveryCard(_ today: DaySummaryRecord) -> some View {
        NavigationLink {
            RecoveryDetailView(day: today)
        } label: {
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
                Label("See what moved your score", systemImage: "chevron.right")
                    .labelStyle(TrailingIconLabelStyle())
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.accent)
            }
            .frame(maxWidth: .infinity)
            .card()
        }
        .buttonStyle(.plain)
    }

    private func strainCard(_ today: DaySummaryRecord) -> some View {
        let target = StrainGuidance.targetRange(recovery: today.recoveryScore)
        return Button { explaining = .strain } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Label("Strain", systemImage: "flame.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.strain)
                    Spacer()
                    Text(PulseFormat.strain(today.strain))
                        .font(.title2.weight(.bold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("/ 21").font(.caption).foregroundStyle(Theme.secondaryText)
                }
                StrainTargetBar(strain: today.strain, target: target)
                Text(StrainGuidance.advice(strain: today.strain, recovery: today.recoveryScore))
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
            }
            .card()
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows what strain means")
    }

    private func tiles(_ today: DaySummaryRecord) -> some View {
        let columns = [GridItem(.flexible(), spacing: Theme.spacing), GridItem(.flexible(), spacing: Theme.spacing)]
        return LazyVGrid(columns: columns, spacing: Theme.spacing) {
            tile(.sleep) {
                MetricTile(title: "Sleep",
                           value: today.sleepMinutes.map { PulseFormat.duration(minutes: $0) } ?? "--",
                           caption: sleepCaption(today), color: Theme.sleep, systemImage: "moon.fill")
            }
            tile(.sleep) {
                MetricTile(title: "Need tonight", value: PulseFormat.duration(minutes: tonightsNeed(today)),
                           caption: "go to bed in time", color: Theme.sleep, systemImage: "bed.double.fill")
            }
            tile(.hrv) {
                MetricTile(title: "HRV", value: today.hrvRMSSD.map { "\(Int($0.rounded()))" } ?? "--",
                           unit: "ms", caption: baselineCaption(today.hrvRMSSD, today.baselineHRV),
                           color: Theme.recoveryGreen, systemImage: "waveform.path.ecg")
            }
            tile(.restingHeartRate) {
                MetricTile(title: "Resting HR", value: today.restingHeartRate.map { "\(Int($0.rounded()))" } ?? "--",
                           unit: "bpm", caption: baselineCaption(today.restingHeartRate, today.baselineRestingHeartRate),
                           color: Theme.heart, systemImage: "heart.fill")
            }
        }
    }

    @ViewBuilder
    private var activity: some View {
        let todays = workouts.filter { Calendar.current.isDateInToday($0.start) }
        SectionHeader(title: "Today's activity", trailing: todays.isEmpty ? nil : "\(todays.count)")
            .padding(.top, 8)
        if todays.isEmpty {
            Label("No workouts yet today", systemImage: "figure.walk")
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

    private var loadingState: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Generating 30 days of demo data…")
                .font(.headline)
            Text("This only happens once.")
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 160)
    }

    // MARK: - Helpers

    private func tile<Content: View>(_ kind: MetricKind, @ViewBuilder _ content: () -> Content) -> some View {
        Button { explaining = kind } label: { content() }
            .buttonStyle(.plain)
            .accessibilityHint("Shows what this means")
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<12: "Good morning"
        case 12..<18: "Good afternoon"
        default: "Good evening"
        }
    }

    /// Tonight's need = tomorrow's formula applied to today (yesterday-strain and debt rules).
    private func tonightsNeed(_ today: DaySummaryRecord) -> Int {
        let goal = Double(profiles.first?.sleepGoalMinutes ?? 480)
        return Int(Recovery.sleepNeed(goal: goal, previousStrain: today.strain,
                                      previousNeed: Double(today.sleepNeedMinutes),
                                      previousAsleep: today.sleepMinutes.map { Double($0) }).rounded())
    }

    private func sleepCaption(_ day: DaySummaryRecord) -> String {
        guard let slept = day.sleepMinutes, day.sleepNeedMinutes > 0 else { return "no data" }
        return "\(Int((Double(slept) / Double(day.sleepNeedMinutes) * 100).rounded()))% of need"
    }

    private func baselineCaption(_ value: Double?, _ baseline: Double?) -> String {
        guard let value, let baseline else { return "building baseline" }
        let diff = Int((value - baseline).rounded())
        if diff == 0 { return "at your normal" }
        return diff > 0 ? "▲ \(diff) vs normal" : "▼ \(-diff) vs normal"
    }
}

/// "Text  >" with the icon after the title.
struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.title
            configuration.icon.imageScale(.small)
        }
    }
}

#Preview {
    TodayView()
        .modelContainer(PulseStore.previewContainer)
        .environment(DemoDataLoader())
        .preferredColorScheme(.dark)
}
