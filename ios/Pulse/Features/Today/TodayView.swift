import SwiftUI
import SwiftData
import PulseCore

/// Home screen. Goal: answer "How ready am I today?" in 2 seconds.
///
/// Built in the Mono design (ios/design/DESIGN.md): black, white and grays only. Recovery is
/// shown by how full the ring is plus one word, never by color.
///
/// Top to bottom: verdict (recovery) -> what to do with it (strain) -> supporting numbers ->
/// the week -> today's activity. Every block opens its details on tap.
struct TodayView: View {
    @Query(sort: \DaySummaryRecord.date, order: .reverse) private var days: [DaySummaryRecord]
    @Query(sort: \WorkoutRecord.start, order: .reverse) private var workouts: [WorkoutRecord]
    @Query private var profiles: [ProfileRecord]

    @State private var showSettings = LaunchOptions.route == "settings"
    @State private var showRecovery = LaunchOptions.route == "recovery"
    @State private var explaining: MetricKind? = LaunchOptions.route == "explainer" ? .hrv : nil
    /// Goes up by one on every tap that opens something. Drives the light haptic.
    @State private var taps = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                if let today = days.first {
                    content(today)
                        .padding(.horizontal, DS.Space.side)
                        .padding(.top, DS.Space.l)
                        .padding(.bottom, DS.Space.xxl)
                } else {
                    loadingState
                }
            }
            // The header stays pinned at the top (it replaces the navigation bar). Its solid
            // background also covers the status bar, so scrolled content never runs under the clock.
            .safeAreaInset(edge: .top, spacing: 0) {
                header
            }
            // Only the screenshot job sets this (to capture the lower half of the screen).
            .defaultScrollAnchor(LaunchOptions.scroll == "bottom" ? UnitPoint.bottom : nil)
            .monoBackground()
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showRecovery) {
                if let today = days.first {
                    RecoveryDetailView(day: today)
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .sheet(item: $explaining) { kind in
                MetricExplainerView(kind: kind, today: days.first, history: Array(days.prefix(14)))
                    .presentationDetents([.medium, .large])
            }
            .sensoryFeedback(.impact(weight: .light), trigger: taps)
        }
    }

    // MARK: - Sections

    private func content(_ today: DaySummaryRecord) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xxl) {
            hero(today).riseIn(1)
            strain(today).riseIn(2)
            stats(today).riseIn(3)
            week.riseIn(4)
            activity.riseIn(5)
        }
    }

    /// Date on the left, data source + settings on the right.
    private var header: some View {
        ScreenHeader(title: Date.now.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())) {
            StatusPill()
            IconButton(systemName: "gearshape", label: "Settings") {
                open { showSettings = true }
            }
        }
    }

    /// The verdict: ring + number, one word, one line, one button.
    private func hero(_ today: DaySummaryRecord) -> some View {
        VStack(spacing: 0) {
            RecoveryDial(score: today.recoveryScore)

            Text(today.zone?.word ?? "Learning")
                .textStyle(.display)
                .foregroundStyle(DS.Colors.primary)
                .padding(.top, DS.Space.l)
                .accessibilityHidden(true)      // the ring already reads this word to VoiceOver

            Text(reason(today))
                .textStyle(.body)
                .foregroundStyle(DS.Colors.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, DS.Space.xs)

            Button {
                open { showRecovery = true }
            } label: {
                Label("See why", systemImage: "arrow.right")
                    .labelStyle(TrailingIconLabelStyle())
            }
            .buttonStyle(.primaryPill)
            .padding(.top, DS.Space.l)
            .accessibilityHint("Shows what moved your recovery score")
        }
        .frame(maxWidth: .infinity)
    }

    private func strain(_ today: DaySummaryRecord) -> some View {
        let target = StrainGuidance.targetRange(recovery: today.recoveryScore)
        return Button {
            open { explaining = .strain }
        } label: {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    HStack(spacing: 6) {
                        Image(systemName: "flame")
                        Text("Strain")
                    }
                    .textStyle(.caption)
                    .foregroundStyle(DS.Colors.secondary)

                    HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
                        CountUpText(value: today.strain) { PulseFormat.strain($0) }
                            .textStyle(.title)
                            .foregroundStyle(DS.Colors.primary)
                        Text("of 21")
                            .textStyle(.caption)
                            .foregroundStyle(DS.Colors.secondary)
                    }
                }
                StrainMeter(strain: today.strain, target: target)
                Text(StrainGuidance.advice(strain: today.strain, recovery: today.recoveryScore))
                    .textStyle(.body)
                    .foregroundStyle(DS.Colors.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.pressable)
        .accessibilityHint("Shows what strain means")
    }

    /// Four numbers, no boxes: a hairline and white space keep them apart.
    private func stats(_ today: DaySummaryRecord) -> some View {
        VStack(spacing: DS.Space.l) {
            HStack(alignment: .top, spacing: DS.Space.m) {
                stat(.sleep) {
                    StatBlock(symbol: "moon", label: "Sleep",
                              number: today.sleepMinutes.map { Double($0) },
                              format: { PulseFormat.duration(minutes: Int($0.rounded())) },
                              caption: sleepCaption(today))
                }
                stat(.sleep) {
                    StatBlock(symbol: "bed.double", label: "Need tonight",
                              number: Double(tonightsNeed(today)),
                              format: { PulseFormat.duration(minutes: Int($0.rounded())) },
                              caption: "to recover fully")
                }
            }
            Hairline()
            HStack(alignment: .top, spacing: DS.Space.m) {
                stat(.hrv) {
                    StatBlock(symbol: "waveform.path.ecg", label: "HRV",
                              number: today.hrvRMSSD,
                              format: { "\(Int($0.rounded()))" }, unit: "ms",
                              caption: baselineCaption(today.hrvRMSSD, today.baselineHRV))
                }
                stat(.restingHeartRate) {
                    StatBlock(symbol: "heart", label: "Resting HR",
                              number: today.restingHeartRate,
                              format: { "\(Int($0.rounded()))" }, unit: "bpm",
                              caption: baselineCaption(today.restingHeartRate, today.baselineRestingHeartRate))
                }
            }
        }
    }

    /// The one card on this screen: recovery for the last 7 days.
    private var week: some View {
        let recent = Array(days.prefix(7).reversed())       // oldest first
        let scores = recent.compactMap(\.recoveryScore)
        let average: Double? = scores.isEmpty ? nil : scores.reduce(0, +) / Double(scores.count)
        let bars = DayBarsChart.Bar.from(recent) { $0.recoveryScore }
        let summary = "Recovery, last \(recent.count) days. "
            + (average.map { "Average \(PulseFormat.percent($0))." } ?? "No scores yet.")
        return Button {
            open { explaining = .recovery }
        } label: {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Last 7 days")
                        .textStyle(.heading)
                        .foregroundStyle(DS.Colors.primary)
                    Spacer()
                    if let average {
                        Text("Avg \(PulseFormat.percent(average))")
                            .textStyle(.caption)
                            .foregroundStyle(DS.Colors.secondary)
                    }
                }
                DayBarsChart(bars: bars, domain: 0...100, summary: summary)
            }
            .monoCard()
        }
        .buttonStyle(.pressable)
        .accessibilityHint("Shows what recovery means")
    }

    private var activity: some View {
        let todays = workouts.filter { Calendar.current.isDateInToday($0.start) }
        return VStack(alignment: .leading, spacing: 0) {
            Text("Activity")
                .textStyle(.heading)
                .foregroundStyle(DS.Colors.primary)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, DS.Space.s)
            if todays.isEmpty {
                Text("No workouts yet today.")
                    .textStyle(.body)
                    .foregroundStyle(DS.Colors.secondary)
            } else {
                ForEach(Array(todays.enumerated()), id: \.element.id) { index, workout in
                    if index > 0 { Hairline() }
                    ActivityRow(workout: workout)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var loadingState: some View {
        VStack(spacing: DS.Space.m) {
            ProgressView()
            Text("Preparing 30 days of demo data")
                .textStyle(.bodyStrong)
                .foregroundStyle(DS.Colors.primary)
            Text("This only happens once.")
                .textStyle(.caption)
                .foregroundStyle(DS.Colors.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 200)
    }

    // MARK: - Helpers

    /// Every tap that opens something goes through here, so it also gives a light haptic.
    private func open(_ action: () -> Void) {
        taps += 1
        action()
    }

    private func stat<Content: View>(_ kind: MetricKind, @ViewBuilder _ content: () -> Content) -> some View {
        Button { open { explaining = kind } } label: { content() }
            .buttonStyle(.pressable)
            .accessibilityHint("Shows what this means")
    }

    /// One line: the single biggest reason behind today's score (tested in PulseCore).
    private func reason(_ today: DaySummaryRecord) -> String {
        let history = days.prefix(20).map(\.value)
        return RecoveryExplainer.oneLine(RecoveryExplainer.breakdown(for: today.value, history: history))
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
        HStack(spacing: 6) {
            configuration.title
            configuration.icon.imageScale(.small)
        }
    }
}

#Preview("Light") {
    TodayView()
        .modelContainer(PulseStore.previewContainer)
        .environment(DemoDataLoader())
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    TodayView()
        .modelContainer(PulseStore.previewContainer)
        .environment(DemoDataLoader())
        .preferredColorScheme(.dark)
}
