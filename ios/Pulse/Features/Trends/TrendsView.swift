import SwiftUI
import SwiftData
import Charts
import PulseCore

/// Week / month view: averages vs the previous period, plain-language insights, and one chart per metric.
struct TrendsView: View {
    @Query(sort: \DaySummaryRecord.date, order: .reverse) private var days: [DaySummaryRecord]
    @State private var period: Period = .week

    enum Period: Int, CaseIterable, Identifiable {
        case week = 7, month = 30
        var id: Int { rawValue }
        var label: String { self == .week ? "7 days" : "30 days" }
        var previousLabel: String { self == .week ? "vs previous 7 days" : "vs previous 30 days" }
    }

    /// Oldest first, for charts.
    private var window: [DaySummaryRecord] { Array(days.prefix(period.rawValue)).reversed() }
    private var values: [DailySummary] { days.map(\.value) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.spacing) {
                    Picker("Period", selection: $period) {
                        ForEach(Period.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .sensoryFeedback(.selection, trigger: period)

                    summaryRow

                    SectionHeader(title: "Insights").padding(.top, 4)
                    ForEach(TrendInsights.insights(values)) { InsightCard(insight: $0) }

                    SectionHeader(title: "Charts").padding(.top, 4)
                    recoveryCard
                    lineCard(.hrv, color: Theme.recoveryGreen) { $0.hrvRMSSD }
                    lineCard(.restingHeartRate, color: Theme.heart) { $0.restingHeartRate }
                    barCard(.sleep, color: Theme.sleep) { $0.sleepMinutes.map { Double($0) / 60 } }
                    barCard(.strain, color: Theme.strain) { $0.strain }
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .screenBackground()
            .navigationTitle("Trends")
            .animation(.easeInOut(duration: 0.3), value: period)
        }
    }

    // MARK: - Summary

    private var summaryRow: some View {
        let recovery = TrendInsights.compare(values, period: period.rawValue, \.recoveryScore)
        let hrv = TrendInsights.compare(values, period: period.rawValue, \.hrvRMSSD)
        let sleep = TrendInsights.compare(values, period: period.rawValue) { $0.sleepMinutes.map { Double($0) } }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: Theme.spacing) {
                stat("Recovery", recovery.current.map(PulseFormat.percent), recovery.delta, higherIsBetter: true)
                stat("HRV", hrv.current.map { "\(Int($0.rounded())) ms" }, hrv.delta, higherIsBetter: true)
                stat("Sleep", sleep.current.map { PulseFormat.duration(minutes: Int($0.rounded())) }, sleep.delta,
                     higherIsBetter: true, deltaFormat: { PulseFormat.duration(minutes: Int($0.rounded())) })
            }
            Text("Averages, \(period.previousLabel)")
                .font(.caption2)
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, 4)
        }
    }

    private func stat(_ title: String, _ value: String?, _ delta: Double?, higherIsBetter: Bool,
                      deltaFormat: @escaping (Double) -> String = { String(format: "%.0f", $0) }) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(Theme.secondaryText)
            Text(value ?? "--")
                .font(.headline.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            ChangeBadge(delta: delta, higherIsBetter: higherIsBetter, format: deltaFormat)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .accessibilityElement(children: .combine)
    }

    // MARK: - Charts

    private var recoveryCard: some View {
        let scores = window.compactMap(\.recoveryScore)
        return VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Recovery", trailing: average(scores).map { "avg \(PulseFormat.percent($0))" })
            Chart {
                ForEach(window) { day in
                    if let score = day.recoveryScore {
                        BarMark(x: .value("Day", day.date, unit: .day), y: .value("Recovery", score))
                            .foregroundStyle(Theme.color(for: day.zone))
                            .cornerRadius(3)
                    }
                }
                if let avg = average(scores) {
                    averageRule(avg)
                }
            }
            .chartYScale(domain: 0...100)
            .frame(height: 150)
            .accessibilityLabel("Recovery chart, \(period.label). Average \(average(scores).map(PulseFormat.percent) ?? "not available").")
        }
        .card()
    }

    private func lineCard(_ kind: MetricKind, color: Color, value: @escaping (DaySummaryRecord) -> Double?) -> some View {
        let points = window.compactMap { day in value(day).map { DayValue(date: day.date, value: $0) } }
        let avg = average(points.map(\.value))
        return VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: kind.title, trailing: avg.map { "avg \(kind.format($0))" })
            Chart {
                ForEach(points) { point in
                    LineMark(x: .value("Day", point.date, unit: .day), y: .value(kind.title, point.value))
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(color)
                    PointMark(x: .value("Day", point.date, unit: .day), y: .value(kind.title, point.value))
                        .foregroundStyle(color)
                        .symbolSize(period == .week ? 30 : 12)
                }
                if let avg {
                    averageRule(avg)
                }
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .frame(height: 130)
            .accessibilityLabel("\(kind.title) chart, \(period.label). Average \(avg.map(kind.format) ?? "not available").")
        }
        .card()
    }

    private func barCard(_ kind: MetricKind, color: Color, value: @escaping (DaySummaryRecord) -> Double?) -> some View {
        let points = window.compactMap { day in value(day).map { DayValue(date: day.date, value: $0) } }
        let avg = average(points.map(\.value))
        return VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: kind.title, trailing: avg.map { "avg \(kind.format($0))" })
            Chart {
                ForEach(points) { point in
                    BarMark(x: .value("Day", point.date, unit: .day), y: .value(kind.title, point.value))
                        .foregroundStyle(color.gradient)
                        .cornerRadius(3)
                }
                if let avg {
                    averageRule(avg)
                }
            }
            .frame(height: 130)
            .accessibilityLabel("\(kind.title) chart, \(period.label). Average \(avg.map(kind.format) ?? "not available").")
        }
        .card()
    }

    private func averageRule(_ value: Double) -> some ChartContent {
        RuleMark(y: .value("Average", value))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            .foregroundStyle(.white.opacity(0.45))
    }

    private func average(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
}

#Preview {
    TrendsView()
        .modelContainer(PulseStore.previewContainer)
        .preferredColorScheme(.dark)
}
