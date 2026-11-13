import SwiftUI
import SwiftData
import Charts
import PulseCore

/// One night at a time: how long, how calm, overnight heart rate, and why you needed what you needed.
struct SleepView: View {
    @Query(sort: \SleepRecord.end, order: .reverse) private var allSleeps: [SleepRecord]
    @Query(sort: \DaySummaryRecord.date, order: .reverse) private var days: [DaySummaryRecord]
    @Query private var profiles: [ProfileRecord]
    @Environment(\.modelContext) private var context
    @Environment(DemoDataLoader.self) private var loader

    @State private var nightIndex = 0          // 0 = last night, 1 = the night before, ...
    @State private var heartRate: [MinutePoint] = []
    @State private var segments: [SleepSegment] = []

    private var sleeps: [SleepRecord] { allSleeps.filter { !$0.isNap } }

    var body: some View {
        NavigationStack {
            ScrollView {
                if sleeps.isEmpty {
                    ContentUnavailableView("No sleep yet", systemImage: "moon.zzz",
                                           description: Text("Wear your band to bed and your night will appear here."))
                        .padding(.top, 80)
                } else {
                    let night = sleeps[min(nightIndex, sleeps.count - 1)]
                    content(night)
                        .padding(.horizontal)
                        .padding(.bottom, 24)
                }
            }
            .screenBackground()
            .navigationTitle("Sleep")
            .task(id: "\(nightIndex)-\(loader.rawDataReady)-\(sleeps.count)") { loadNight() }
        }
    }

    private func loadNight() {
        guard !sleeps.isEmpty else { return }
        let night = sleeps[min(nightIndex, sleeps.count - 1)]
        let minutes = PulseStore.minutes(from: night.start, to: night.end, in: context)
        heartRate = minutes.compactMap { m in m.averageHeartRate.map { MinutePoint(date: m.start, value: $0) } }
        segments = SleepTimeline.build(minutes: minutes, from: night.start, to: night.end)
    }

    @ViewBuilder
    private func content(_ night: SleepRecord) -> some View {
        let summary = days.first { Calendar.current.isDate($0.date, inSameDayAs: night.end) }
        let need = summary?.sleepNeedMinutes ?? 480
        VStack(spacing: Theme.spacing) {
            nightPicker(night)
            headline(night, need: need)
            timelineCard
            heartRateCard
            HStack(spacing: Theme.spacing) {
                MetricTile(title: "Efficiency", value: PulseFormat.percent(efficiency(night) * 100),
                           caption: "asleep / in bed", color: Theme.sleep, systemImage: "bed.double.fill")
                MetricTile(title: "Wake-ups", value: "\(night.disturbances)",
                           caption: "\(night.awakeMinutes) min awake", color: Theme.sleep, systemImage: "eye.fill")
            }
            if let summary {
                needCard(for: summary)
            }
        }
    }

    // MARK: - Cards

    private func headline(_ night: SleepRecord, need: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(PulseFormat.duration(minutes: night.asleepMinutes))
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("asleep").foregroundStyle(Theme.secondaryText)
            }
            ProgressView(value: min(1, Double(night.asleepMinutes) / Double(need)))
                .tint(Theme.sleep)
                .animation(.easeOut, value: night.asleepMinutes)
            Text("\(Int((Double(night.asleepMinutes) / Double(need) * 100).rounded()))% of the \(PulseFormat.duration(minutes: need)) you needed")
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
        }
        .card()
        .accessibilityElement(children: .combine)
    }

    private var timelineCard: some View {
        let totals = SleepTimeline.totals(segments)
        return VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Your night")
            if segments.isEmpty {
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            } else {
                Chart(segments) { segment in
                    RectangleMark(xStart: .value("Start", segment.start),
                                  xEnd: .value("End", segment.end),
                                  y: .value("Phase", segment.phase.title))
                        .foregroundStyle(Theme.color(for: segment.phase))
                        .cornerRadius(2)
                }
                .chartYScale(domain: SleepPhase.allCases.map(\.title))
                .chartXAxis {
                    AxisMarks(values: .stride(by: .hour, count: 2)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.hour())
                    }
                }
                .frame(height: 130)
                .accessibilityLabel(timelineSummary(totals))

                HStack(spacing: 16) {
                    ForEach(SleepPhase.allCases.reversed(), id: \.self) { phase in
                        HStack(spacing: 6) {
                            Circle().fill(Theme.color(for: phase)).frame(width: 8, height: 8)
                            Text(phase.title).font(.caption)
                            Text(PulseFormat.duration(minutes: totals[phase] ?? 0))
                                .font(.caption.weight(.semibold).monospacedDigit())
                        }
                    }
                }
                .foregroundStyle(Theme.secondaryText)
                .accessibilityHidden(true)

                Text("Restful = very still with a low heart rate. Pulse doesn't guess REM or deep sleep: heart rate and motion alone can't measure them reliably.")
                    .font(.caption2)
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .card()
    }

    private var heartRateCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Heart rate", trailing: lowestText)
            if heartRate.isEmpty {
                ProgressView().frame(maxWidth: .infinity, minHeight: 160)
            } else {
                Chart(heartRate) { point in
                    LineMark(x: .value("Time", point.date), y: .value("BPM", point.value))
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(Theme.heart)
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartXAxis {
                    AxisMarks(values: .stride(by: .hour, count: 2)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.hour())
                    }
                }
                .frame(height: 150)
                .accessibilityLabel("Overnight heart rate chart. \(lowestText ?? "")")
            }
        }
        .card()
    }

    /// "Why did I need 8h 30m?" Rebuilt from yesterday's numbers with the same formula as the engine.
    private func needCard(for summary: DaySummaryRecord) -> some View {
        let previous = days.first {
            Calendar.current.isDate($0.date, inSameDayAs: summary.date.addingTimeInterval(-86_400))
        }
        let breakdown = SleepNeedBreakdown(
            goal: Double(profiles.first?.sleepGoalMinutes ?? 480),
            previousStrain: previous?.strain,
            previousNeed: previous.map { Double($0.sleepNeedMinutes) },
            previousAsleep: previous?.sleepMinutes.map { Double($0) })
        return VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Why you needed \(PulseFormat.duration(minutes: Int(breakdown.total.rounded())))")
            needRow("Your baseline", breakdown.goal, sign: "")
            needRow("Yesterday's strain", breakdown.strainExtra, sign: "+")
            needRow("Recent sleep debt", breakdown.debtExtra, sign: "+")
            if breakdown.goal + breakdown.strainExtra + breakdown.debtExtra > breakdown.total + 0.5 {
                Text("Capped at 10 hours.").font(.caption2).foregroundStyle(Theme.secondaryText)
            }
        }
        .card()
    }

    private func needRow(_ title: String, _ minutes: Double, sign: String) -> some View {
        HStack {
            Text(title).font(.subheadline)
            Spacer()
            Text(sign + PulseFormat.duration(minutes: Int(minutes.rounded())))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(minutes > 0 || sign.isEmpty ? Color.primary : Theme.secondaryText)
        }
        .accessibilityElement(children: .combine)
    }

    private func nightPicker(_ night: SleepRecord) -> some View {
        HStack {
            Button { nightIndex += 1 } label: { Image(systemName: "chevron.left") }
                .disabled(nightIndex >= sleeps.count - 1)
                .accessibilityLabel("Previous night")
            Spacer()
            VStack(spacing: 2) {
                Text(nightIndex == 0 ? "Last night" : night.end.formatted(.dateTime.weekday(.wide).month().day()))
                    .font(.headline)
                Text("\(night.start.formatted(date: .omitted, time: .shortened)) – \(night.end.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            Button { nightIndex -= 1 } label: { Image(systemName: "chevron.right") }
                .disabled(nightIndex == 0)
                .accessibilityLabel("Next night")
        }
        .font(.title3)
        .padding(.vertical, 4)
        .sensoryFeedback(.selection, trigger: nightIndex)
    }

    // MARK: - Helpers

    private var lowestText: String? {
        heartRate.map(\.value).min().map { "lowest \(Int($0.rounded())) bpm" }
    }

    private func efficiency(_ night: SleepRecord) -> Double {
        let inBed = night.end.timeIntervalSince(night.start) / 60
        return inBed > 0 ? Double(night.asleepMinutes) / inBed : 0
    }

    private func timelineSummary(_ totals: [SleepPhase: Int]) -> String {
        let parts = SleepPhase.allCases.reversed().map { "\($0.title) \(PulseFormat.duration(minutes: totals[$0] ?? 0))" }
        return "Sleep timeline. " + parts.joined(separator: ", ")
    }
}

/// Average HR for one minute, for charts.
struct MinutePoint: Identifiable {
    let date: Date
    let value: Double
    var id: Date { date }

    /// Reads raw minutes in [from, to) as chart points (skipping off-wrist minutes).
    /// Use the view's own (main) context.
    static func load(from: Date, to: Date, context: ModelContext) -> [MinutePoint] {
        PulseStore.minutes(from: from, to: to, in: context).compactMap { m in
            m.averageHeartRate.map { MinutePoint(date: m.start, value: $0) }
        }
    }
}

#Preview {
    SleepView()
        .modelContainer(PulseStore.previewContainer)
        .environment(DemoDataLoader())
        .preferredColorScheme(.dark)
}
