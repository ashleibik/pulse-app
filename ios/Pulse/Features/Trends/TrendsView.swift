import SwiftUI
import SwiftData
import Charts
import PulseCore

/// Week / month view of every daily number.
struct TrendsView: View {
    @Query(sort: \DaySummaryRecord.date, order: .reverse) private var days: [DaySummaryRecord]
    @State private var period: Period = .week

    enum Period: Int, CaseIterable, Identifiable {
        case week = 7, month = 30
        var id: Int { rawValue }
        var label: String { self == .week ? "7 days" : "30 days" }
    }

    /// Oldest first, for charts.
    private var window: [DaySummaryRecord] { Array(days.prefix(period.rawValue)).reversed() }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.spacing) {
                    Picker("Period", selection: $period) {
                        ForEach(Period.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .sensoryFeedback(.selection, trigger: period)

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
        }
    }

    // Recovery: bars colored by their own zone.
    private var recoveryCard: some View {
        let values = window.compactMap(\.recoveryScore)
        return VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Recovery", trailing: average(values).map { "avg \(PulseFormat.percent($0))" })
            Chart(window) { day in
                if let score = day.recoveryScore {
                    BarMark(x: .value("Day", day.date, unit: .day), y: .value("Recovery", score))
                        .foregroundStyle(Theme.color(for: day.zone))
                        .cornerRadius(3)
                }
            }
            .chartYScale(domain: 0...100)
            .frame(height: 150)
        }
        .card()
    }

    private func lineCard(_ kind: MetricKind, color: Color, value: @escaping (DaySummaryRecord) -> Double?) -> some View {
        let points = window.compactMap { day in value(day).map { DayValue(date: day.date, value: $0) } }
        return VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: kind.title, trailing: average(points.map(\.value)).map { "avg \(kind.format($0))" })
            Chart(points) { point in
                LineMark(x: .value("Day", point.date, unit: .day), y: .value(kind.title, point.value))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(color)
                PointMark(x: .value("Day", point.date, unit: .day), y: .value(kind.title, point.value))
                    .foregroundStyle(color)
                    .symbolSize(period == .week ? 30 : 12)
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .frame(height: 130)
        }
        .card()
    }

    private func barCard(_ kind: MetricKind, color: Color, value: @escaping (DaySummaryRecord) -> Double?) -> some View {
        let points = window.compactMap { day in value(day).map { DayValue(date: day.date, value: $0) } }
        return VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: kind.title, trailing: average(points.map(\.value)).map { "avg \(kind.format($0))" })
            Chart(points) { point in
                BarMark(x: .value("Day", point.date, unit: .day), y: .value(kind.title, point.value))
                    .foregroundStyle(color.gradient)
                    .cornerRadius(3)
            }
            .frame(height: 130)
        }
        .card()
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
