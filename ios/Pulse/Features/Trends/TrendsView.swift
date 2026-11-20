import SwiftUI
import SwiftData
import PulseCore

/// Week / month view: averages vs the previous period, plain-language insights, and one chart per metric.
/// "Better" / "worse" is always written out (ios/design/DESIGN.md).
struct TrendsView: View {
    @Query(sort: \DaySummaryRecord.date, order: .reverse) private var days: [DaySummaryRecord]
    @Environment(\.modelContext) private var context
    @Environment(BandManager.self) private var band
    @State private var period: Period = .week
    @State private var showReport = false

    enum Period: Int, CaseIterable, Identifiable {
        case week = 7, month = 30
        var id: Int { rawValue }
        var label: String { self == .week ? "7 days" : "30 days" }
    }

    /// Oldest first, for charts.
    private var window: [DaySummaryRecord] { Array(days.prefix(period.rawValue)).reversed() }
    private var values: [DailySummary] { days.map(\.value) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xxl) {
              if days.isEmpty {
                EmptyState(symbol: "chart.xyaxis.line", title: "No trends yet",
                           text: "Wear your band for a few days and nights. Trends compare this week with the one before.")
                    .padding(.top, DS.Space.xl)
              } else {
                summary.riseIn(0)
                Button(period == .week ? "See this week's report" : "See this month's report") { showReport = true }
                    .buttonStyle(.secondaryPill)
                insights.riseIn(1)
                recoveryChart.riseIn(2)
                lineSection(.hrv) { $0.hrvRMSSD }
                lineSection(.restingHeartRate) { $0.restingHeartRate }
                barSection(.sleep) { $0.sleepMinutes.map { Double($0) / 60 } }
                barSection(.strain) { $0.strain }
              }
            }
            .padding(.horizontal, DS.Space.side)
            .padding(.top, DS.Space.l)
            .padding(.bottom, DS.Space.tabBarClearance)
        }
        .refreshable { await band.refresh(context: context) }
        .safeAreaInset(edge: .top, spacing: 0) {
            ScreenHeader(title: "Trends") {
                PillPicker(options: Period.allCases, label: { $0.label }, selection: $period)
            }
        }
        // Only the screenshot job sets this (to capture the lower half of the screen).
        .defaultScrollAnchor(LaunchOptions.scroll == "bottom" ? UnitPoint.bottom : nil)
        .monoBackground()
        .sheet(isPresented: $showReport) { ReportView(period: period.rawValue) }
        .animation(DS.Motion.spring, value: period)
    }

    // MARK: - Summary

    /// The answer: average recovery for the period, then three supporting averages.
    private var summary: some View {
        let recovery = TrendInsights.compare(values, period: period.rawValue, \.recoveryScore)
        let hrv = TrendInsights.compare(values, period: period.rawValue, \.hrvRMSSD)
        let resting = TrendInsights.compare(values, period: period.rawValue, \.restingHeartRate)
        let sleep = TrendInsights.compare(values, period: period.rawValue) { $0.sleepMinutes.map { Double($0) } }
        let duration: (Double) -> String = { PulseFormat.duration(minutes: Int($0.rounded())) }
        let whole: (Double) -> String = { "\(Int($0.rounded()))" }

        return VStack(alignment: .leading, spacing: DS.Space.l) {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text("Average recovery, last \(period.label)")
                    .textStyle(.caption)
                    .foregroundStyle(DS.Colors.secondary)
                if let current = recovery.current {
                    HeroNumber(value: current) { PulseFormat.percent($0) }
                } else {
                    Text("--")
                        .font(.system(size: 64, weight: .bold))
                        .foregroundStyle(DS.Colors.tertiary)
                }
                Text("\(TrendInsights.changeCaption(recovery.delta, higherIsBetter: true)) vs the \(period.label) before")
                    .textStyle(.body)
                    .foregroundStyle(DS.Colors.secondary)
            }
            .accessibilityElement(children: .combine)

            Hairline()

            HStack(alignment: .top, spacing: DS.Space.m) {
                StatBlock(label: "HRV", number: hrv.current, format: whole, unit: "ms",
                          caption: TrendInsights.changeCaption(hrv.delta, higherIsBetter: true),
                          valueStyle: .heading)
                StatBlock(label: "Resting HR", number: resting.current, format: whole, unit: "bpm",
                          caption: TrendInsights.changeCaption(resting.delta, higherIsBetter: false),
                          valueStyle: .heading)
                StatBlock(label: "Sleep", number: sleep.current, format: duration,
                          caption: TrendInsights.changeCaption(sleep.delta, higherIsBetter: true, format: duration),
                          valueStyle: .heading)
            }
        }
    }

    private var insights: some View {
        let items = TrendInsights.insights(values)
        return VStack(alignment: .leading, spacing: 0) {
            SectionTitle(title: "Insights")
                .padding(.bottom, DS.Space.xs)
            ForEach(Array(items.enumerated()), id: \.element.id) { index, insight in
                if index > 0 { Hairline() }
                InsightRow(insight: insight)
            }
        }
    }

    // MARK: - Charts

    /// The one card on this screen.
    private var recoveryChart: some View {
        let scores = window.compactMap(\.recoveryScore)
        let avg = average(scores)
        let bars = DayBarsChart.Bar.from(window) { $0.recoveryScore }
        return VStack(alignment: .leading, spacing: DS.Space.m) {
            SectionTitle(title: "Recovery", trailing: avg.map { "Avg \(PulseFormat.percent($0))" })
            DayBarsChart(bars: bars, domain: 0...100, height: 120,
                         summary: "Recovery, last \(period.label). Average \(avg.map { PulseFormat.percent($0) } ?? "not available").")
        }
        .monoCard()
    }

    private func lineSection(_ kind: MetricKind, value: (DaySummaryRecord) -> Double?) -> some View {
        var points: [ChartPoint] = []
        for day in window {
            if let v = value(day) { points.append(ChartPoint(date: day.date, value: v)) }
        }
        let avg = average(points.map(\.value))
        return VStack(alignment: .leading, spacing: DS.Space.m) {
            SectionTitle(title: kind.shortTitle, trailing: avg.map { "Avg \(kind.format($0))" })
            LineChart(points: points, marksLast: true,
                      summary: "\(kind.title), last \(period.label). Average \(avg.map { kind.format($0) } ?? "not available").")
        }
    }

    private func barSection(_ kind: MetricKind, value: (DaySummaryRecord) -> Double?) -> some View {
        let bars = DayBarsChart.Bar.from(window, value: value)
        let avg = average(bars.compactMap(\.value))
        return VStack(alignment: .leading, spacing: DS.Space.m) {
            SectionTitle(title: kind.shortTitle, trailing: avg.map { "Avg \(kind.format($0))" })
            DayBarsChart(bars: bars,
                         summary: "\(kind.title), last \(period.label). Average \(avg.map { kind.format($0) } ?? "not available").")
        }
    }

    private func average(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
}

#Preview("Light") {
    TrendsView()
        .modelContainer(PulseStore.previewContainer)
        .environment(BandManager())
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    TrendsView()
        .modelContainer(PulseStore.previewContainer)
        .environment(BandManager())
        .preferredColorScheme(.dark)
}
