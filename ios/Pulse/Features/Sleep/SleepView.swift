import SwiftUI
import SwiftData
import Charts
import PulseCore

/// One night at a time: how long, how calm, overnight heart rate, and why you needed what you needed.
/// Mono design (ios/design/DESIGN.md): the sleep phases are told apart by their row and a gray
/// level, not by color.
struct SleepView: View {
    @Query(sort: \SleepRecord.end, order: .reverse) private var allSleeps: [SleepRecord]
    @Query(sort: \DaySummaryRecord.date, order: .reverse) private var days: [DaySummaryRecord]
    @Query private var profiles: [ProfileRecord]
    @Environment(\.modelContext) private var context
    @Environment(DemoDataLoader.self) private var loader

    @State private var nightIndex = 0          // 0 = last night, 1 = the night before, ...
    @State private var heartRate: [ChartPoint] = []
    @State private var segments: [SleepSegment] = []

    private var sleeps: [SleepRecord] { allSleeps.filter { !$0.isNap } }

    var body: some View {
        ScrollView {
            Group {
                if sleeps.isEmpty {
                    EmptyState(symbol: "moon.zzz", title: "No sleep yet",
                               text: "Wear your band to bed and your night will appear here.")
                        .padding(.top, DS.Space.xxl)
                } else {
                    content(sleeps[min(nightIndex, sleeps.count - 1)])
                }
            }
            .padding(.horizontal, DS.Space.side)
            .padding(.top, DS.Space.l)
            .padding(.bottom, DS.Space.xxl)
        }
        .safeAreaInset(edge: .top, spacing: 0) { header }
        // Only the screenshot job sets this (to capture the lower half of the screen).
        .defaultScrollAnchor(LaunchOptions.scroll == "bottom" ? UnitPoint.bottom : nil)
        .monoBackground()
        .task(id: "\(nightIndex)-\(loader.rawDataReady)-\(sleeps.count)") { loadNight() }
        .sensoryFeedback(.selection, trigger: nightIndex)
    }

    private func loadNight() {
        guard !sleeps.isEmpty else { return }
        let night = sleeps[min(nightIndex, sleeps.count - 1)]
        let minutes = PulseStore.minutes(from: night.start, to: night.end, in: context)
        heartRate = minutes.compactMap { m in m.averageHeartRate.map { ChartPoint(date: m.start, value: $0) } }
        segments = SleepTimeline.build(minutes: minutes, from: night.start, to: night.end)
    }

    // MARK: - Sections

    /// Title on the left, older / newer night on the right.
    private var header: some View {
        ScreenHeader(title: "Sleep") {
            IconButton(systemName: "chevron.left", label: "Previous night") { nightIndex += 1 }
                .disabled(nightIndex >= sleeps.count - 1)
            IconButton(systemName: "chevron.right", label: "Next night") { nightIndex -= 1 }
                .disabled(nightIndex == 0)
        }
    }

    private func content(_ night: SleepRecord) -> some View {
        let summary = days.first { Calendar.current.isDate($0.date, inSameDayAs: night.end) }
        let need = summary?.sleepNeedMinutes ?? 480
        return VStack(alignment: .leading, spacing: DS.Space.xxl) {
            hero(night, need: need).riseIn(0)
            timeline.riseIn(1)
            heart.riseIn(2)
            HStack(alignment: .top, spacing: DS.Space.m) {
                StatBlock(symbol: "bed.double", label: "Efficiency",
                          number: efficiency(night) * 100,
                          format: { PulseFormat.percent($0) },
                          caption: "asleep / in bed")
                StatBlock(symbol: "eye", label: "Wake-ups",
                          number: Double(night.disturbances),
                          format: { "\(Int($0.rounded()))" },
                          caption: "\(night.awakeMinutes) min awake")
            }
            .riseIn(3)
            if let summary {
                needBreakdown(for: summary).riseIn(4)
            }
        }
    }

    /// The answer: how long you slept, and how that compares with what you needed.
    private func hero(_ night: SleepRecord, need: Int) -> some View {
        let fraction = Double(night.asleepMinutes) / Double(max(need, 1))
        let title = nightIndex == 0 ? "Last night" : night.end.formatted(.dateTime.weekday(.wide).month().day())
        let times = "\(night.start.formatted(date: .omitted, time: .shortened)) – \(night.end.formatted(date: .omitted, time: .shortened))"
        return VStack(alignment: .leading, spacing: DS.Space.s) {
            Text("\(title) · \(times)")
                .textStyle(.caption)
                .foregroundStyle(DS.Colors.secondary)
            HeroNumber(value: Double(night.asleepMinutes)) {
                PulseFormat.duration(minutes: Int($0.rounded()))
            }
            ProgressMeter(fraction: fraction)
                .padding(.vertical, DS.Space.xs)
            Text("\(Int((fraction * 100).rounded()))% of the \(PulseFormat.duration(minutes: need)) you needed.")
                .textStyle(.body)
                .foregroundStyle(DS.Colors.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), asleep \(PulseFormat.duration(minutes: night.asleepMinutes))")
        .accessibilityValue("\(Int((fraction * 100).rounded())) percent of the \(PulseFormat.duration(minutes: need)) you needed")
    }

    /// The one card on this screen: when you were restful, in light sleep, or awake.
    private var timeline: some View {
        let totals = SleepTimeline.totals(segments)
        return VStack(alignment: .leading, spacing: DS.Space.m) {
            SectionTitle(title: "Your night")
            if segments.isEmpty {
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            } else {
                Chart(segments) { segment in
                    RectangleMark(xStart: .value("Start", segment.start),
                                  xEnd: .value("End", segment.end),
                                  y: .value("Phase", segment.phase.title))
                        .foregroundStyle(Self.gray(for: segment.phase))
                        .cornerRadius(3)
                }
                .chartYScale(domain: SleepPhase.allCases.map(\.title))
                .chartYAxis {
                    AxisMarks(position: .leading) { _ in
                        AxisValueLabel()
                            .font(.footnote)
                            .foregroundStyle(DS.Colors.secondary)
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .hour, count: 2)) { _ in
                        AxisValueLabel(format: .dateTime.hour())
                            .font(.footnote)
                            .foregroundStyle(DS.Colors.secondary)
                    }
                }
                .frame(height: 120)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(timelineSummary(totals))

                HStack(alignment: .top, spacing: DS.Space.s) {
                    ForEach(SleepPhase.allCases.reversed(), id: \.self) { phase in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(Self.gray(for: phase))
                                    .frame(width: 10, height: 10)
                                Text(phase.title)
                                    .textStyle(.caption)
                                    .foregroundStyle(DS.Colors.secondary)
                            }
                            Text(PulseFormat.duration(minutes: totals[phase] ?? 0))
                                .textStyle(.bodyStrong)
                                .monospacedDigit()
                                .foregroundStyle(DS.Colors.primary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .accessibilityHidden(true)      // the chart's label already lists the totals

                Text("Restful = very still with a low heart rate. Pulse doesn't guess REM or deep sleep: heart rate and motion alone can't measure them reliably.")
                    .textStyle(.caption)
                    .foregroundStyle(DS.Colors.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .monoCard()
    }

    private var heart: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            SectionTitle(title: "Heart rate", trailing: lowestText)
            if heartRate.isEmpty {
                ProgressView().frame(maxWidth: .infinity, minHeight: 140)
            } else {
                LineChart(points: heartRate,
                          xValues: .stride(by: .hour, count: 2),
                          xFormat: .dateTime.hour(),
                          height: 140,
                          summary: "Overnight heart rate. \(lowestText ?? "")")
            }
        }
    }

    /// "Why did I need 8h 30m?" Rebuilt from yesterday's numbers with the same formula as the engine.
    private func needBreakdown(for summary: DaySummaryRecord) -> some View {
        let previous = days.first {
            Calendar.current.isDate($0.date, inSameDayAs: summary.date.addingTimeInterval(-86_400))
        }
        let breakdown = SleepNeedBreakdown(
            goal: Double(profiles.first?.sleepGoalMinutes ?? 480),
            previousStrain: previous?.strain,
            previousNeed: previous.map { Double($0.sleepNeedMinutes) },
            previousAsleep: previous?.sleepMinutes.map { Double($0) })
        let capped = breakdown.goal + breakdown.strainExtra + breakdown.debtExtra > breakdown.total + 0.5
        return VStack(alignment: .leading, spacing: 0) {
            SectionTitle(title: "Why you needed \(PulseFormat.duration(minutes: Int(breakdown.total.rounded())))")
                .padding(.bottom, DS.Space.s)
            ValueRow(label: "Your baseline", value: minutesText(breakdown.goal, sign: ""))
            Hairline()
            ValueRow(label: "Yesterday's strain", value: minutesText(breakdown.strainExtra, sign: "+"),
                     emphasized: breakdown.strainExtra > 0)
            Hairline()
            ValueRow(label: "Recent sleep debt", value: minutesText(breakdown.debtExtra, sign: "+"),
                     emphasized: breakdown.debtExtra > 0)
            if capped {
                Text("Capped at 10 hours.")
                    .textStyle(.caption)
                    .foregroundStyle(DS.Colors.secondary)
                    .padding(.top, DS.Space.s)
            }
        }
    }

    // MARK: - Helpers

    /// Gray level per phase. The rows of the chart are labelled, so this is only extra help.
    private static func gray(for phase: SleepPhase) -> Color {
        switch phase {
        case .restful: DS.Colors.primary
        case .light: DS.Colors.tertiary
        case .awake: DS.Colors.secondary
        }
    }

    private func minutesText(_ minutes: Double, sign: String) -> String {
        sign + PulseFormat.duration(minutes: Int(minutes.rounded()))
    }

    private var lowestText: String? {
        heartRate.map(\.value).min().map { "Lowest \(Int($0.rounded())) bpm" }
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

#Preview("Light") {
    SleepView()
        .modelContainer(PulseStore.previewContainer)
        .environment(DemoDataLoader())
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    SleepView()
        .modelContainer(PulseStore.previewContainer)
        .environment(DemoDataLoader())
        .preferredColorScheme(.dark)
}
